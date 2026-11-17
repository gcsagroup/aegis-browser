"""Node cumulative positions, authority selection and S2/S3 integration."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import sqlite3
import unittest
from unittest.mock import patch

from services.access_account import metering, orders, settlement, store
from services.access_account.panel import Panel
from services.access_account.tests.test_credentials import CredentialFixture


class SettlementTest(CredentialFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.config = dict(nodeId='node-one', upstreams={'client-A': 1080, 'client-B': 1081})
        self.meter = metering.Meter(self.path, self.config, self.clock)
        self.flow = '1' * 32

    def bind(self, config=None, account='A'):
        settlement.bind(self.path, config or self.config, account, 'period-' + account, self.now)

    def open(self, client='client-A', meter=None):
        (meter or self.meter).accept(dict(v=1, op='open', flow=self.flow, client=client))

    def sample(self, n, direction='up', meter=None):
        (meter or self.meter).accept(dict(v=1, op='sample', flow=self.flow, direction=direction,
                                         path='target_tcp' if direction == 'up' else 'vision_raw',
                                         bytes=n, pathBytes=n))

    def read(self, token='token-A', panel=None):
        return store.read_current(self.path, token, self.clock, panel=panel)

    def replay(self, up, down, when=None):
        settlement.replay(self.path, self.config, 'A', 'period-A', up, down,
                          self.now if when is None else when, self.now)

    def test_local_settlement_monotonic_concurrent_replay_and_restart(self):
        self.bind()
        self.open()
        self.now += 20
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(self.sample, [10, 30, 20, 1, 40, 40]))
        self.sample(60, 'down')
        self.meter = metering.Meter(self.path, self.config, self.clock)
        self.bind()
        self.open()
        self.sample(30)
        self.now += 100
        for up, down in [(40, 60), (10, 30), (40, 10)]:
            self.replay(up, down)
        before = self.read()
        self.assertEqual((before['uploadedBytes'], before['downloadedBytes'], before['usedBytes']),
                         ('42', '63', '105'))
        self.assertEqual((before['measuredAt'], before['receivedAt']), (10020, 10020))
        for up, down, stamp in [(41, 60, self.now), (40, -1, self.now), (40, 60, self.now+1)]:
            with self.assertRaises(ValueError):
                self.replay(up, down, stamp)
        self.assertEqual(self.read(), before)
        self.assertEqual(self.read('token-B')['usedBytes'], '5')
        self.meter.accept(dict(v=1, op='sample', flow=self.flow, direction='up',
                               path='target_tcp', bytes=77, pathBytes=77, measuredAt=10030))
        after = self.read()
        self.assertEqual(after['usedBytes'], '142')
        self.assertEqual((after['measuredAt'], after['receivedAt'], after['evaluatedAt']),
                         (10030, self.now, self.now))
        self.now += 100
        self.replay(77, 60)
        self.assertEqual((self.read()['measuredAt'], self.read()['receivedAt']),
                         (10030, after['receivedAt']))

    def test_source_isolation_and_atomic_rollback(self):
        self.bind()
        self.open()
        other_config = dict(self.config, nodeId='node-two')
        other = metering.Meter(self.path, other_config, self.clock)
        with self.assertRaises(ValueError):
            self.open(meter=other)
        self.assertEqual(metering.usage(self.path, 'node-two')['accounts'], [])
        self.bind(other_config)
        self.open(meter=other)
        self.sample(2**53+1, meter=other)
        self.sample(8)
        self.assertEqual(self.read()['uploadedBytes'], str(2**53+11))
        self.db.execute("CREATE TRIGGER fail_confirm BEFORE UPDATE OF uploaded ON settlement_nodes "
                        "BEGIN SELECT RAISE(ABORT,'fixture'); END")
        with self.assertRaises(sqlite3.Error):
            self.sample(9)
        self.assertEqual(metering.usage(self.path, 'node-one')['uploadedBytes'], 8)
        self.assertEqual(self.read()['uploadedBytes'], str(2**53+11))

    def test_late_previous_period_report_stays_with_old_binding(self):
        self.bind()
        self.open()
        self.sample(3)
        self.db.execute("DELETE FROM snapshots WHERE account_id='A'")
        self.db.execute("DELETE FROM plans WHERE account_id='A'")
        self.db.execute("INSERT INTO plans VALUES ('A','new','new-period',1000,90000,'client-new')")
        self.db.execute("INSERT INTO snapshots VALUES ('A','new-period',100,7,2,80000,10000,10000)")
        self.sample(100)
        self.replay(100, 0)
        self.assertEqual(self.read()['usedBytes'], '9')
        self.assertEqual(self.read('token-B')['usedBytes'], '5')
        self.assertEqual(self.db.execute("SELECT uploaded FROM settlement_nodes "
                                         "WHERE period_id='period-A'").fetchone(), ('100',))

    def test_settlement_preserves_alpha_scope_for_balances_and_credentials(self):
        self.bind()
        self.bind(account='B')
        existing_b = self.issue('token-B')
        panel = Panel('https://panel.invalid', 'fixture-only', alpha_panel_client='client-A')
        with patch.object(panel, 'read', side_effect=AssertionError('settled usage already available')):
            self.assertEqual(self.read(panel=panel)['usedBytes'], '5')
            self.assertEqual(self.verify(self.issue(panel=panel), panel=panel), 'client-A')
            for operation in (lambda: self.read('token-B', panel),
                              lambda: self.issue('token-B', panel=panel),
                              lambda: self.verify(existing_b, panel=panel)):
                with self.assertRaisesRegex(store.Unavailable, 'outside Alpha scope'):
                    operation()

    def test_managed_authority_reaches_issuer_and_orders_without_panel_double_count(self):
        self.bind()
        self.open()
        self.db.execute("UPDATE snapshots SET uploaded_bytes=9999 WHERE account_id='A'")
        panel = self.panel(lambda: self.fail('managed usage must not consult the panel'))
        self.now += 20000
        result = self.read(panel=panel)
        self.assertEqual((result['usedBytes'], result['freshness']), ('5', 'unavailable'))
        grant = self.issue(panel=panel)
        self.assertEqual(self.verify(grant, panel=panel), 'client-A')
        self.sample(9995)
        self.assertEqual(self.read(panel=panel)['status'], 'exhausted')
        with closing(orders.connect(self.path)) as db:
            self.assertIsNone(settlement.authority(db, 'A', 'period-A', self.now))
            self.assertIsNone(settlement.authority(db, 'B', 'period-B', self.now))
        self.assertEqual(self.issue(panel=panel), {})
        self.assertIsNone(self.verify(grant, panel=panel))
        orders.migrate(self.path)
        orders.record(self.path, order_id='topup', account_id='A', plan_id='plan-A', period_id='period-A',
                      panel_client='client-A', quota_bytes=500, duration_ms=50, paid=True)
        receipt = orders.redeem(self.path, 'token-A', 'topup', self.clock)
        self.assertEqual(orders.redeem(self.path, 'token-A', 'topup', self.clock), receipt)
        self.assertEqual(self.read(panel=panel)['remainingBytes'], '500')
        self.assertEqual(self.verify(self.issue(panel=panel), panel=panel), 'client-A')
        with closing(orders.connect(self.path)) as db:
            auth = settlement.authority(db, 'A', 'period-A', self.now)
            self.assertEqual((auth['quota_bytes'], auth['uploaded_bytes'], auth['downloaded_bytes']),
                             (10500, 9997, 3))
        self.assertEqual(self.read('token-B', self.panel_b())['usedBytes'], '50')

    def panel_b(self):
        class Panel:
            def read(self, client, clock_ms):
                assert client == 'client-B'
                return dict(quota_bytes=100, uploaded_bytes=10, downloaded_bytes=40,
                            expires_at=80000, measured_at=None, received_at=clock_ms())
        return Panel()

    def test_provisioning_on_ambiguous_existing_traffic_fails_closed(self):
        self.open()
        self.sample(7)
        with self.assertRaises(ValueError):
            self.bind()
        self.assertEqual(self.read()['usedBytes'], '5')
        self.assertEqual(metering.usage(self.path, 'node-one')['uploadedBytes'], 7)
