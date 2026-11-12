"""Sandbox paid-order unit, migration, atomicity and real HTTP regressions."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import hashlib
import http.client
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
from tempfile import TemporaryDirectory
import threading
import unittest

from services.access_account import orders, store
from services.access_account.server import create_server

NOW = 1_800_000_000_000


class OrderFixture:
    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / 's1.sqlite'
        with closing(sqlite3.connect(self.path)) as db:
            db.executescript(Path(orders.__file__).with_name('schema.sql').read_text())
            for account in ('A', 'B'):
                db.execute('INSERT INTO accounts VALUES (?)', (account,))
                db.execute('INSERT INTO sessions VALUES (?,?,?,NULL)',
                           (hashlib.sha256(account.encode()).digest(), account, NOW + 100000))
            db.commit()
        orders.migrate(self.path)

    def record(self, order_id='one', **changes):
        terms = dict(order_id=order_id, account_id='A', plan_id='sandbox', period_id='period-A',
                     panel_client='sandbox-A', quota_bytes=1000, duration_ms=10000, paid=True)
        terms.update(changes)
        orders.record(self.path, **terms)

    def redeem(self, order_id='one', token='A'):
        return orders.redeem(self.path, token, order_id, lambda: NOW)

    def current(self):
        return store.read_current(self.path, 'A', lambda: NOW)

    def sql(self, query, args=()):
        with closing(sqlite3.connect(self.path)) as db:
            result = db.execute(query, args).fetchall()
            db.commit()
            return result


class OrderTest(OrderFixture, unittest.TestCase):
    def test_s1_migration_repeated_and_disabled_by_default(self):
        before = self.current()
        orders.migrate(self.path)
        orders.migrate(self.path)
        self.assertEqual(before, self.current())
        self.record()
        self.record()
        with self.assertRaises(orders.Rejected):
            self.record(quota_bytes=2000)
        for query in ('UPDATE sandbox_orders SET paid=0', 'DELETE FROM sandbox_orders'):
            with self.assertRaises(sqlite3.IntegrityError):
                self.sql(query)

    def test_populated_s1_migration_and_renewal(self):
        self.sql('INSERT INTO plans VALUES (?,?,?,?,?,?)',
                 ('A', 'sandbox', 'period-A', NOW - 100, NOW + 5000, 'sandbox-A'))
        self.sql('INSERT INTO snapshots VALUES (?,?,?,?,?,?,?,?)',
                 ('A', 'period-A', 500, 400, 200, NOW + 4000, NOW - 10, NOW))
        before = self.current()
        orders.migrate(self.path)
        orders.migrate(self.path)
        self.assertEqual(before, self.current())
        self.record()
        self.redeem()
        after = self.current()
        self.assertEqual((after['usedBytes'], after['quotaBytes'], after['remainingBytes']),
                         ('600', '1500', '900'))
        self.assertEqual(after['expiresAt'], NOW + 14000)
        self.assertEqual(after['measuredAt'], before['measuredAt'])

    def test_operator_confirms_payment_without_mutating_terms_or_downgrading(self):
        self.record(paid=False)
        self.record(paid=False)
        with self.assertRaises(orders.Rejected):
            self.redeem()
        # Economic and ownership changes must fail even during confirmation.
        for changes in (dict(account_id='B'), dict(plan_id='other'), dict(period_id='other'),
                        dict(panel_client='other'), dict(quota_bytes=2000), dict(duration_ms=20000)):
            with self.subTest(changes=changes), self.assertRaises(orders.Rejected):
                self.record(**changes)
        self.assertEqual(self.sql('SELECT paid FROM sandbox_orders'), [(0,)])
        self.record()
        self.record()
        receipt = self.redeem()
        self.record(paid=False)  # Delayed unpaid import is a successful no-op.
        self.assertEqual(self.sql('SELECT paid FROM sandbox_orders'), [(1,)])
        self.assertEqual(self.redeem(), receipt)
        self.assertEqual(self.current()['quotaBytes'], '1000')
        for query in ('UPDATE sandbox_orders SET quota_bytes=2000',
                      'UPDATE sandbox_orders SET paid=0',
                      "UPDATE sandbox_orders SET order_id='replacement'"):
            with self.assertRaises(sqlite3.IntegrityError):
                self.sql(query)

    def test_payment_confirmation_and_stale_imports_serialize(self):
        self.record(paid=False)
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda paid: self.record(paid=paid), [False, True, False] * 6))
        self.assertEqual(self.sql('SELECT paid FROM sandbox_orders'), [(1,)])
        self.redeem()
        self.assertEqual(self.current()['quotaBytes'], '1000')

    def test_migration_replaces_previous_immutable_payment_trigger(self):
        self.record(paid=False)
        self.record('granted')
        receipt = self.redeem('granted')
        self.sql('DROP TRIGGER immutable_sandbox_order_update')
        self.sql("CREATE TRIGGER immutable_sandbox_order_update BEFORE UPDATE ON sandbox_orders "
                 "BEGIN SELECT RAISE(ABORT, 'confirmed order terms are immutable'); END")
        orders.migrate(self.path)
        orders.migrate(self.path)
        self.record()
        self.assertEqual(self.sql('SELECT paid FROM sandbox_orders WHERE order_id=?', ('one',)),
                         [(1,)])
        self.assertEqual(self.redeem('granted'), receipt)
        self.assertEqual(self.current()['quotaBytes'], '1000')

    def test_renewal_uses_effective_expiry_in_both_s1_orderings(self):
        self.record()
        self.redeem()
        self.sql('UPDATE plans SET period_start=?', (NOW - 10000,))
        self.sql('UPDATE snapshots SET uploaded_bytes=700, downloaded_bytes=500')
        cases = [(5000, 4000, 14000), (4000, 5000, 14000),
                 (-1000, 5000, 10000), (5000, -1000, 10000)]
        for index, (period_end, expires_at, expected) in enumerate(cases):
            with self.subTest(period_end=period_end, expires_at=expires_at):
                self.sql('UPDATE plans SET period_end=?', (NOW + period_end,))
                self.sql('UPDATE snapshots SET expires_at=?', (NOW + expires_at,))
                order_id = f'renew-{index}'
                self.record(order_id)
                self.redeem(order_id)
                result = self.current()
                self.assertEqual(result['periodEnd'], NOW + expected)
                self.assertEqual(result['expiresAt'], NOW + expected)
                self.assertEqual(result['usedBytes'], '1200')
                self.assertEqual(result['quotaBytes'], str(2000 + index * 1000))
                self.redeem(order_id)
                self.assertEqual(self.current(), result)

    def test_non_sqlite_encodable_order_id_is_rejected(self):
        with self.assertRaises(orders.Rejected):
            self.redeem('\ud800')
        self.assertEqual(self.sql('SELECT * FROM sandbox_grants'), [])

    def test_reject_unpaid_unknown_other_account_revoked_and_expired(self):
        self.record(paid=False)
        for order_id, token in [('one', 'A'), ('missing', 'A'), ('one', 'B')]:
            with self.assertRaises(orders.Rejected):
                self.redeem(order_id, token)
        self.record('paid')
        with self.assertRaises(orders.Rejected):
            self.redeem('paid', 'B')
        self.assertIsNone(self.redeem('paid', 'invalid'))
        self.sql('UPDATE sessions SET revoked_at=? WHERE account_id=?', (NOW, 'A'))
        self.assertIsNone(self.redeem('paid'))
        self.sql('UPDATE sessions SET revoked_at=NULL, expires_at=?', (NOW,))
        self.assertIsNone(self.redeem('paid'))
        self.assertEqual(self.sql('SELECT * FROM sandbox_grants'), [])
        self.assertEqual(self.current(), None)

    def test_consumed_renewal_keeps_usage_binding_and_measurement(self):
        self.record()
        self.redeem()
        self.sql('UPDATE snapshots SET uploaded_bytes=700, downloaded_bytes=500, '
                 'measured_at=?, received_at=?', (NOW, NOW))
        before = self.current()
        self.assertEqual(before['status'], 'exhausted')
        self.record('renew')
        self.redeem('renew')
        after = self.current()
        for key in ('usedBytes', 'uploadedBytes', 'downloadedBytes', 'periodId',
                    'periodStart', 'measuredAt', 'receivedAt'):
            self.assertEqual(before[key], after[key])
        self.assertEqual((after['quotaBytes'], after['remainingBytes'], after['status']),
                         ('2000', '800', 'active'))
        self.assertEqual(after['expiresAt'], before['expiresAt'] + 10000)
        self.assertEqual(after['periodEnd'], before['periodEnd'] + 10000)
        self.record('wrong-period', period_id='new-period')
        with self.assertRaises(orders.Rejected):
            self.redeem('wrong-period')
        self.assertEqual(after, self.current())

    def test_rollback_on_receipt_failure_and_overflow(self):
        self.record()
        self.sql("CREATE TRIGGER fail_receipt BEFORE INSERT ON sandbox_grants BEGIN "
                 "SELECT RAISE(ABORT, 'injected failure'); END")
        with self.assertRaises(store.Unavailable):
            self.redeem()
        self.assertEqual(self.current()['status'], 'not_subscribed')
        self.assertEqual(self.sql('SELECT * FROM panel_bindings'), [])
        self.sql('DROP TRIGGER fail_receipt')
        self.redeem()
        before = self.current()
        self.record('overflow', quota_bytes=9223372036854775807)
        with self.assertRaises(store.Unavailable):
            self.redeem('overflow')
        self.assertEqual(before, self.current())
        self.assertEqual(len(self.sql('SELECT * FROM sandbox_grants')), 1)

    def test_concurrent_orders_restart_and_stable_replay(self):
        self.record()
        with ThreadPoolExecutor(max_workers=8) as pool:
            receipts = list(pool.map(lambda _: self.redeem(), range(20)))
        self.assertTrue(all(r == receipts[0] for r in receipts))
        self.assertEqual(self.current()['quotaBytes'], '1000')
        # New interpreter, new SQLite connection, same durable receipt.
        code = ('from services.access_account.orders import redeem; import sys; '
                f'print(redeem(sys.argv[1], "A", "one", lambda: {NOW + 1}))')
        result = subprocess.run([sys.executable, '-c', code, str(self.path)],
                                capture_output=True, text=True, check=True)
        self.assertIn(str(NOW), result.stdout)
        self.assertEqual(self.current()['quotaBytes'], '1000')
        self.record('two')
        self.record('three')
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(self.redeem, ['two', 'three']))
        self.assertEqual(self.current()['quotaBytes'], '3000')
        self.assertEqual(len(self.sql('SELECT * FROM sandbox_grants')), 3)

    def test_process_crash_before_commit_leaves_no_partial_grant(self):
        self.record()
        code = """
