import hashlib
from pathlib import Path
import sqlite3
import tempfile
import unittest

from services.access_account.store import Unavailable, read_current


SCHEMA = Path(__file__).resolve().parents[1] / 'schema.sql'
MAX_I64 = (1 << 63) - 1


class AccountStoreTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / 'authority?#.sqlite'
        self.db = sqlite3.connect(self.path, isolation_level=None)
        self.addCleanup(self.db.close)
        self.db.executescript(SCHEMA.read_text())
        for account in ('A', 'B'):
            digest = hashlib.sha256(('token-' + account).encode()).digest()
            self.db.execute('INSERT INTO accounts VALUES (?)', (account,))
            self.db.execute('INSERT INTO sessions VALUES (?, ?, 100000, NULL)', (digest, account))
        self.db.execute("INSERT INTO plans VALUES ('A','plan','period',1000,60000,'source-a')")
        self.db.execute("INSERT INTO snapshots VALUES ('A','period',10001,7000,3000,50000,1000,1000)")

    def read(self, now=1000, token='token-A'):
        return read_current(self.path, token, lambda: now)

    def test_isolation_without_cache_and_auth_boundaries(self):
        self.assertEqual(self.read()['remainingBytes'], '1')
        other = self.read(token='token-B')
        self.assertEqual(other.pop('entitlementAccountId'), 'B')
        self.assertEqual(other.pop('status'), 'not_subscribed')
        self.assertTrue(all(value is None for value in other.values()))
        self.assertEqual(self.read()['planId'], 'plan')
        for token in ('A', '', '☀', None):
            self.assertIsNone(self.read(token=token))
        self.assertIsNone(self.read(100000))
        self.db.execute("UPDATE sessions SET revoked_at=1000 WHERE account_id='A'")
        self.assertIsNone(self.read())
        self.assertEqual(self.read(token='token-B')['status'], 'not_subscribed')

    def test_exact_bytes_expiry_and_overage(self):
        self.assertEqual(self.read()['status'], 'active')
        self.db.execute('UPDATE snapshots SET quota_bytes=10000')
        self.assertEqual(self.read()['status'], 'exhausted')
        self.db.execute('UPDATE snapshots SET quota_bytes=?,uploaded_bytes=?,downloaded_bytes=?',
                        (MAX_I64, MAX_I64, MAX_I64))
        snapshot = self.read()
        self.assertEqual((snapshot['usedBytes'], snapshot['remainingBytes'], snapshot['status']),
                         (str(MAX_I64 * 2), '0', 'exhausted'))
        self.assertEqual(self.read(50000)['status'], 'expired')
        self.db.execute('UPDATE snapshots SET expires_at=90000')
        self.assertEqual(self.read(59999)['status'], 'exhausted')
        self.assertEqual(self.read(60000)['status'], 'expired')

    def test_source_age_and_missing_watermark(self):
        self.db.execute('UPDATE snapshots SET received_at=6000')
        for now, freshness in [(6000, 'current'), (6001, 'delayed'), (16000, 'delayed'),
                               (16001, 'unavailable')]:
            with self.subTest(now=now):
                snap = self.read(now)
                self.assertEqual((snap['measuredAt'], snap['snapshotAgeMs'], snap['freshness']),
                                 (1000, now - 1000, freshness))
        self.db.execute('UPDATE snapshots SET measured_at=NULL')
        snap = self.read(6001)
        self.assertEqual((snap['receivedAt'], snap['measuredAt'], snap['snapshotAgeMs'],
                          snap['freshness'], snap['usedBytes']),
                         (6000, None, None, 'unavailable', '10000'))
        with self.assertRaises(Unavailable):
            self.read(5999)

    def test_pre_period_measurement_cannot_be_relabelled_by_late_receipt(self):
        self.db.execute('UPDATE snapshots SET measured_at=999, received_at=1001')
        with self.assertRaises(Unavailable):
            self.read(1001)

    def test_pending_future_or_wrong_period_does_not_substitute_a_snapshot(self):
        with self.assertRaises(Unavailable):
            self.read(999)
        self.db.execute('DELETE FROM snapshots')
        with self.assertRaises(Unavailable):
            self.read()
        with self.assertRaises(sqlite3.IntegrityError):
            self.db.execute("INSERT INTO snapshots VALUES ('A','old',7,1,2,50000,NULL,1000)")
        # SQLite FK enforcement is connection-specific. Even an incorrectly
        # provisioned stale row must not attach to the currently selected period.
        self.db.execute('PRAGMA foreign_keys=OFF')
        self.db.execute("INSERT INTO snapshots VALUES ('A','old',7,1,2,50000,NULL,1000)")
        with self.assertRaises(Unavailable):
            self.read()

    def test_source_cannot_be_reassigned_across_accounts_or_periods(self):
        self.db.execute("DELETE FROM plans WHERE account_id='A'")
        self.assertEqual(self.db.execute('SELECT count(*) FROM snapshots').fetchone(), (0,))
        for account, period in [('A', 'new'), ('B', 'period')]:
            with self.assertRaises(sqlite3.IntegrityError):
                self.db.execute("INSERT INTO plans VALUES (?,'plan',?,1000,60000,'source-a')",
                                (account, period))
        self.db.execute("INSERT INTO plans VALUES ('A','plan','new',1000,60000,'source-b')")
        with self.assertRaises(Unavailable):
            self.read()

    def test_source_rejects_invalid_values(self):
        for change in ('quota_bytes=-1', 'uploaded_bytes=1.25', 'downloaded_bytes=NULL',
                       'expires_at=0', 'measured_at=received_at+1', 'received_at=-1'):
            with self.subTest(change=change), self.assertRaises(sqlite3.IntegrityError):
                self.db.execute('UPDATE snapshots SET ' + change)

    def test_read_only_open_does_not_create_missing_store(self):
        missing = self.path.with_name('missing.db')
        with self.assertRaises(Unavailable):
            read_current(missing, 'token-A', lambda: 1000)
        self.assertFalse(missing.exists())
        self.db.execute('DROP TABLE snapshots')
        with self.assertRaises(Unavailable):
            self.read()
