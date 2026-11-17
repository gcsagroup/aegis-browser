"""Settle live REALITY traffic, then replay the same, older, restarted and prior-period reports."""
import concurrent.futures
import contextlib
import http.client
import json
import sqlite3
import subprocess
import sys
import time

from .acceptance import ACCOUNTS, run, snapshot
from .runtime import HOST, PERIOD, require
from .tls_target import Client

NEXT_PERIOD = "next"


def account_command(rt, op, account, period, *extra):
    subprocess.run([sys.executable, "-m", "services.access_account.settlement", op,
                    "--database", rt.db, "--config", rt.config, "--account", account,
                    "--period", period, *map(str, extra)], check=True, capture_output=True)


def entitlement(rt, account):
    with contextlib.closing(http.client.HTTPConnection(HOST, rt.api, timeout=5)) as connection:
        connection.request("GET", "/v1/me/entitlement",
                           headers={"Authorization": "Bearer " + rt.tokens[account]})
        response = connection.getresponse()
        require(response.status == 200 and response.getheader("Cache-Control") == "no-store",
                f"Unusable entitlement for {account}: HTTP {response.status}")
        value = json.loads(response.read())
    require(value["entitlementAccountId"] == account, "Entitlement returned another account")
    return value


def balance(rt, account, expected, period=PERIOD):
    value = entitlement(rt, account)
    up, down = expected
    require(value["periodId"] == period and value["uploadedBytes"] == str(up)
            and value["downloadedBytes"] == str(down) and value["usedBytes"] == str(up + down)
            and value["remainingBytes"] == str(int(value["quotaBytes"]) - up - down),
            f"{account} target and entitlement disagree: {expected}, {value}")
    return value


def replay(rt, row):
    account_command(rt, "replay", row["accountId"], row["periodId"],
                    "--uploaded", row["uploadedBytes"], "--downloaded", row["downloadedBytes"],
                    "--measured-at", row["sampledAt"])


def rollover(rt):
    # Operator provisioning of a new account period and unique panel client.
    now = time.time_ns() // 1_000_000
    with contextlib.closing(sqlite3.connect(rt.db)) as db:
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("DELETE FROM plans WHERE account_id='a'")
        db.execute("INSERT INTO plans VALUES (?,?,?,?,?,?)",
                   ("a", "paid", NEXT_PERIOD, now, now + 600000, "next-a"))
        db.execute("INSERT INTO snapshots VALUES (?,?,?,?,?,?,?,?)",
                   ("a", NEXT_PERIOD, 10**9, 0, 0, now + 600000, now, now))
        db.commit()


def exercise(rt, emit):
    rt.setup()
    for name in ACCOUNTS:
        account_command(rt, "bind", name, PERIOD)
        balance(rt, name, (0, 0))
    checkpoints = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        clients = list(pool.map(lambda name: Client(name, rt.connect(name), rt.trust), ACCOUNTS))
        for number in range(3):
            list(pool.map(lambda client: client.exchange(number), clients))
            sample = snapshot(rt, 1)
            sample["entitlements"] = {n: balance(rt, n, sample["targetTLS"][n]) for n in ACCOUNTS}
            for row in sample["usage"]["accounts"]:
                value = sample["entitlements"][row["accountId"]]
                require(value["measuredAt"] == row["sampledAt"] and
                        value["receivedAt"] >= value["measuredAt"], "Wrong confirmed sample time")
            emit(f"live-{number + 1}", sample)
            checkpoints.append(sample)
        list(pool.map(lambda client: client.finish(), clients))
    final = snapshot(rt, 0)
    emit("target-finished", final)
    latest, older = final["usage"]["accounts"][0], checkpoints[0]["usage"]["accounts"][0]
    for stage, row in (("duplicate", latest), ("out-of-order", older), ("restart", latest)):
        if stage == "restart":
            rt.collector.terminate()
            rt.collector.wait(timeout=5)
            # The old process is gone; remove only this fixture's stale socket inode.
            rt.socket_path.unlink(missing_ok=True)
            rt.start_collector()
        replay(rt, row)
        states = {name: balance(rt, name, final["targetTLS"][name]) for name in ACCOUNTS}
        require(states[latest["accountId"]]["measuredAt"] == latest["sampledAt"],
                "Replay changed the latest confirmed sample time")
        emit(stage, states)
    rollover(rt)
    replay(rt, latest)
    emit("old-period", {"oldNodeUsage": rt.usage(), "newA": balance(rt, "a", (0, 0), NEXT_PERIOD),
                        "unaffectedB": balance(rt, "b", final["targetTLS"]["b"])})


if __name__ == "__main__":
    run(exercise)
