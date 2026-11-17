"""Run one native browser scenario in its own fixture; emit private env paths and a redacted receipt."""
import argparse
import contextlib
import hashlib
import json
import os
import shlex
import signal
import socketserver
import ssl
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from .runtime import HOST, NODE, PERIOD, Runtime
from .settlement import account_command, entitlement
from .tls_target import WireTLS

BODY = b"Aegis controlled native route\n"


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        channel = WireTLS(self.request, self.server.ctx, server=True)
        entry = {"atMs": time.time_ns() // 1000000, "status": "handshake"}
        try:
            self.request.settimeout(5)
            channel.run(channel.tls.do_handshake)
            req = bytearray()
            while not req.endswith(b"\r\n\r\n") and len(req) < 8192:
                req.extend(channel.read(1))
            line, *headers = req.lower().split(b"\r\n")
            peer = f"n127.0.0.1:{self.client_address[1]}->127.0.0.1:{self.server.server_address[1]}"
            owned = subprocess.run(["/usr/sbin/lsof", "-nP", "-a", "-p", str(self.server.runtime.xray_process.pid),
                                    "-iTCP", "-sTCP:ESTABLISHED", "-Fn"], capture_output=True, timeout=4,
                                   text=True).stdout.splitlines()
            clean = not any(h.startswith((b"proxy-authorization:", b"authorization:")) for h in headers)
            route = line.split(b" ")[1].split(b"?", 1)[0]
            ok = route in (b"/page", b"/download", b"/download/slow") and clean and peer in owned
            entry.update(status=200 if ok else 403, xrayPeer=peer in owned, clean=clean,
                         resource=route.decode("ascii") if ok else None)
            page = route == b"/page"
            slow = route == b"/download/slow"
            body = b'<html><title>Metered webpage</title>metered webpage</html>' if page else BODY
            size = (409600 if slow else len(body)) if ok else 0
            channel.write((f"HTTP/1.1 {entry['status']} Reply\r\nContent-Length: {size}\r\n"
                           f"Content-Type: {'text/html' if page else 'application/octet-stream'}\r\n"
                           "Connection: close\r\nCache-Control: no-store\r\n\r\n").encode())
            if ok and slow:
                for _ in range(100):
                    channel.write(bytes(4096))
                    time.sleep(.3)
            elif ok:
                channel.write(body)
            channel.run(channel.tls.unwrap)
        except (EOFError, OSError) as exc:
            entry["closed"] = type(exc).__name__
        finally:
            entry.update(targetReceived=channel.received, targetSent=channel.sent)
            with self.server.lock:
                self.server.events.append(entry)


class NativeRuntime(Runtime):
    def setup_targets(self):
        super().setup_targets()
        native = socketserver.ThreadingTCPServer((HOST, 0), Handler)
        native.daemon_threads = True
        # Keep the REALITY cover ALPN unchanged; only the HTTP target is HTTP/1.1.
        native.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        native.ctx.load_cert_chain(self.root / "cert.pem", self.root / "key.pem")
        native.ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        native.ctx.num_tickets = 0
        native.ctx.set_alpn_protocols(["http/1.1"])
        native.runtime = self
        native.lock = threading.Lock()
        native.events = []
        self.native = native
        self.target = self.serve(native)
        self.authority = f"paid-wire.invalid:{self.target}"


def private_env(rt):
    outbound = json.loads((rt.root / "a.json").read_text())["outbounds"][0]
    server = outbound["settings"]["vnext"][0]
    reality = outbound["streamSettings"]["realitySettings"]
    config = rt.root / "embedded.json"
    config.write_text(json.dumps({"address": HOST, "port": server["port"], "id": server["users"][0]["id"],
                                 "serverName": reality["serverName"], "publicKey": reality["password"],
                                 "shortId": reality["shortId"], "fingerprint": reality["fingerprint"]}))
    origin = "https://" + rt.authority
    env = {"AEGIS_S3_ORIGIN": f"http://{HOST}:{rt.api}", "AEGIS_S3_ID": "a", "AEGIS_S3_B_ID": "b",
           "AEGIS_S3_TOKEN": rt.tokens["a"], "AEGIS_S3_B_TOKEN": rt.tokens["b"],
           "AEGIS_S3_CA_PEM": str(rt.root / "cert.pem"), "AEGIS_S3_HTTPS_URL": origin + "/download",
           "AEGIS_S3_SLOW_URL": origin + "/download/slow", "AEGIS_S3_EXPECTED_SHA256": hashlib.sha256(BODY).hexdigest(),
           "AEGIS_S3_SLOW_SHA256": hashlib.sha256(bytes(409600)).hexdigest(),
           "AEGIS_ACCESS_LOCAL_V2RAY_CONFIG": str(config), "AEGIS_ACCESS_LOCAL_V2RAY_LIVE": "1",
           "AEGIS_ACCESS_PAGE_URL": f"https://localhost:{rt.target}/page"}
    target = rt.root / "native.env"
    target.write_text("".join(f"export {k}={shlex.quote(v)}\n" for k, v in env.items()))
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", required=True, type=Path)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    os.umask(0o077)
    with args.receipt.open("x") as evidence, tempfile.TemporaryDirectory(prefix="native-") as tmp, contextlib.ExitStack() as stack:
        root = Path(tmp)
        rt = NativeRuntime(root, stack, args.client.resolve(), args.server.resolve(), root / "meter.sock")
        rt.setup()
        for name in ("a", "b"):
            account_command(rt, "bind", name, PERIOD)
        print(json.dumps({"env": str(private_env(rt)), "ca": str(rt.root / "cert.pem"), "pid": os.getpid()}), flush=True)
        stop.wait(540)  # Stop before temporary provisioning expires.
        result = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                  "node": NODE, "period": PERIOD, "targetEvents": rt.native.events,
                  "meter": rt.usage(), "entitlements": {n: entitlement(rt, n) for n in ("a", "b")}}
        print(json.dumps(result), file=evidence)


if __name__ == "__main__":
    main()
