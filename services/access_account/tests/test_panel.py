"""Integration contract for authenticated reads through a controlled 3X-UI 3.11.0 panel."""

from contextlib import closing
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
from tempfile import TemporaryDirectory
import threading
import unittest

from services.access_account.panel import Panel
from services.access_account.server import create_server
from services.access_account.tests.test_http import NOW, ROUTE, SCHEMA


PREFIX = "/tenant/panel/api/clients/traffic/"
SETTINGS = "/tenant/panel/api/clients/get/"
FAILURE = (503, {"error": "entitlement_unavailable"})
A, B = "client+a", "client@b"


def traffic(client, up, down, total):
    return dict(email=client, up=up, down=down, total=total, expiryTime=NOW + 1000,
                enable=True, reset=0, resetDay=0, resetWeekday=0)


class PanelHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        panel = self.server
        panel.paths.append(self.path)
        status, body = panel.status, panel.body
        if self.headers.get_all("Authorization") != ["Bearer fixture-panel-key"]:
            status, body = 401, b"invalid credential"
        elif self.path in panel.settings and body is None:
            body = json.dumps({"success": True, "obj": {"client": panel.settings[self.path]}}).encode()
        elif self.path not in panel.rows:
            status, body = 404, b"wrong scoped route"
        elif body is None:
            body = json.dumps({"success": True, "obj": panel.rows[self.path]}).encode()
        if panel.during_read:
            panel.during_read()
        self.send_response(status)
        if status == 302:
            self.send_header("Location", PREFIX + "client%40b")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class PanelEntitlementTest(unittest.TestCase):
    def start(self, server):
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        return server

    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "accounts.db"
        with closing(sqlite3.connect(self.path)) as db:
            db.executescript(SCHEMA.read_text())
            for account, client in [("A", A), ("B", B), ("empty", None)]:
                digest = hashlib.sha256(("token-" + account).encode()).digest()
                db.execute("INSERT INTO accounts VALUES (?)", (account,))
                db.execute("INSERT INTO sessions VALUES (?,?,?,NULL)", (digest, account, NOW + 10000))
                if client:
                    db.execute("INSERT INTO plans VALUES (?,?,?,?,?,?)",
                               (account, "plan-" + account, "p1", NOW - 500, NOW + 2000, client))
            db.commit()
        self.mock = self.start(ThreadingHTTPServer(("127.0.0.1", 0), PanelHandler))
        self.a = traffic(A, 2**53 + 1, 89, 2**53 + 133)
        self.b = traffic(B, 17, 994, 1009)
        self.mock.rows = {PREFIX + "client%2Ba": self.a, PREFIX + "client%40b": self.b}
        self.mock.settings = {
            path.replace(PREFIX, SETTINGS): dict(row, totalGB=row["total"], trafficReset="never")
            for path, row in self.mock.rows.items()
        }
        self.mock.paths, self.mock.status, self.mock.body, self.mock.during_read = [], 200, None, None
        panel = Panel(f"http://127.0.0.1:{self.mock.server_port}/tenant/", "fixture-panel-key")
        server = self.start(create_server(self.path, clock_ms=lambda: NOW, panel=panel))
        self.http = http.client.HTTPConnection(*server.server_address, timeout=4)
        self.addCleanup(self.http.close)

    def read(self, account="A", path=ROUTE):
        self.http.request("GET", path, headers={"Authorization": "Bearer token-" + account})
        response = self.http.getresponse()
        self.assertEqual(response.getheader("Cache-Control"), "no-store")
        return response.status, json.loads(response.read())

    def test_current_client_and_current_read_own_the_numbers(self):
        keys = ("entitlementAccountId", "planId", "status", "uploadedBytes", "downloadedBytes",
                "quotaBytes", "usedBytes", "remainingBytes")
        for account, expected in [
            ("A", ("A", "plan-A", "active", "9007199254740993", "89", "9007199254741125",
                   "9007199254741082", "43")),
            ("B", ("B", "plan-B", "exhausted", "17", "994", "1009", "1011", "0")),
            ("A", ("A", "plan-A", "active", "9007199254740993", "90", "9007199254741125",
                   "9007199254741083", "42")),
        ]:
            status, data = self.read(account)
            self.assertEqual(status, 200)
            self.assertEqual(tuple(data[k] for k in keys), expected)
            self.assertEqual((data["receivedAt"], data["measuredAt"], data["snapshotAgeMs"],
                              data["freshness"]), (NOW, None, None, "unavailable"))
            self.a["down"] = 90
        self.assertEqual(self.read("A", ROUTE + "?account=B")[0], 404)
        self.assertEqual(self.read("unknown")[0], 401)
        self.assertEqual(self.read("empty")[1]["status"], "not_subscribed")
        self.assertEqual(self.mock.paths, [route + client for client in
                                          ("client%2Ba", "client%40b", "client%2Ba")
                                          for route in (PREFIX, SETTINGS)])

    def test_failed_read_never_replays_success_or_follows_redirect(self):
        self.assertEqual(self.read()[0], 200)
        for status, body in [(401, b"bad token"), (503, b"private detail"), (302, b""),
                             (200, b"not json"), (200, b'{"success":false}'),
                             (200, b'{"success":true,"obj":null}'),
                             (200, json.dumps({"success": True, "obj": self.b}).encode())]:
            with self.subTest(status=status, body=body):
                self.mock.status, self.mock.body = status, body
                self.assertEqual(self.read(), FAILURE)
        self.assertEqual(self.mock.paths.count(PREFIX + "client%2Ba"), 8)
        self.assertTrue(all(path.endswith("client%2Ba") for path in self.mock.paths))

    def test_only_finite_dedicated_plan_and_valid_integer_counters(self):
        account = self.mock.settings[SETTINGS + "client%2Ba"]
        for field, value in [("enable", False), ("totalGB", 0), ("expiryTime", 0), ("reset", 1),
                             ("reset", False), ("resetDay", 7), ("resetWeekday", 2),
                             ("trafficReset", "daily"), ("totalGB", "42")]:
            with self.subTest(field=field):
                self.mock.settings[SETTINGS + "client%2Ba"] = dict(account, **{field: value})
                self.assertEqual(self.read(), FAILURE)
        self.mock.settings[SETTINGS + "client%2Ba"] = account
        for field, value in [("enable", False), ("up", -1), ("up", True),
                             ("down", 3.5), ("up", 2**63)]:
            with self.subTest(field=field):
                self.mock.rows[PREFIX + "client%2Ba"] = dict(self.a, **{field: value})
                self.assertEqual(self.read(), FAILURE)
        self.mock.rows[PREFIX + "client%2Ba"] = dict(self.a, total=0, expiryTime=0)
        self.assertEqual(self.read()[1]["quotaBytes"], str(account["totalGB"]))
        for extra, expected in [({"expiryTime": NOW}, "expired"), ({"totalGB": 1}, "exhausted")]:
            self.mock.settings[SETTINGS + "client%2Ba"] = dict(account, enable=False, **extra)
            self.assertEqual(self.read()[1]["status"], expected)

    def test_rechecks_session_and_plan_after_upstream_response(self):
        for sql, expected in [
            ("UPDATE plans SET period_end=period_end+1 WHERE account_id='A'", FAILURE),
            ("UPDATE sessions SET revoked_at=1 WHERE account_id='A'", (401, {"error": "unauthorized"})),
        ]:
            with self.subTest(sql=sql):
                def mutate():
                    with closing(sqlite3.connect(self.path)) as db:
                        db.execute(sql)
                        db.commit()
                self.mock.during_read = mutate
                self.assertEqual(self.read(), expected)
