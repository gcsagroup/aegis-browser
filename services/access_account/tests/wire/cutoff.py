"""Real two-account TLS quota contention, cutoff, restart and confirmed top-up."""
import concurrent.futures
import contextlib
import json
import socket
import socketserver
import sqlite3
import ssl
import subprocess
import sys
import threading
import time

from ... import orders
from .acceptance import run
from .runtime import HOST, PERIOD, Runtime, require, until
from .settlement import account_command, entitlement
from .tls_target import WireTLS

LIMIT = 1 << 20
CHUNK = 8192


def drain(channel):
    """Count any final partial TLS record, independently of TLS decoding."""
    while block := channel.sock.recv(65536):
        channel.received += len(block)


def read_exact(sock, count):
    data = bytearray()
    while len(data) < count:
        block = sock.recv(count - len(data))
        require(block, "SOCKS target closed")
        data.extend(block)
    return bytes(data)


class Peer(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        channel = WireTLS(self.request, self.server.context, server=True)
        state = {"receivedTLS": 0, "offeredTLS": 0, "receivedPlain": 0, "closed": False}
        with self.server.lock:
            self.server.sessions.append(state)

        def record():
            with self.server.lock:
                state.update(receivedTLS=channel.received, offeredTLS=channel.sent)

        def write(data):
            channel.write(data)
            record()

        try:
            channel.run(channel.tls.do_handshake)
            tag = channel.read(1)
            require(tag in (b"U", b"D", b"I", b"B", b"C", b"R", b"E"), "Unexpected origin tag")
            state["tag"] = tag.decode()
            with self.server.lock:
                require(tag not in self.server.state, "Duplicate origin tag")
                self.server.state[tag] = state
            write(b"+")
            if tag == b"D":
                require(self.server.start_down.wait(10), "Download contender never started")
                for _ in range(256):
                    write(b"d" * CHUNK)
                    time.sleep(.004)
            else:
                while data := channel.run(lambda: channel.tls.read(CHUNK)):
                    with self.server.lock:
                        state["receivedPlain"] += len(data)
                    record()
                    if tag in (b"B", b"C", b"R"):
                        write(data)
                    elif tag == b"U":
                        require(data == b"u" * len(data), "Origin upload payload changed")
        except (ConnectionError, EOFError, ssl.SSLError):
            pass
        except Exception as error:
            with self.server.lock:
                self.server.failures.append(type(error).__name__ + ": " + str(error))
        finally:
            proof = "eof"
            try:
                drain(channel)
            except ConnectionError:
                proof = "reset"
            except TimeoutError:
                proof = "timeout"
                with self.server.lock:
                    self.server.failures.append("TLS origin did not drain")
            record()
            with self.server.lock:
                state.update(closed=proof != "timeout", closeProof=proof,
                             closedAtMs=time.time_ns() // 1000000)


class TLSClient:
    def __init__(self, sock, trust, tag):
        sock.settimeout(4)
        self.channel = WireTLS(sock, trust)
        self.channel.run(self.channel.tls.do_handshake)
        self.channel.write(tag)
        require(self.channel.read(1) == b"+", "No TLS target confirmation for " + tag.decode())
        self.closed = False
        self.plain_received = 0

    def write(self, data):
        self.channel.write(data)

    def read(self):
        try:
            data = self.channel.run(lambda: self.channel.tls.read(CHUNK))
            if data:
                self.plain_received += len(data)
                return data
        except (ConnectionError, EOFError, ssl.SSLError):
            pass
        # A cutoff can split a target TLS record. Its bytes still reached the
        # client even though the TLS application cannot decode that record.
        try:
            drain(self.channel)
        except ConnectionError:
            pass
        self.closed = True
        return b""

    def close(self):
        self.channel.sock.close()


class GuardRuntime(Runtime):
    def setup_targets(self):
        super().setup_targets()
        target = socketserver.ThreadingTCPServer((HOST, 0), Peer)
        target.daemon_threads = True
        target.context = self.origin.context
        target.state, target.sessions, target.failures = {}, [], []
        target.lock = threading.Lock()
        target.start_down = threading.Event()
        self.guard_target = target
        self.target = self.serve(target)
        self.authority = f"localhost:{self.target}"

    def seed(self):
        super().seed()
        with contextlib.closing(sqlite3.connect(self.db)) as db:
            db.execute("UPDATE snapshots SET quota_bytes=? WHERE account_id='a'", (LIMIT,))
            db.commit()

    def start_collector(self):
        self.collector = self.launch("collector", [*self.cli, "serve", "--database", self.db,
                                     "--config", self.config, "--socket", self.socket_path, "--enforce-quota"],
                                     socket_path=self.socket_path)

    def start_xray(self, socks):
        self.socks = socks
        super().start_xray(socks)

    def launch(self, name, args, **kwargs):
        if kwargs.get("meter"):
            args = ["env", "AEGIS_XRAY_QUOTA=enforce", *args]
        return super().launch(name, args, **kwargs)

    def restart_xray(self):
        self.xray_process.terminate()
        self.xray_process.wait(timeout=5)
        self.xray_process = self.launch("server-xray-restarted", [self.metered, "run", "-c",
                                      self.root / "xserver.json"], service_port=self.reality_port, meter=True)

    def inspect(self):
        return json.loads(subprocess.check_output([sys.executable, "-m", "services.access_account.quota",
                          "--database", self.db, "--account", "a", "--period", PERIOD]))

    def socks_connect(self, account):
        # Bypass issuer/CONNECT authorization to test the actual paid Xray
        # admission path with its already-configured account identity.
        sock = socket.create_connection((HOST, self.socks[account]), timeout=4)
        self.stack.callback(sock.close)
        sock.sendall(b"\x05\x01\x00")
        require(read_exact(sock, 2) == b"\x05\x00", "SOCKS fixture unavailable")
        sock.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(HOST) + self.target.to_bytes(2, "big"))
        reply = read_exact(sock, 10)
        require(reply[:4] == b"\x05\x00\x00\x01", "SOCKS target rejected")
        return sock

    def flow(self, account, tag, *, direct=False):
        sock = self.socks_connect(account) if direct else self.connect(account)
        return TLSClient(sock, self.trust, tag)


def denied(rt):
    with rt.guard_target.lock:
        before = len(rt.guard_target.sessions)
    started = time.monotonic()
    try:
        probe = rt.flow("a", b"R", direct=True)
    except (ConnectionError, EOFError, ssl.SSLError, AssertionError):
        pass
    else:
        probe.close()
        raise AssertionError("A new paid Xray flow reached the TLS origin")
    require(time.monotonic() - started < 4, "New-flow rejection was not bounded")
    with rt.guard_target.lock:
        require(len(rt.guard_target.sessions) == before, "Rejected Xray flow still contacted the origin")
    return {"directPaidXrayRejected": True, "originConnectionsAdded": 0}


def echo(client):
    client.write(b"continuity")
    require(client.channel.read(10) == b"continuity", "Other account payload changed")
    client.plain_received += 10


def closed(client):
    require(not client.read(), "Cutoff connection still delivered application data")
    return client.closed


def reconciled(rt, clients):
    require(not rt.guard_target.failures, str(rt.guard_target.failures))
    sample = rt.usage()
    rows = {r["accountId"]: r for r in sample["accounts"]}
    state = rt.guard_target.state
    up = sum(state[t]["receivedTLS"] for t in clients)
    down = sum(client.channel.received for client in clients.values())
    row = rows.get("a", {})
    if ((up, down) != (row.get("uploadedBytes"), row.get("downloadedBytes"))
            or row.get("openFlows") or row.get("incompleteFlows")):
        return None
    return {"acceptedTargetTLS": up, "deliveredClientTLS": down, "usage": sample,
            "endpoints": {t.decode(): {"target": dict(state[t]), "clientReceivedTLS": c.channel.received,
                                        "clientReceivedPlain": c.plain_received}
                          for t, c in clients.items()}}


def await_reconciled(rt, clients, emit):
    try:
        return until(lambda: reconciled(rt, clients))
    except Exception:
        emit("unreconciled", {"quota": rt.inspect(), "usage": rt.usage(),
                              "targetSessions": rt.guard_target.sessions,
                              "clientReceivedTLS": {t.decode(): c.channel.received
                                                    for t, c in clients.items()}})
        raise


def exercise(rt, emit):
    rt.setup()
    for account in ("a", "b"):
        account_command(rt, "bind", account, PERIOD)
    clients = {tag: rt.flow("a", tag, direct=tag == b"I") for tag in (b"U", b"D", b"I")}
    upload, download, idle = [clients[tag] for tag in (b"U", b"D", b"I")]
    other = rt.flow("b", b"B")
    echo(other)
    base = rt.inspect()
    require(0 < base["confirmedBytes"] < LIMIT // 4, "Unexpected TLS setup consumption")
    emit("open", {"quota": base, "AActiveTLSFlows": 2, "AIdleTLSFlows": 1, "BLiveTLSFlows": 1})

    def send():
        try:
            for _ in range(256):
                upload.write(b"u" * CHUNK)
                time.sleep(.004)
        except (ConnectionError, EOFError, ssl.SSLError):
            pass

    def receive():
        while data := download.read():
            require(data == b"d" * len(data), "Client download payload changed")

    start = time.time_ns() // 1000000
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        receiving = pool.submit(receive)
        sending = pool.submit(send)
        rt.guard_target.start_down.set()
        receiving.result(timeout=15)
        sending.result(timeout=15)
    require(closed(idle) and closed(upload), "A previously opened TLS socket remained usable")
    until(lambda: all(rt.guard_target.state[t]["closed"] for t in clients))
    observed = await_reconciled(rt, clients, emit)
    end = rt.inspect()
    up, down = observed["acceptedTargetTLS"], observed["deliveredClientTLS"]
    require(rt.guard_target.state[b"U"]["receivedPlain"] > CHUNK and download.plain_received > CHUNK,
            "Both TLS contenders must transfer real application data")
    require(up + down == LIMIT and end["confirmedBytes"] == LIMIT and end["heldBytes"] == 0
            and end["grantedBytes"] - end["releasedBytes"] == LIMIT, "Shared quota did not reconcile")
    quota_cut = max(s["lastCutAt"] for s in end["flowStates"] if s["reason"] == "quota")
    close_delay = max(rt.guard_target.state[t]["closedAtMs"] for t in clients) - quota_cut
    require(0 <= close_delay < 1250, "Quota did not close the old TLS targets promptly")
    require(entitlement(rt, "a")["status"] == "exhausted", "Account still has paid access")
    rejection = denied(rt)
    echo(other)
    emit("exhausted", {**observed, "quota": end, "startedAtMs": start, "closeDelayMs": close_delay,
                       "newFlow": rejection,
                       "BContinuedOnExistingTLS": True})

    other.close()
    rt.collector.terminate()
    rt.collector.wait(timeout=5)
    rt.socket_path.unlink(missing_ok=True)
    rt.start_collector()
    rt.restart_xray()
    require(rt.inspect()["confirmedBytes"] == LIMIT and rt.inspect()["heldBytes"] == 0,
            "Collector/node restart reset quota consumption")
    emit("restart", {"quota": rt.inspect(), "newFlow": denied(rt)})

    orders.migrate(rt.db)
    terms = dict(order_id="test-replenishment", account_id="a", plan_id="paid", period_id=PERIOD,
                 panel_client="client-a", quota_bytes=65536, duration_ms=60000)
    orders.record(rt.db, **terms, paid=False)
    denied(rt)
    orders.record(rt.db, **terms, paid=True)
    require(orders.redeem(rt.db, rt.tokens["a"], terms["order_id"], lambda: time.time_ns() // 1000000),
            "Top-up did not settle")
    resumed = rt.flow("a", b"R")
    clients[b"R"] = resumed
    echo(resumed)
    resumed.close()
    until(lambda: rt.guard_target.state[b"R"]["closed"])
    emit("confirmed-topup", {"entitlement": entitlement(rt, "a"), "quota": rt.inspect(),
                             "TLSRoundTripResumed": True})

    old = rt.flow("a", b"E")
    clients[b"E"] = old
    independent = rt.flow("b", b"C")
    echo(independent)
    expires = time.time_ns() // 1000000 + 1500
    with contextlib.closing(sqlite3.connect(rt.db)) as db:
        db.execute("UPDATE snapshots SET expires_at=? WHERE account_id='a'", (expires,))
        db.execute("UPDATE plans SET period_end=? WHERE account_id='a'", (expires,))
        db.commit()
    require(closed(old), "Expiry failed to close the previously open TLS connection")
    elapsed = time.time_ns() // 1000000 - expires
    require(-30 <= elapsed < 1250, "Expiry cutoff outside bounded interval")
    until(lambda: rt.guard_target.state[b"E"]["closed"])
    rejection = denied(rt)
    echo(independent)
    final = await_reconciled(rt, clients, emit)
    value = entitlement(rt, "a")
    require(value["status"] == "expired" and int(value["remainingBytes"]) > 0, "Wrong expiry state")
    require(int(value["usedBytes"]) == final["acceptedTargetTLS"] + final["deliveredClientTLS"]
            == rt.inspect()["confirmedBytes"] and rt.inspect()["heldBytes"] == 0,
            "Renewal/expiry TLS bytes did not reconcile with confirmed usage")
    emit("expired", {"deadlineMs": expires, "closeDelayMs": elapsed, "entitlement": value,
                     "quota": rt.inspect(), "newFlow": rejection, **final,
                     "BContinuedOnExistingTLS": True})
    independent.close()


if __name__ == "__main__":
    run(exercise, runtime_class=GuardRuntime)
