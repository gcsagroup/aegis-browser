"""Two owned loopback HTTPS origins for the opt-in iOS campaign simulator test."""

import argparse
import ctypes
import json
import ssl
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Event, Lock, Thread
from urllib.parse import parse_qs, urlsplit


LOG_LOCK = Lock()
REQUESTS = {}
CONTINUOUS_TICKS = ctypes.CDLL(None).mach_continuous_time
CONTINUOUS_TICKS.restype = ctypes.c_uint64


def receipt(origin, event, **fields):
    with LOG_LOCK:
        print(json.dumps(dict(origin=origin, event=event, **fields), sort_keys=True), flush=True)


class Origin(ThreadingHTTPServer):
    def __init__(self, origin, certificate, key):
        super().__init__(("127.0.0.1", 0), Handler)
        self.origin = origin
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls.set_alpn_protocols(["http/1.1"])
        self.tls.load_cert_chain(certificate, key)

    def finish_request(self, request, client_address):
        request.settimeout(12)
        receipt(self.origin, "tcp-accepted")
        try:
            wrapped = self.tls.wrap_socket(request, server_side=True)
        except (ssl.SSLError, TimeoutError):
            receipt(self.origin, "tls-not-established")
            return
        with wrapped:
            receipt(self.origin, "tls-established")
            super().finish_request(wrapped, client_address)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        target = urlsplit(self.path)
        path = target.path
        nonce = parse_qs(target.query).get("nonce", [""])[0]
        if len(nonce) != 32 or any(char not in "0123456789abcdef" for char in nonce):
            self.send_error(400)
            return
        at_ticks = CONTINUOUS_TICKS()
        with LOG_LOCK:
            REQUESTS.setdefault(nonce, []).append({"path": path, "atTicks": at_ticks})
        receipt(self.server.origin, "request", path=path, nonce=nonce, atTicks=at_ticks)
        if path in {"/no-response", "/held-image"}:
            time.sleep(8)
            return
        if path == "/slow-resource":
            self.send_html(f"<!doctype html><title>Owned fixture</title><img src='/held-image?nonce={nonce}' alt=''>".encode())
        elif path == "/finished":
            self.send_html(b"<!doctype html><title>Owned fixture</title><p>Complete</p>")
        else:
            self.send_error(404)

    def send_html(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        receipt(self.server.origin, "response", status=200)


class ReceiptHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        nonce = urlsplit(self.path).path.removeprefix("/receipt/")
        with LOG_LOCK:
            paths = list(REQUESTS.get(nonce, []))
        body = json.dumps(paths).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture_directory", type=Path)
    options = parser.parse_args()
    directory = options.fixture_directory
    with Origin("trusted", directory / "trusted.pem", directory / "trusted.key") as trusted, \
            Origin("untrusted", directory / "untrusted.pem", directory / "untrusted.key") as untrusted, \
            ThreadingHTTPServer(("127.0.0.1", 0), ReceiptHandler) as receipts:
        with (directory / "ports.json").open("x") as ports:
            json.dump({"trusted": trusted.server_port, "untrusted": untrusted.server_port,
                       "receipts": receipts.server_port}, ports)
        servers = (trusted, untrusted, receipts)
        for server in servers:
            Thread(target=server.serve_forever, daemon=True).start()
        try:
            Event().wait()
        except KeyboardInterrupt:
            for server in servers:
                server.shutdown()


if __name__ == "__main__":
    main()
