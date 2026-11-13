"""Loopback entitlement entry point with an opt-in managed node credential issuer."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import time

from . import credentials, orders, store
from .panel import Panel


_PATH = "/v1/me/entitlement"
_CREDENTIAL_PATH = "/v1/me/node-credentials"
_ORDER_PATH = "/v1/me/orders/redeem"
_BEARER = re.compile(r"Bearer ([A-Za-z0-9_-]{1,256})", re.ASCII | re.IGNORECASE)


class _Handler(BaseHTTPRequestHandler):
    def _bearer_token(self):
        values = self.headers.get_all("Authorization", [])
        match = _BEARER.fullmatch(values[0]) if len(values) == 1 else None
        return match[1] if match else None

    def _credential_request(self, deleting=False, renew_id=None):
        if self.request_version == "HTTP/0.9":
            self.close_connection = True
            return
        target = self.requestline.split()[1]
        suffix = target[len(_CREDENTIAL_PATH) + 1:]
        valid = (target.startswith(_CREDENTIAL_PATH + "/") and credentials._uuid(suffix)
                 if deleting else renew_id is not None or target == _CREDENTIAL_PATH)
        if not valid or self.server.managed_node is None:
            self._json(404, {"error": "not_found"})
            return
        token = self._bearer_token()
        if token is None:
            self._json(401, {"error": "unauthorized"})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if (self.headers.get_all("Transfer-Encoding")
                or deleting and lengths not in ([], ["0"])
                or not deleting and (len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,4}", lengths[0])
                                     or not 1 <= int(lengths[0]) <= 1024)):
            self._json(400, {"error": "invalid_request"})
            return
        try:
            if deleting:
                valid_session = credentials.revoke(self.server.database_path, token, suffix,
                                                   self.server.clock_ms)
                self._json(200 if valid_session else 401,
                           {} if valid_session else {"error": "unauthorized"})
                return
            if self.headers.get_all("Content-Type", []) != ["application/json"]:
                raise ValueError
            self.connection.settimeout(5)
            body = self.rfile.read(int(lengths[0]))
            if len(body) != int(lengths[0]):
                raise ValueError
            def unique(pairs):
                result = {}
                for key, value in pairs:
                    if key in result:
                        raise ValueError
                    result[key] = value
                return result
            data = json.loads(body, object_pairs_hook=unique)
            if not isinstance(data, dict) or set(data) != {"contextId", "mode"}:
                raise ValueError
            result = credentials.issue(self.server.database_path, token, data["contextId"],
                                       data["mode"], self.server.clock_ms,
                                       node=self.server.managed_node, panel=self.server.panel,
                                       renew_id=renew_id)
        except (ValueError, RecursionError, OSError):
            self._json(400, {"error": "invalid_request"})
            return
        except store.Unavailable:
            self._json(503, {"error": "credentials_unavailable"})
            return
        if result is None:
            self._json(401, {"error": "unauthorized"})
        elif not result:
            self._json(403, {"error": "not_entitled"})
        else:
            self._json(200, result)

    def do_POST(self):
        target = self.requestline.split()[1]
        if target == _ORDER_PATH:
            self._redeem_order()
        elif target == _CREDENTIAL_PATH:
            self._credential_request()
        elif target.startswith(_CREDENTIAL_PATH + "/") and target.endswith("/renew"):
            identifier = target[len(_CREDENTIAL_PATH) + 1:-len("/renew")]
            if credentials._uuid(identifier):
                self._credential_request(renew_id=identifier)
            else:
                self._json(404, {"error": "not_found"})
        else:
            self._json(404, {"error": "not_found"})

    def _redeem_order(self):
        if (self.request_version == "HTTP/0.9"
                or self.requestline.split()[1] != _ORDER_PATH
                or not self.server.sandbox_orders):
            self._json(404, {"error": "not_found"})
            return
        token = self._bearer_token()
        if token is None:
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
            receipt = orders.redeem(self.server.database_path, token, pairs[0][1],
                                    self.server.clock_ms)
        except orders.Rejected:
            self._json(409, {"error": "order_unavailable"})
        except store.Unavailable:
            self._json(503, {"error": "entitlement_unavailable"})
        else:
            self._json(401 if receipt is None else 200,
                       {"error": "unauthorized"} if receipt is None else receipt)

    def do_DELETE(self):
        self._credential_request(deleting=True)

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
        token = self._bearer_token()
        if token is None:
            self._json(401, {"error": "unauthorized"})
            return
        try:
            snapshot = store.read_current(self.server.database_path, token, self.server.clock_ms,
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
                  managed_node=None, sandbox_orders=False):
    """Bind an IPv4 loopback listener; serve_forever is owned by the caller."""
    if host != "127.0.0.1":
        raise ValueError("only the numeric loopback host 127.0.0.1 is supported")
    if sandbox_orders:
        if panel is not None:
            raise ValueError("sandbox orders require stored snapshots; panel writes are unsupported")
        orders.migrate(database_path)
    if managed_node is not None:
        if not isinstance(managed_node, credentials.ManagedNode):
            raise ValueError("invalid managed node configuration")
        credentials.migrate(database_path)
    server = ThreadingHTTPServer((host, port), _Handler)
    server.database_path = database_path
    server.clock_ms = clock_ms
    server.panel = panel
    server.sandbox_orders = sandbox_orders
    server.managed_node = managed_node
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
    parser.add_argument("--alpha-panel-client",
                        help="opt in to a single Alpha panel client, allowing no panel expiry")
    parser.add_argument("--node-config", help="enable issuance using the JSON file passed to node --config")
    parser.add_argument("--node-host", help="operator-selected TLS CONNECT hostname (no URI)")
    parser.add_argument("--node-port", type=int)
    parser.add_argument("--node-ttl-ms", type=int, default=60_000)
    args = parser.parse_args()
    if args.alpha_panel_client is not None and (
            not args.panel_url or args.stored_snapshots or args.sandbox_orders):
        parser.error("--alpha-panel-client requires --panel-url without stored snapshots or sandbox orders")
    if args.sandbox_orders and not args.stored_snapshots:
        parser.error("--sandbox-orders requires --stored-snapshots")
    try:
        panel = (Panel(args.panel_url, os.environ.get("AEGIS_3XUI_TOKEN"),
                       alpha_panel_client=args.alpha_panel_client) if args.panel_url else None)
        node = None
        if any(value is not None for value in (args.node_config, args.node_host, args.node_port)):
            if args.node_config is None:
                raise ValueError("--node-config is required for managed node issuance")
            try:
                config = json.loads(Path(args.node_config).read_text())
            except (OSError, ValueError, RecursionError):
                raise ValueError("invalid managed node configuration") from None
            node = credentials.ManagedNode.from_config(config, args.node_host, args.node_port,
                                                       args.node_ttl_ms)
    except ValueError as error:
        parser.error(str(error))
    with create_server(args.database, port=args.port, panel=panel, managed_node=node,
                       sandbox_orders=args.sandbox_orders) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
