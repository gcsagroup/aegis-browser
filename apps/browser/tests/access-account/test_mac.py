"""Native macOS Access transport, session isolation and late response regressions."""
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from uuid import uuid4

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT))
from services.access_account.server import create_server

OVERLAY = ROOT / "apps/browser/overlay"
NOW = 1_800_000_000_000
QUOTA = 9_007_199_254_740_997


@unittest.skipUnless(sys.platform == "darwin", "requires the native macOS Foundation transport")
class NativeQuery(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scratch = tempfile.TemporaryDirectory()
        cls.addClassCleanup(scratch.cleanup)
        cls.driver = Path(scratch.name) / "query"
        subprocess.run(["xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-Wall", "-Werror",
                        "-I", str(OVERLAY), "-framework", "Foundation", "-o", str(cls.driver),
                        str(Path(__file__).with_name("query_mac.mm")),
                        str(OVERLAY / "chrome/browser/aegis/access/access_account_mac.mm")], check=True)

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.a = self.root / "Default"
        self.b = self.root / "Profile 1"
        self.a.mkdir()
        self.b.mkdir()
        self.dbfile = self.root / "db"
        self.db = sqlite3.connect(self.dbfile)
        self.addCleanup(self.db.close)
        self.db.executescript((ROOT / "services/access_account/schema.sql").read_text())
        for account in ("A", "B"):
            self.db.execute("INSERT INTO accounts VALUES (?)", (account,))
            self.db.execute("INSERT INTO sessions VALUES (?,?,?,NULL)",
                            (hashlib.sha256(("test-" + account).encode()).digest(), account, NOW + 30000))
        self.db.execute("INSERT INTO plans VALUES ('A','plan-A','period-A',?,?, 'panel-A')",
                        (NOW - 10000, NOW + 10000))
        self.db.execute("INSERT INTO snapshots VALUES ('A','period-A',?,11,13,?,?,?)",
                        (QUOTA, NOW + 20000, NOW - 6000, NOW - 100))
        self.db.commit()
        self.origin = self.serve(create_server(self.dbfile, clock_ms=lambda: NOW))

    def serve(self, server):
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        return "http://127.0.0.1:" + str(server.server_address[1])

    def bind(self, profile, who="A", origin=None):
        path = profile / "AegisAccessAccount.json"
        temp = profile / str(uuid4())
        temp.touch(mode=0o600)
        temp.write_text(json.dumps(dict(accountId=who, token="test-" + who, generation=temp.name,
                                        origin=origin or self.origin)))
        temp.replace(path)
        return path

    def query(self, profile):
        p = subprocess.run([self.driver, profile], check=True, capture_output=True, timeout=15)
        return json.loads(p.stdout)

    def test_service_two_profiles_signout_and_revocation(self):
        self.bind(self.a)
        self.bind(self.b, "B")
        a = self.query(self.a)["entitlement"]
        self.assertEqual((a["entitlementAccountId"], a["quotaBytes"], a["remainingBytes"],
                          a["freshness"]), ("A", str(QUOTA), str(QUOTA - 24), "delayed"))
        self.assertGreaterEqual(a["snapshotAgeMs"], 6000)
        b = self.query(self.b)["entitlement"]
        self.assertEqual((b["entitlementAccountId"], b["status"], b["quotaBytes"]), ("B", "not_subscribed", None))
        self.bind(self.a, "B")
        self.assertEqual(self.query(self.a)["entitlement"], b)
        (self.a / "AegisAccessAccount.json").unlink()
        self.assertEqual(self.query(self.a), {"state": "signed_out"})
        self.db.execute("UPDATE sessions SET revoked_at=? WHERE account_id='B'", (NOW,))
        self.db.commit()
        self.assertEqual(self.query(self.b), {"state": "signed_out"})

    def test_inflight_switch_back_and_signout_discard_response(self):
        entered, release = threading.Event(), threading.Event()

        class Slow(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                entered.set()
                release.wait(3)
                self.send_response(401)
                self.end_headers()

        origin = self.serve(ThreadingHTTPServer(("127.0.0.1", 0), Slow))
        for action, wanted in (("switch", "superseded"), ("switch_back", "superseded"), ("delete", "signed_out")):
            entered.clear()
            release.clear()
            path = self.bind(self.a, origin=origin)
            with subprocess.Popen([self.driver, self.a], stdout=subprocess.PIPE) as p:
                try:
                    self.assertTrue(entered.wait(3))
                    if action == "delete":
                        path.unlink()
                    else:
                        self.bind(self.a, "B", origin)
                        if action == "switch_back":
                            self.bind(self.a, "A", origin)
                finally:
                    release.set()
                self.assertEqual(json.loads(p.communicate(timeout=8)[0]), {"state": wanted})

    def test_binding_changes_after_service_response_before_delivery(self):
        for action in ("switch", "switch_back", "sign_out"):
            with self.subTest(action=action):
                path = self.bind(self.a)
                with subprocess.Popen([self.driver, self.a, "--hold-delivery"],
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE) as job:
                    try:
                        self.assertEqual(job.stdout.readline(), b"queued\n")
                        if action == "sign_out":
                            path.unlink()
                        else:
                            self.bind(self.a, "B")
                            if action == "switch_back":
                                self.bind(self.a, "A")
                    finally:
                        output, _ = job.communicate(b"deliver\n", timeout=10)
                    self.assertEqual(job.returncode, 0)
                    state = "signed_out" if action == "sign_out" else "superseded"
                    self.assertEqual(json.loads(output), {"state": state})

    def test_sign_in_after_missing_binding_before_delivery(self):
        with subprocess.Popen([self.driver, self.a, "--hold-delivery"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE) as job:
            self.assertEqual(job.stdout.readline(), b"queued\n")
            self.bind(self.a)
            output, _ = job.communicate(b"deliver\n", timeout=10)
        self.assertEqual(json.loads(output), {"state": "superseded"})

    def test_queued_reply_advances_age_and_freshness(self):
        self.bind(self.a)
        for age, expected in ((5000, "delayed"), (15000, "unavailable")):
            measured = NOW - age
            self.db.execute("UPDATE plans SET period_start=? WHERE account_id='A'", (NOW - 20000,))
            self.db.execute("UPDATE snapshots SET measured_at=? WHERE account_id='A'", (measured,))
            self.db.commit()
            with subprocess.Popen([self.driver, self.a, "--hold-delivery"],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE) as job:
                self.assertEqual(job.stdout.readline(), b"queued\n")
                time.sleep(.05)
                output, _ = job.communicate(b"deliver\n", timeout=10)
            reply = json.loads(output)["entitlement"]
            self.assertEqual(reply["measuredAt"], measured)
            self.assertGreater(reply["snapshotAgeMs"], age)
            self.assertEqual(reply["freshness"], expected)

    def test_redirect_modes_and_untrusted_binding(self):
        captured = []

        class Target(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                captured.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()

        target = self.serve(ThreadingHTTPServer(("127.0.0.1", 0), Target))

        class Redirect(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                self.send_response(307)
                self.send_header("Location", target + "/unexpected")
                self.end_headers()

        origin = self.serve(ThreadingHTTPServer(("127.0.0.1", 0), Redirect))
        path = self.bind(self.a, origin=origin)
        self.assertEqual(self.query(self.a), {"state": "unavailable"})
        self.assertFalse(captured)
        for unsafe in ("http://example.invalid", target + "?bad", "https://u:p@example.invalid"):
            self.bind(self.a, origin=unsafe)
            self.assertEqual(self.query(self.a), {"state": "unavailable"})
        path = self.bind(self.a)
        path.chmod(0o644)
        self.assertEqual(self.query(self.a), {"state": "unavailable"})
        path.unlink()
        path.symlink_to(self.bind(self.b, "B"))
        self.assertEqual(self.query(self.a), {"state": "unavailable"})

    def test_server_errors_and_malformed_or_cross_account_data(self):
        response = self.query_bound_snapshot()
        wire = [200, response]

        class Stub(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def do_GET(self):
                self.send_response(wire[0])
                self.end_headers()
                self.wfile.write(json.dumps(wire[1]).encode())

        origin = self.serve(ThreadingHTTPServer(("127.0.0.1", 0), Stub))
        self.bind(self.a, origin=origin)
        for change in ({"usedBytes": 24}, {"remainingBytes": "0"}, {"usedBytes": "024"},
                       {"entitlementAccountId": "B"}, {"freshness": "current"},
                       {"measuredAt": None}, {"periodEnd": False}, {"status": "expired"}):
            wire[1] = {**response, **change}
            self.assertEqual(self.query(self.a), {"state": "unavailable"}, change)
        wire[1] = {**response, "transportSecret": "fixture-must-not-be-exposed"}
        delivered = self.query(self.a)["entitlement"]
        self.assertGreaterEqual(delivered.pop("snapshotAgeMs"), response["snapshotAgeMs"])
        self.assertEqual(delivered, {k: v for k, v in response.items() if k != "snapshotAgeMs"})
        for age, freshness in ((0, "current"), (5000, "current"), (15000, "delayed"),
                               (15001, "unavailable"), (None, "unavailable")):
            measured = NOW if age is not None else None
            wire[1] = {**response, "receivedAt": NOW, "measuredAt": measured,
                       "snapshotAgeMs": age, "freshness": freshness}
            if age is not None and NOW + age >= wire[1]["periodEnd"]:
                wire[1]["status"] = "expired"
            delivered = self.query(self.a)["entitlement"]
            if age is None:
                self.assertEqual(delivered, wire[1])
            else:
                actual_age = delivered["snapshotAgeMs"]
                self.assertGreaterEqual(actual_age, age)
                expected_freshness = "current" if actual_age <= 5000 else "delayed" if actual_age <= 15000 else "unavailable"
                self.assertEqual(delivered, {**wire[1], "snapshotAgeMs": actual_age,
                                             "freshness": expected_freshness})
        wire[1] = {**response, "ignored": "x" * 65536}
        self.assertEqual(self.query(self.a), {"state": "unavailable"})
        wire[0] = 503
        self.assertEqual(self.query(self.a), {"state": "unavailable"})

    def query_bound_snapshot(self):
        self.bind(self.a)
        return self.query(self.a)["entitlement"]


if __name__ == "__main__":
    unittest.main()
