"""Loopback entitlement entry point with opt-in trusted sandbox redemption."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import re
import time

from . import orders, store
from .panel import Panel


_PATH = "/v1/me/entitlement"
_BEARER = re.compile(r"Bearer ([A-Za-z0-9_-]{1,256})", re.ASCII | re.IGNORECASE)


class _Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # BaseHTTPRequestHandler logs untrusted request targets, including query strings.
        pass

    def _json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if status == 401:
            self.send_header("WWW-Authenticate", "Bearer")
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        # Keep parser and unsupported-method failures private and uncacheable too.
        self._json(code, {"error": "invalid_request"})

    def do_POST(self):
        if (self.request_version == "HTTP/0.9"
                or self.requestline.split()[1] != "/v1/me/orders/redeem"
                or not self.server.sandbox_orders):
            self._json(404, {"error": "not_found"})
            return
        credentials = self.headers.get_all("Authorization", [])
        match = _BEARER.fullmatch(credentials[0]) if len(credentials) == 1 else None
        if match is None:
            self._json(401, {"error": "unauthorized"})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if (self.headers.get_all("Transfer-Encoding") or len(lengths) != 1
                or not re.fullmatch(r"[0-9]{1,4}", lengths[0])
                or not 1 <= int(lengths[0]) <= 1024
                or self.headers.get_all("Content-Type") != ["application/json"]):
            self._json(400, {"error": "invalid_request"})
            return
        try:
            self.connection.settimeout(5)
            body = self.rfile.read(int(lengths[0]))
            if len(body) != int(lengths[0]):
                raise ValueError("incomplete request body")
            pairs = json.loads(body, object_pairs_hook=list)
            if (not isinstance(pairs, list) or len(pairs) != 1
                    or not isinstance(pairs[0], tuple) or pairs[0][0] != "orderId"
                    or not isinstance(pairs[0][1], str) or not 1 <= len(pairs[0][1]) <= 128):
                raise ValueError("expected only orderId")
            # JSON escapes may decode to lone surrogates which SQLite cannot bind.
            pairs[0][1].encode("utf-8")
        except (ValueError, UnicodeError, OSError, RecursionError):
            self._json(400, {"error": "invalid_request"})
            return
        try:
            receipt = orders.redeem(self.server.database_path, match[1], pairs[0][1],
                                    self.server.clock_ms)
        except orders.Rejected:
            self._json(409, {"error": "order_unavailable"})
        except store.Unavailable:
            self._json(503, {"error": "entitlement_unavailable"})
        else:
            self._json(401 if receipt is None else 200,
                       {"error": "unauthorized"} if receipt is None else receipt)

    def do_GET(self):
        if self.request_version == "HTTP/0.9":
            # Such a response cannot carry the required no-store header.
            self.close_connection = True
            return
        # BaseHTTPRequestHandler normalizes a leading "//"; require the wire target.
        if self.requestline.split()[1] != _PATH:
            self._json(404, {"error": "not_found"})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if self.headers.get_all("Transfer-Encoding") or lengths not in ([], ["0"]):
            self._json(400, {"error": "invalid_request"})
            return
        credentials = self.headers.get_all("Authorization", [])
        match = _BEARER.fullmatch(credentials[0]) if len(credentials) == 1 else None
        if match is None:
            self._json(401, {"error": "unauthorized"})
            return
        try:
            snapshot = store.read_current(self.server.database_path, match[1], self.server.clock_ms,
                                          panel=self.server.panel)
        except store.Unavailable:
            self._json(503, {"error": "entitlement_unavailable"})
            return
        if snapshot is None:
            self._json(401, {"error": "unauthorized"})
        else:
            self._json(200, snapshot)


def _utc_ms():
    return time.time_ns() // 1_000_000


def create_server(database_path, *, host="127.0.0.1", port=0, clock_ms=_utc_ms, panel=None,
                  sandbox_orders=False):
    """Bind an IPv4 loopback listener; serve_forever is owned by the caller."""
    if host != "127.0.0.1":
        raise ValueError("only the numeric loopback host 127.0.0.1 is supported")
    if sandbox_orders:
        if panel is not None:
            raise ValueError("sandbox orders require stored snapshots; panel writes are unsupported")
        orders.migrate(database_path)
    server = ThreadingHTTPServer((host, port), _Handler)
    server.database_path = database_path
    server.clock_ms = clock_ms
    server.panel = panel
    server.sandbox_orders = sandbox_orders
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", required=True)
    parser.add_argument("--port", type=int, required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--panel-url", help="3X-UI base URL including any panel path prefix")
    source.add_argument("--stored-snapshots", action="store_true", help="read provisioned snapshots offline")
    parser.add_argument("--sandbox-orders", action="store_true",
                        help="enable trusted local order redemption (stored snapshots only)")
    args = parser.parse_args()
    if args.sandbox_orders and not args.stored_snapshots:
        parser.error("--sandbox-orders requires --stored-snapshots")
    try:
        panel = Panel(args.panel_url, os.environ.get("AEGIS_3XUI_TOKEN")) if args.panel_url else None
    except ValueError as error:
        parser.error(str(error))
    with create_server(args.database, port=args.port, panel=panel,
                       sandbox_orders=args.sandbox_orders) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