import os, sys
from services.access_account import orders
original = orders.connect
def crash_connection(path):
    db = original(path)
    db.create_function('crash', 0, lambda: os._exit(23))
    db.execute('CREATE TEMP TRIGGER crash_receipt BEFORE INSERT ON sandbox_grants '
               'BEGIN SELECT crash(); END')
    return db
orders.connect = crash_connection
orders.redeem(sys.argv[1], 'A', 'one', lambda: 1800000000000)
"""
        result = subprocess.run([sys.executable, '-c', code, str(self.path)], check=False)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.current()['status'], 'not_subscribed')
        self.assertEqual(self.sql('SELECT * FROM sandbox_grants'), [])
        self.redeem()
        self.assertEqual(self.current()['quotaBytes'], '1000')

    def test_expired_renewal_and_panel_limits_remain_authoritative(self):
        self.record()
        self.redeem()
        self.sql('UPDATE plans SET period_start=?, period_end=?', (NOW - 20000, NOW - 1))
        self.sql('UPDATE snapshots SET expires_at=?, uploaded_bytes=900', (NOW - 1,))
        self.record('renew')
        self.redeem('renew')
        self.assertEqual(self.current()['expiresAt'], NOW + 10000)
        self.assertEqual(self.current()['usedBytes'], '900')
        class FinitePanel:
            def read(self, client, clock):
                return dict(quota_bytes=500, uploaded_bytes=400, downloaded_bytes=200,
                            expires_at=NOW + 1000, measured_at=None, received_at=clock())
        actual = store.read_current(self.path, 'A', lambda: NOW, panel=FinitePanel())
        self.assertEqual((actual['quotaBytes'], actual['remainingBytes'], actual['status']),
                         ('500', '0', 'exhausted'))
        self.assertEqual(actual['expiresAt'], NOW + 1000)

    def test_operator_cli_import_and_constraints(self):
        command = [sys.executable, '-m', 'services.access_account.orders',
                   '--database', str(self.path), 'record', '--order-id', 'cli',
                   '--account-id', 'A', '--plan-id', 'sandbox', '--period-id', 'period-A',
                   '--panel-client', 'sandbox-A', '--quota-bytes', '1000',
                   '--duration-ms', '10000', '--paid']
        subprocess.run(command[:-1], check=True, capture_output=True)
        with self.assertRaises(orders.Rejected):
            self.redeem('cli')
        for notification in (command, command, command[:-1]):
            subprocess.run(notification, check=True, capture_output=True)
        self.redeem('cli')
        self.assertEqual(self.current()['quotaBytes'], '1000')
        for changes in (dict(quota_bytes=0), dict(duration_ms=-1), dict(account_id='missing')):
            with self.assertRaises(sqlite3.IntegrityError):
                self.record('bad', **changes)


class OrderHTTPTest(OrderFixture, unittest.TestCase):
    def start(self, **kwargs):
        server = create_server(self.path, clock_ms=lambda: NOW, **kwargs)
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever,
                                  kwargs={'poll_interval': 0.01}, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.shutdown)
        return server

    def request(self, server, method='POST', token='A', body=None, path='/v1/me/orders/redeem'):
        with closing(http.client.HTTPConnection(*server.server_address, timeout=10)) as conn:
            headers = {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token}
            conn.request(method, path, body=body if body is not None else '{"orderId":"one"}',
                         headers=headers)
            response = conn.getresponse()
            self.assertEqual(response.getheader('Cache-Control'), 'no-store')
            return response.status, json.loads(response.read())

    def test_http_auth_rejections_concurrency_replay_and_renewal(self):
        server = self.start(sandbox_orders=True)
        self.record()
        self.record('unpaid', paid=False)
        for token, body, status in [('invalid', '{"orderId":"one"}', 401),
                                    ('B', '{"orderId":"one"}', 409),
                                    ('A', '{"orderId":"unpaid"}', 409),
                                    ('A', '{"orderId":"missing"}', 409),
                                    ('A', '{"orderId":"one","paid":true}', 400),
                                    ('A', '{"orderId":"one","orderId":"one"}', 400),
                                    ('A', '[]', 400)]:
            self.assertEqual(self.request(server, token=token, body=body)[0], status)
        self.assertEqual(self.sql('SELECT * FROM sandbox_grants'), [])
        with ThreadPoolExecutor(max_workers=6) as pool:
            responses = list(pool.map(lambda _: self.request(server), range(12)))
        self.assertTrue(all(r == responses[0] for r in responses))
        self.assertEqual(responses[0][0], 200)
        self.sql('UPDATE snapshots SET uploaded_bytes=800, downloaded_bytes=400')
        self.record('renew')
        self.assertEqual(self.request(server, body='{"orderId":"renew"}')[0], 200)
        status, data = self.request(server, method='GET', body='', path='/v1/me/entitlement')
        self.assertEqual((status, data['usedBytes'], data['remainingBytes']), (200, '1200', '800'))
        self.assertEqual(data['expiresAt'], NOW + 20000)
        restarted = self.start(sandbox_orders=True)
        self.assertEqual(self.request(restarted), responses[0])
        self.assertEqual(len(self.sql('SELECT * FROM sandbox_grants')), 2)

    def test_default_disabled_and_panel_rejected(self):
        self.assertEqual(self.request(self.start())[0], 404)
        with self.assertRaises(ValueError):
            self.start(sandbox_orders=True, panel=object())

    def test_http_payment_confirmation_and_stale_unpaid_import(self):
        server = self.start(sandbox_orders=True)
        self.record(paid=False)
        self.assertEqual(self.request(server)[0], 409)
        self.record()
        response = self.request(server)
        self.assertEqual(response[0], 200)
        self.record(paid=False)
        self.assertEqual(self.request(server), response)
        self.assertEqual(len(self.sql('SELECT * FROM sandbox_grants')), 1)

    def test_invalid_unicode_and_nested_json_return_400_without_grant(self):
        server = self.start(sandbox_orders=True)
        self.record()
        for body in (r'{"orderId":"\ud800"}', r'{"orderId":"\udfff"}',
                     '[' * 1024, '{"orderId":' + '[' * 500 + '0' + ']' * 500 + '}'):
            with self.subTest(body=body[:40]):
                self.assertEqual(self.request(server, body=body), (400, {'error': 'invalid_request'}))
                self.assertEqual(self.sql('SELECT * FROM sandbox_grants'), [])
        self.assertEqual(self.request(server)[0], 200)

    def test_incomplete_body_eof_and_timeout_return_400_without_grant(self):
        server = self.start(sandbox_orders=True)
        self.record()
        for half_close in (True, False):
            with self.subTest(half_close=half_close):
                with socket.create_connection(server.server_address, timeout=10) as sock:
                    # Even syntactically valid JSON is incomplete if the declared length differs.
                    body = b'{"orderId":"one"}'
                    sock.sendall(b'POST /v1/me/orders/redeem HTTP/1.1\r\nHost: localhost\r\n'
                                 b'Authorization: Bearer A\r\nContent-Type: application/json\r\n'
                                 + f'Content-Length: {len(body) + 1}\r\n\r\n'.encode() + body)
                    if half_close:
                        sock.shutdown(socket.SHUT_WR)
                    response = http.client.HTTPResponse(sock)
                    response.begin()
                    self.assertEqual(response.status, 400)
                    self.assertEqual(response.getheader('Cache-Control'), 'no-store')
                    self.assertEqual(json.loads(response.read()), {'error': 'invalid_request'})
                self.assertEqual(self.sql('SELECT * FROM sandbox_grants'), [])
        self.assertEqual(self.request(server)[0], 200)

    def test_lost_response_retry(self):
        server = self.start(sandbox_orders=True)
        self.record()
        # Send a complete request but discard its response, as after a client timeout.
        with socket.create_connection(server.server_address, timeout=5) as sock:
            body = b'{"orderId":"one"}'
            sock.sendall(b'POST /v1/me/orders/redeem HTTP/1.1\r\nHost: localhost\r\n'
                         b'Authorization: Bearer A\r\nContent-Type: application/json\r\n'
                         + f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
            # Reading only headers establishes server completion; caller loses the receipt.
            sock.recv(4096)
        self.assertEqual(self.request(server)[0], 200)
        self.assertEqual(self.current()['quotaBytes'], '1000')
        self.assertEqual(len(self.sql('SELECT * FROM sandbox_grants')), 1)
