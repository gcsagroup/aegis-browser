"""Exercise the current-account HTTP endpoint against controlled durable data."""

import hashlib
import http.client
import json
from pathlib import Path
import secrets
import sqlite3
from tempfile import TemporaryDirectory
import threading
import unittest

from services.access_account.server import create_server


SCHEMA = Path(__file__).resolve().parents[1] / "schema.sql"
ROUTE = "/v1/me/entitlement"
NOW = 1_800_000_000_000
QUOTA = 9_007_199_254_740_997
DETAILS = ("planId", "periodId", "periodStart", "periodEnd", "expiresAt",
           "quotaBytes", "uploadedBytes", "downloadedBytes", "usedBytes",
           "remainingBytes", "measuredAt", "receivedAt", "snapshotAgeMs", "freshness")


class EntitlementHTTPTest(unittest.TestCase):
    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "accounts.sqlite"
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript(SCHEMA.read_text())
        self.tokens = {}
        for account in ("A", "B", "empty", "expired"):
            self.db.execute("INSERT INTO accounts(id) VALUES (?)", (account,))
            self.tokens[account] = self.session(account)
        self.plan("A", QUOTA, 65_539, 97)
        self.plan("B", 1_011, 1_010, 17)
        self.plan("expired", 4_009, 101, 2, expiry=NOW)
        self.db.commit()
        self.server = create_server(self.path, clock_ms=lambda: NOW)
        self.addCleanup(self.server.server_close)
        worker = threading.Thread(target=self.server.serve_forever,
                                  kwargs={"poll_interval": 0.02}, daemon=True)
        worker.start()
        self.addCleanup(worker.join)
        self.addCleanup(self.server.shutdown)

    def session(self, account, expiry=NOW + 600_000):
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode("ascii")).digest()
        self.db.execute(
            "INSERT INTO sessions(token_hash,account_id,expires_at,revoked_at) VALUES (?,?,?,?)",
            (digest, account, expiry, None))
        return token

    def plan(self, account, quota, uploaded, downloaded, expiry=NOW + 420_000):
        period = "period-" + account
        self.db.execute(
            "INSERT INTO plans(account_id,plan_id,period_id,period_start,period_end,panel_client)"
            " VALUES (?,?,?,?,?,?)",
            (account, "plan-" + account, period, NOW - 888_000, NOW + 900_000, "panel-" + account))
        self.db.execute(
            "INSERT INTO snapshots(account_id,period_id,quota_bytes,uploaded_bytes,downloaded_bytes,"
            "expires_at,measured_at,received_at) VALUES (?,?,?,?,?,?,?,?)",
            (account, period, quota, uploaded, downloaded, expiry, NOW - 2_001, NOW - 100))

    def client(self):
        client = http.client.HTTPConnection(*self.server.server_address[:2], timeout=4)
        self.addCleanup(client.close)
        return client

    def query(self, client, token=None, path=ROUTE):
        headers = {} if token is None else {"Authorization": "Bearer " + token}
        client.request("GET", path, headers=headers)
        response = client.getresponse()
        self.assertIn("no-store", (response.getheader("Cache-Control") or "").lower().split(", "))
        return response.status, json.loads(response.read())

    def ok(self, client, account):
        status, data = self.query(client, self.tokens[account])
        self.assertEqual(status, 200)
        self.assertEqual(data["entitlementAccountId"], account)
        return data

    def test_two_authenticated_clients_and_switch_on_same_url(self):
        first, second = self.client(), self.client()
        a = self.ok(first, "A")
        expected = dict(status="active", planId="plan-A", periodId="period-A",
                        periodStart=NOW - 888_000, periodEnd=NOW + 900_000, expiresAt=NOW + 420_000,
                        quotaBytes=str(QUOTA), uploadedBytes="65539", downloadedBytes="97",
                        usedBytes="65636", remainingBytes=str(QUOTA - 65_636),
                        measuredAt=NOW - 2_001, receivedAt=NOW - 100,
                        snapshotAgeMs=2_001, freshness="current")
        self.assertEqual({key: a[key] for key in expected}, expected)
        b = self.ok(second, "B")
        self.assertEqual((b["status"], b["quotaBytes"], b["usedBytes"], b["remainingBytes"]),
                         ("exhausted", "1011", "1027", "0"))
        self.assertEqual(self.ok(first, "B"), b)
        self.assertEqual(self.ok(second, "A"), a)
        self.assertEqual(self.ok(first, "A"), a)
        status, _ = self.query(first, self.tokens["A"], ROUTE + "?account=B")
        self.assertGreaterEqual(status, 400)

    def test_exact_exhaustion_without_overage(self):
        self.db.execute("UPDATE snapshots SET downloaded_bytes=1 WHERE account_id='B'")
        self.db.commit()
        data = self.ok(self.client(), "B")
        self.assertEqual((data["status"], data["usedBytes"], data["remainingBytes"]),
                         ("exhausted", "1011", "0"))

    def test_unsubscribed_and_expired(self):
        client = self.client()
        data = self.ok(client, "empty")
        self.assertEqual(data["status"], "not_subscribed")
        self.assertEqual({key: data[key] for key in DETAILS}, dict.fromkeys(DETAILS))
        expired = self.ok(client, "expired")
        self.assertEqual((expired["status"], expired["expiresAt"], expired["remainingBytes"]),
                         ("expired", NOW, "3906"))

    def test_measurement_watermark_is_independent_of_receipt_time_and_business_status(self):
        client = self.client()
        for age, freshness in [(5_000, "current"), (5_001, "delayed"), (15_000, "delayed"),
                               (15_001, "unavailable"), (None, "unavailable")]:
            with self.subTest(age=age):
                measured = None if age is None else NOW - age
                self.db.execute("UPDATE snapshots SET measured_at=? WHERE account_id='A'", (measured,))
                self.db.commit()
                data = self.ok(client, "A")
                self.assertEqual((data["status"], data["freshness"], data["snapshotAgeMs"],
                                  data["measuredAt"], data["receivedAt"], data["usedBytes"]),
                                 ("active", freshness, age, measured, NOW - 100, "65636"))

    def test_missing_snapshot_and_database_failure_do_not_replay_previous_success(self):
        client = self.client()
        self.ok(client, "A")
        self.db.execute("DELETE FROM snapshots WHERE account_id='A'")
        self.db.commit()
        failure = (503, {"error": "entitlement_unavailable"})
        self.assertEqual(self.query(client, self.tokens["A"]), failure)
        self.ok(client, "B")
        self.db.execute("ALTER TABLE snapshots RENAME TO offline_snapshots")
        self.db.commit()
        self.assertEqual(self.query(client, self.tokens["B"]), failure)

    def test_session_must_remain_valid_on_each_request(self):
        client = self.client()
        self.ok(client, "A")
        expired = self.session("A", expiry=NOW)
        self.db.execute("UPDATE sessions SET revoked_at=? WHERE account_id='A' AND expires_at>?",
                        (NOW, NOW))
        self.db.commit()
        for label, token in [("missing", None), ("unknown", secrets.token_urlsafe(32)),
                             ("expired", expired), ("revoked", self.tokens["A"])]:
            with self.subTest(credential=label):
                self.assertEqual(self.query(client, token), (401, {"error": "unauthorized"}))
        self.ok(client, "B")


if __name__ == "__main__":
    unittest.main()
