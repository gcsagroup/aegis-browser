"""Concurrency, retry and crash boundaries for the actual SQLite reservation authority."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import sqlite3
import tempfile
import unittest

from services.access_account import metering, quota, settlement


class QuotaTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db = Path(tmp.name) / "accounts.sqlite"
        self.now = 500
        self.cfg = dict(nodeId="node", upstreams={"client-a": 1080, "client-b": 1081})
        with sqlite3.connect(self.db) as db:
            db.executescript(Path(metering.__file__).with_name("schema.sql").read_text())
            for account in ("a", "b"):
                db.execute("INSERT INTO accounts VALUES (?)", (account,))
                db.execute(
                    "INSERT INTO plans VALUES (?, ?, ?, 100, 900, ?)",
                    (account, "paid", "p", "client-" + account),
                )
                db.execute(
                    "INSERT INTO snapshots VALUES (?, ?, 100, 0, 0, 900, 110, 110)", (account, "p")
                )
        for account in ("a", "b"):
            settlement.bind(self.db, self.cfg, account, "p", self.now)
        self.meter = quota.EnforcedMeter(self.db, self.cfg, lambda: self.now)
        for index, account in enumerate(("a", "a", "a", "b")):
            self.assertTrue(
                self.send(index, "open", client="client-" + account, mode="enforce")["ok"]
            )

    def send(self, index, op, **fields):
        return self.meter.accept(dict(v=1, flow=f"{index:032x}", op=op, **fields))

    def reserve(self, index, direction, count, ticket=1):
        path = "target_tcp" if direction == "up" else "vision_raw"
        return self.send(
            index, "reserve", direction=direction, ticket=ticket, path=path, bytes=count
        )

    def commit(self, index, direction, count, complete=True, ticket=1):
        return self.send(
            index, "commit", direction=direction, ticket=ticket, bytes=count, complete=complete
        )

    def test_competing_directions_fence_old_connections_even_across_refill(self):
        with ThreadPoolExecutor(2) as pool:
            jobs = [pool.submit(self.reserve, i, d, 80) for i, d in [(0, "up"), (1, "down")]]
            grants = [f.result()["granted"] for f in jobs]
        self.assertEqual(sorted(grants), [20, 80])
        self.assertFalse(self.send(2, "check")["ok"])
        for i, d in [(0, "up"), (1, "down")]:
            self.assertTrue(self.send(i, "check")["ok"])
            self.assertTrue(self.commit(i, d, grants[i])["ok"])
        self.assertTrue(self.reserve(3, "down", 42)["ok"])
        self.assertTrue(self.commit(3, "down", 42)["ok"])
        with self.assertRaises(ValueError):
            self.send(6, "open", mode="enforce", client="client-a")
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE snapshots SET quota_bytes=200 WHERE account_id='a'")
        self.assertFalse(self.send(0, "check")["ok"])
        self.assertFalse(self.send(1, "check")["ok"])
        self.assertTrue(self.send(6, "open", mode="enforce", client="client-a")["ok"])
        self.assertTrue(self.reserve(6, "up", 100)["ok"])
        self.assertEqual(quota.inspect(self.db, "a", "p")["confirmedBytes"], 100)
        self.assertEqual(quota.inspect(self.db, "b", "p")["confirmedBytes"], 42)

    def test_healthy_check_does_not_wait_for_another_accounts_writer(self):
        pool = ThreadPoolExecutor(1)
        try:
            with sqlite3.connect(self.db) as writer:
                writer.execute("BEGIN IMMEDIATE")
                writer.execute("UPDATE snapshots SET quota_bytes=200 WHERE account_id='a'")
                # The guard allows 250 ms for a check. A healthy B flow must be
                # readable while A holds the database's reserved writer lock.
                check = pool.submit(self.send, 3, "check")
                try:
                    self.assertEqual(check.result(timeout=0.2), {"ok": True, "expiresAt": 900})
                finally:
                    writer.rollback()
        finally:
            pool.shutdown(wait=True)

    def test_restart_holds_unknown_bytes_and_retains_final_receipts(self):
        self.assertEqual(self.reserve(0, "up", 80), self.reserve(0, "up", 80))
        self.meter = quota.EnforcedMeter(self.db, self.cfg, lambda: self.now)
        self.assertEqual(self.reserve(1, "down", 80)["granted"], 20)
        self.assertEqual(self.commit(0, "up", 65, False), self.commit(0, "up", 65, False))
        self.assertTrue(self.commit(1, "down", 12)["ok"])
        report = quota.inspect(self.db, "a", "p")
        self.assertEqual(
            [report[k] for k in ("grantedBytes", "heldBytes", "confirmedBytes", "releasedBytes")],
            [100, 15, 77, 8],
        )
        self.assertFalse(self.send(0, "check")["ok"])
        self.assertTrue(self.send(7, "open", mode="enforce", client="client-a")["ok"])
        self.assertEqual(self.reserve(7, "down", 25)["granted"], 8)
        self.assertEqual(quota.inspect(self.db, "a", "p")["heldBytes"], 23)

    def test_abort_lost_open_ack_cannot_erase_reserved_or_delivered_bytes(self):
        self.assertEqual(self.send(2, "abort"), {"ok": True})
        self.assertFalse(self.send(2, "check")["ok"])
        self.assertEqual(self.send(99, "abort"), {"ok": True})
        self.reserve(0, "up", 3)
        with self.assertRaises(ValueError):
            self.send(0, "abort")
        self.commit(0, "up", 3)
        with self.assertRaises(ValueError):
            self.send(0, "abort")
        self.assertEqual(quota.inspect(self.db, "a", "p")["confirmedBytes"], 3)

    def test_lost_reserve_ack_releases_only_a_known_unwritten_ticket(self):
        self.reserve(0, "up", 100)
        self.meter = quota.EnforcedMeter(self.db, self.cfg, lambda: self.now)
        cancel = dict(direction="up", ticket=1, path="target_tcp", bytes=100)
        self.assertEqual(self.send(0, "cancel", **cancel), {"ok": True})
        self.assertEqual(self.send(0, "cancel", **cancel), {"ok": True})
        self.send(0, "finish", uploadedBytes=0, downloadedBytes=0, complete=False)
        report = quota.inspect(self.db, "a", "p")
        self.assertEqual((report["heldBytes"], report["confirmedBytes"], report["releasedBytes"]),
                         (0, 0, 100))
        self.assertTrue(self.send(7, "open", client="client-a", mode="enforce")["ok"])
        self.assertFalse(self.reserve(0, "up", 100)["ok"])
        self.assertTrue(self.reserve(7, "up", 100)["ok"])

    def test_cancel_fences_a_late_reservation_without_erasing_prior_writes(self):
        cancel = dict(direction="up", ticket=1, path="target_tcp", bytes=100)
        self.send(0, "cancel", **cancel)
        self.assertFalse(self.reserve(0, "up", 100)["ok"])
        self.reserve(1, "up", 10)
        self.commit(1, "up", 10)
        with self.assertRaises(ValueError):
            self.send(1, "cancel", **cancel)
        self.assertEqual(quota.inspect(self.db, "a", "p")["confirmedBytes"], 10)
        self.send(1, "cancel", direction="up", ticket=2, path="target_tcp", bytes=90)
        self.assertFalse(self.reserve(1, "up", 90, ticket=2)["ok"])
        self.assertEqual(quota.inspect(self.db, "a", "p")["confirmedBytes"], 10)

    def test_expiry_and_invalid_frames(self):
        with self.assertRaises(ValueError):
            self.send(0, "sample", direction="up", bytes=7, path="target_tcp", pathBytes=7)
        self.assertEqual(self.reserve(0, "up", 16)["expiresAt"], 900)
        with self.assertRaises(ValueError):
            self.commit(0, "up", 17)
        with self.assertRaises(ValueError):
            self.send(0, "finish", uploadedBytes=99, downloadedBytes=0, complete=False)
        self.now = 901
        self.assertFalse(self.send(2, "check")["ok"])
        self.assertFalse(self.reserve(0, "down", 10)["ok"])
        self.assertTrue(self.commit(0, "up", 10)["ok"])
        with self.assertRaises(ValueError):
            self.send(4, "open", mode="enforce", client="client-a")
        self.assertEqual(quota.inspect(self.db, "a", "p")["confirmedBytes"], 10)

    def test_duplicate_scope_and_nonsettled_node(self):
        with self.assertRaises(ValueError):
            self.send(0, "open", mode="enforce", client="client-b")
        self.meter = quota.EnforcedMeter(
            self.db, dict(self.cfg, nodeId="different"), lambda: self.now
        )
        with self.assertRaises(ValueError):
            self.send(9, "open", mode="enforce", client="client-a")
