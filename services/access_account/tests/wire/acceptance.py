"""Run from the checkout with python -m services.access_account.tests.wire.acceptance --help."""
import argparse
import concurrent.futures
import contextlib
import hashlib
from importlib.metadata import version
import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from .runtime import HOST, NODE, PERIOD, SERVICE, Runtime, require, until
from .tls_target import Client, payload

ACCOUNTS = ("a", "b")


def reconcile(sample, counts, open_flows):
    rows = {row["accountId"]: row for row in sample["accounts"]}
    if set(rows) != set(ACCOUNTS) or any(r["periodId"] != PERIOD for r in rows.values()):
        return False
    for name in ACCOUNTS:
        row = rows[name]
        if ((row["uploadedBytes"], row["downloadedBytes"]) != counts.get(name)
                or row["openFlows"] != open_flows or row["incompleteFlows"] or not row["sampledAt"]):
            return False
    return (sample["nodeId"] == NODE and sample["periodId"] == PERIOD
            and sample["openFlows"] == 2 * open_flows and not sample["incompleteFlows"]
            and all(sample[key] == sum(row[key] for row in rows.values())
                    for key in ("uploadedBytes", "downloadedBytes")))


def snapshot(rt, open_flows):
    deadline = time.monotonic() + 8
    while True:
        require(not rt.origin.failures, str(rt.origin.failures))
        sample = rt.usage()
        counts = rt.origin.snapshot()
        if reconcile(sample, counts, open_flows):
            return {"atMs": time.time_ns() // 1000000, "targetTLS": counts, "usage": sample}
        if time.monotonic() > deadline:
            raise AssertionError(f"Target reconciliation failed: target={counts}, node={sample}")
        time.sleep(.1)


def controls(rt, last):
    # Independent operational TLS probe of the REALITY listener (uses its cover destination).
    probe = rt.trust.wrap_socket(socket.create_connection((HOST, rt.reality_port), timeout=5),
                                 server_hostname="localhost")
    probe.close()
    with socket.create_connection((HOST, rt.target), timeout=5) as direct:
        client = Client("d", direct, rt.trust)
        for number in range(3):
            client.exchange(number)
        client.finish()
    require(rt.origin.snapshot()["d"][0] > 0, "Direct TLS origin session had no bytes")
    require(rt.usage() == last, "Independent probe or direct traffic changed metered usage")
    return {"directTargetTLS": rt.origin.snapshot()["d"], "coverProbe": "TLS handshake",
            "usage": last}


def cache_control(rt, emit):
    import requests
    from cachecontrol import CacheControl
    url = f"https://{rt.authority}/cache"
    with CacheControl(requests.Session()) as session:
        session.trust_env = False
        session.verify = str(rt.root / "cert.pem")
        def fetch(expected_cache):
            try:
                with session.get(url, timeout=6, allow_redirects=False) as response:
                    require(response.status_code == 200 and response.content == b"resource"
                            and response.from_cache == expected_cache, "Unexpected HTTP cache result")
            except requests.RequestException:
                # The proxy URL in this library's exception can contain its credentials.
                raise RuntimeError("HTTP cache transport failed") from None
        before = rt.usage()
        fetch(False)
        def drained():
            sample = rt.usage()
            return sample if sample["openFlows"] == 0 and not sample["incompleteFlows"] else None
        warm = until(drained)
        require(warm == before and rt.origin.cache_requests == 1, "Direct cache warmup changed metering")
        emit("cache-miss", {"originRequests": rt.origin.cache_requests, "usage": warm})
        fetch(True)
        require(rt.origin.cache_requests == 1 and rt.usage() == warm,
                "HTTP cache hit changed origin traffic or account usage")
        emit("cache-hit", {"httpClientFromCache": True, "originRequests": rt.origin.cache_requests,
                           "usage": warm})


def plain_control(rt, before):
    # Exchange distinct messages to exercise the actual unpadded Vision branch.
    with rt.connect("a", plain=True) as sock, sock.makefile("rb") as reader:
        for number in range(40):
            sock.sendall(payload("p", number, 32, "up"))
            require(reader.read(819) == payload("p", number, 819, "down"), "Plain payload mismatch")
    def drained():
        sample = rt.usage()
        return sample if not sample["openFlows"] and not sample["incompleteFlows"] else None
    after = until(drained)
    def accounts(snapshot):
        return {r["accountId"]: r for r in snapshot["accounts"]}
    a, old = accounts(after), accounts(before)
    require(a["b"] == old["b"], "Plain target changed the other account")
    for row, previous in ((a["a"], old["a"]), (after, before)):
        require(row["uploadedBytes"] - previous["uploadedBytes"] == rt.plain.received
                and row["downloadedBytes"] - previous["downloadedBytes"] == rt.plain.sent,
                "Plain target byte delta mismatch")
    require(a["a"]["pathBytes"]["vision_plain"] > old["a"]["pathBytes"]["vision_plain"],
            "Vision plain write was not exercised")
    return {"targetPlain": [rt.plain.received, rt.plain.sent], "usage": after}


def exercise(rt, emit):
    rt.setup()
    baseline = rt.usage()
    require(not baseline["accounts"] and baseline["openFlows"] == 0, "Non-empty baseline")
    emit("baseline", baseline)
    clients = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        def connect(name):
            return Client(name, rt.connect(name), rt.trust)
        clients.update(zip(ACCOUNTS, pool.map(connect, ACCOUNTS)))
        previous = {name: (0, 0) for name in ACCOUNTS}
        for number in range(3):
            list(pool.map(lambda client: client.exchange(number), clients.values()))
            result = snapshot(rt, 1)
            for name, counts in result["targetTLS"].items():
                require(all(n > old for n, old in zip(counts, previous[name])), "Live stream stalled")
                previous[name] = counts
            emit("open-" + str(number + 1), result)
        list(pool.map(lambda client: client.finish(), clients.values()))
    result = snapshot(rt, 0)
    for row in result["usage"]["accounts"]:
        paths = row["pathBytes"]
        require(paths["target_tcp"] == row["uploadedBytes"], "Missing target TCP coverage")
        require(paths["vision_padded"] > 0 and paths["vision_raw"] > 0,
                "Both Vision padded and direct writes must actually run")
        require(sum(paths[p] for p in ("vision_padded", "vision_plain", "vision_raw"))
                == row["downloadedBytes"], "Missing Vision coverage")
    emit("finished", result)
    emit("controls", controls(rt, result["usage"]))
    emit("plain-target", plain_control(rt, result["usage"]))
    cache_control(rt, emit)


def run(test=exercise, *, runtime_class=Runtime):
    parser = argparse.ArgumentParser(description=__doc__, epilog="Test dependencies: requests==2.32.5 and CacheControl==0.14.3.")
    parser.add_argument("--client", required=True, type=Path, help="stock Xray binary")
    parser.add_argument("--server", required=True, type=Path, help="meter-enabled Xray binary")
    parser.add_argument("--receipt", required=True, type=Path, help="new JSONL file; never overwritten")
    args = parser.parse_args()
    os.umask(0o077)
    with args.receipt.open("x") as receipt:
        def emit(stage, value):
            print(json.dumps({"stage": stage, "value": value}), file=receipt, flush=True)
        files = [args.client, args.server, *Path(__file__).parent.glob("*.py"),
                 *SERVICE.glob("*.py"), *SERVICE.glob("*.sql")]
        emit("identity", {"dependencies": {pkg: version(pkg) for pkg in ("requests", "CacheControl")},
                          "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                          "sha256": {str(f): hashlib.sha256(f.read_bytes()).hexdigest() for f in files}})
        try:
            with tempfile.TemporaryDirectory(prefix="n1-") as tmp, contextlib.ExitStack() as stack:
                rt = runtime_class(Path(tmp), stack, args.client.resolve(), args.server.resolve(), Path(tmp) / "m.sock")
                test(rt, emit)
        except Exception as error:
            emit("failed", str(error))
            raise
        emit("passed", True)


if __name__ == "__main__":
    run()
