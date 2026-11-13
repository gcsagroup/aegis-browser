"""Controlled S3 issuer/authorization tests; all identities and secrets are fixtures."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

from services.access_account import credentials as c, orders, server
from services.access_account.server import create_server


class CredentialFixture:
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / 'accounts?#.sqlite'
        self.db = sqlite3.connect(self.path, isolation_level=None)
        self.addCleanup(self.db.close)
        self.db.executescript((Path(c.__file__).with_name('schema.sql')).read_text())
        self.now = 10_000
        for account in ('A', 'B'):
            digest = hashlib.sha256(('token-' + account).encode()).digest()
            self.db.execute('INSERT INTO accounts VALUES (?)', (account,))
            self.db.execute('INSERT INTO sessions VALUES (?,?,100000,NULL)', (digest, account))
            self.db.execute('INSERT INTO plans VALUES (?, ?, ?, 1000, 90000, ?)',
                            (account, 'plan-' + account, 'period-' + account, 'client-' + account))
            self.db.execute('INSERT INTO snapshots VALUES (?, ?, 10000, 2, 3, 80000, 10000, 10000)',
                            (account, 'period-' + account))
        c.migrate(self.path)
        self.context = str(uuid.uuid4())
        self.node = c.ManagedNode('node-one', 'node.example.test', 443,
                                  admitted_clients={'client-A', 'client-B'})

    def clock(self):
        return self.now

    def issue(self, token='token-A', context=None, mode='regular', panel=None):
        return c.issue(self.path, token, context or self.context, mode, self.clock,
                       node=self.node, panel=panel)

    def verify(self, grant, **kwargs):
        return c.verify_node(self.path, grant['username'], grant['password'], self.clock,
                             node_id=kwargs.pop('node_id', self.node.node_id), **kwargs)


    def panel(self, callback=lambda: None):
        clock = self.clock
        class FixturePanel:
            def read(self, client, clock_ms):
                if client != 'client-A':
                    raise c.Unavailable('wrong fixture identity')
                callback()
                return dict(quota_bytes=100, uploaded_bytes=1, downloaded_bytes=2,
                            expires_at=80000, measured_at=None, received_at=clock())
        return FixturePanel()


class CredentialTest(CredentialFixture, unittest.TestCase):
    def test_identity_hash_only_and_scope(self):
        grant = self.issue()
        self.assertEqual(set(grant), {'accountId', 'periodId', 'credentialId', 'contextId',
                                     'mode', 'host', 'port', 'username', 'password', 'expiresAt'})
        self.assertEqual(grant['username'], grant['credentialId'])
        self.assertEqual(grant['accountId'], 'A')
        self.assertEqual(grant['expiresAt'], 70_000)
        self.assertEqual(self.verify(grant), 'client-A')
        row = self.db.execute('SELECT * FROM node_credentials').fetchone()
        self.assertNotIn(grant['password'], row)
        self.assertNotIn('token-A', row)
        self.assertIsNone(self.verify(grant, node_id='node-other'))
        self.assertIsNone(c.verify_node(self.path, grant['username'], 'x' * 43,
                                        self.clock, node_id='node-one'))

    def test_account_switch_and_private_context_isolation(self):
        a = self.issue()
        b = self.issue('token-B')
        private = self.issue(mode='private')
        other = self.issue(context=str(uuid.uuid4()))
        replacement = self.issue()
        self.assertIsNone(self.verify(a))
        for grant, expected in ((b, 'client-B'), (private, 'client-A'),
                                (other, 'client-A'), (replacement, 'client-A')):
            self.assertEqual(self.verify(grant), expected)

    def test_concurrent_reissue_leaves_exactly_one_winner(self):
        with ThreadPoolExecutor(max_workers=8) as pool:
            grants = list(pool.map(lambda _: self.issue(), range(16)))
        self.assertEqual(sum(self.verify(grant) is not None for grant in grants), 1)
        self.assertEqual(self.db.execute('SELECT count(*) FROM node_credentials WHERE revoked=0')
                         .fetchone()[0], 1)

    def test_same_account_sessions_replace_only_their_own_scope(self):
        other_token = 'second-session-A'
        self.db.execute('INSERT INTO sessions VALUES (?, ?, 100000, NULL)',
                        (hashlib.sha256(other_token.encode()).digest(), 'A'))
        a = self.issue()
        other = self.issue(other_token)
        self.assertEqual(self.verify(a), 'client-A')
        self.assertEqual(self.verify(other), 'client-A')
        replacement = self.issue()
        self.assertIsNone(self.verify(a))
        self.assertEqual(self.verify(other), 'client-A')
        self.assertTrue(c.revoke(self.path, 'token-A', other['credentialId'], self.clock))
        self.assertEqual(self.verify(other), 'client-A')
        with ThreadPoolExecutor(max_workers=8) as pool:
            grants = list(pool.map(self.issue, ['token-A', other_token] * 8))
        self.assertIsNone(self.verify(replacement))
        self.assertIsNone(self.verify(other))
        self.assertEqual(sum(self.verify(grant) is not None for grant in grants), 2)
        self.assertEqual(self.db.execute('SELECT count(DISTINCT token_hash) '
                                         'FROM node_credentials WHERE revoked=0').fetchone()[0], 2)

    def test_missing_upstream_is_rejected_before_panel_or_credential_write(self):
        self.node = c.ManagedNode('node-one', 'node.test', 443, admitted_clients={'client-B'})
        def unexpected_read():
            self.fail('an unadmitted client must not trigger a panel read')
        for panel in (None, self.panel(unexpected_read)):
            with self.assertRaises(c.Unavailable):
                self.issue(panel=panel)
        self.assertEqual(self.db.execute('SELECT count(*) FROM node_credentials').fetchone()[0], 0)
        self.assertEqual(self.verify(self.issue('token-B')), 'client-B')

    def test_issuance_reaps_expired_active_and_revoked_rows(self):
        self.node = c.ManagedNode('node-one', 'node.test', 443, 10,
                                  admitted_clients={'client-A', 'client-B'})
        expired = self.issue()
        revoked = self.issue(context=str(uuid.uuid4()))
        c.revoke(self.path, 'token-A', revoked['credentialId'], self.clock)
        self.now += 5
        live = self.issue('token-B')
        self.now += 5
        self.assertIsNone(self.verify(expired))
        self.assertIsNone(self.verify(revoked))
        new = self.issue()
        self.assertEqual(self.db.execute('SELECT count(*) FROM node_credentials').fetchone()[0], 2)
        for grant in (expired, revoked):
            self.assertIsNone(self.verify(grant))
        for grant in (live, new):
            self.assertIsNotNone(self.verify(grant))

    def test_delete_is_idempotent_and_session_scoped(self):
        grant = self.issue()
        self.assertTrue(c.revoke(self.path, 'token-B', grant['credentialId'], self.clock))
        self.assertEqual(self.verify(grant), 'client-A')
        for identifier in (grant['credentialId'], grant['credentialId'], str(uuid.uuid4())):
            self.assertTrue(c.revoke(self.path, 'token-A', identifier, self.clock))
        self.assertIsNone(self.verify(grant))
        self.assertFalse(c.revoke(self.path, 'unknown', grant['credentialId'], self.clock))

    def test_invalid_sessions_and_input(self):
        for token in ('', '☀', 'unknown', None, 'A'):
            self.assertIsNone(self.issue(token))
        for context, mode in (('bad', 'regular'), (self.context, 'guest'),
                              (self.context, {}), (None, 'regular')):
            with self.assertRaises(ValueError):
                c.issue(self.path, 'token-A', context, mode, self.clock, node=self.node)
        self.db.execute("UPDATE sessions SET revoked_at=10000 WHERE account_id='A'")
        self.assertIsNone(self.issue())

    def test_session_account_switch_and_unsubscribed_account(self):
        grant = self.issue()
        self.db.execute("UPDATE sessions SET account_id='B' WHERE account_id='A'")
        self.assertIsNone(self.verify(grant))
        switched = self.issue()
        self.assertEqual(switched['accountId'], 'B')
        self.assertEqual(self.verify(switched), 'client-B')
        self.db.execute("DELETE FROM plans WHERE account_id='B'")
        self.assertEqual(self.issue(), {})
        self.assertIsNone(self.verify(switched))

    def test_expiry_caps_and_boundaries(self):
        for column, table, limit in [('expires_at', 'sessions', 11000),
                                     ('period_end', 'plans', 12000),
                                     ('expires_at', 'snapshots', 13000)]:
            with self.subTest(table=table):
                self.db.execute(f'UPDATE {table} SET {column}=? WHERE account_id=?', (limit, 'A'))
                grant = self.issue()
                self.assertEqual(grant['expiresAt'], limit)
                self.now = limit
                self.assertIsNone(self.verify(grant))
                self.now = 10000
                self.db.execute(f'UPDATE {table} SET {column}=80000 WHERE account_id=?', ('A',))
        self.node = c.ManagedNode('node-one', 'node.example.test', 443, 1,
                                  admitted_clients={'client-A', 'client-B'})
        grant = self.issue()
        self.now += 1
        self.assertIsNone(self.verify(grant))

    def test_renew_fences_revocation_rotation_and_expiry_during_panel_read(self):
        for action in ('revoke', 'rotate', 'expire', 'replace-plan'):
            with self.subTest(action=action):
                self.now = 10000
                grant = self.issue()
                def change():
                    if action == 'revoke':
                        c.revoke(self.path, 'token-A', grant['credentialId'], self.clock)
                    elif action == 'rotate':
                        self.issue()
                    elif action == 'expire':
                        self.now = grant['expiresAt']
                    else:
                        self.db.execute("UPDATE plans SET period_end=period_end WHERE account_id='A'")
                def renew():
                    return c.issue(self.path, 'token-A', self.context, 'regular', self.clock,
                                   node=self.node, panel=self.panel(change), renew_id=grant['credentialId'])
                if action == 'replace-plan':
                    with self.assertRaises(c.Unavailable):
                        renew()
                else:
                    self.assertEqual(renew(), {})
                self.assertIsNone(self.verify(grant))

    def test_verify_accepts_renewal_committed_during_panel_read(self):
        grant = self.issue()
        self.now += 5000
        def renew():
            result = c.issue(self.path, 'token-A', self.context, 'regular', self.clock,
                             panel=self.panel(), node=self.node, renew_id=grant['credentialId'])
            self.assertEqual(result['expiresAt'], 75000)
            self.now = grant['expiresAt']
        self.assertEqual(self.verify(grant, panel=self.panel(renew)), 'client-A')

    def test_current_exhaustion_and_expiry_are_checked(self):
        grant = self.issue()
        self.db.execute("UPDATE snapshots SET uploaded_bytes=9997 WHERE account_id='A'")
        self.assertIsNone(self.verify(grant))
        self.assertEqual(self.issue(), {})
        self.db.execute("UPDATE snapshots SET uploaded_bytes=0 WHERE account_id='A'")
        self.assertIsNone(self.verify(grant))  # observed denial cannot resurrect
        grant = self.issue()
        self.db.execute("UPDATE snapshots SET expires_at=10000 WHERE account_id='A'")
        self.assertIsNone(self.verify(grant))

    def test_revoke_unrevoke_and_plan_recreation_do_not_replay(self):
        grant = self.issue()
        self.db.execute("UPDATE sessions SET revoked_at=10000 WHERE account_id='A'")
        self.db.execute("UPDATE sessions SET revoked_at=NULL WHERE account_id='A'")
        self.assertIsNone(self.verify(grant))
        grant = self.issue()
        self.db.execute("DELETE FROM plans WHERE account_id='A'")
        self.db.execute("INSERT INTO plans VALUES ('A','plan-A','period-A',1000,90000,'client-A')")
        self.db.execute("INSERT INTO snapshots VALUES ('A','period-A',10000,2,3,80000,10000,10000)")
        self.assertIsNone(self.verify(grant))
        self.assertEqual(self.verify(self.issue()), 'client-A')

    def test_stale_missing_and_future_snapshots_fail_closed(self):
        grant = self.issue()
        self.now = 25001
        for call in (self.issue, lambda: self.verify(grant)):
            with self.assertRaises(c.Unavailable):
                call()
        self.now = 9999
        with self.assertRaises(c.Unavailable):
            self.issue()
        self.now = 10000
        self.db.execute("UPDATE snapshots SET measured_at=NULL WHERE account_id='A'")
        with self.assertRaises(c.Unavailable):
            self.issue()
        self.db.execute("DELETE FROM snapshots WHERE account_id='A'")
        with self.assertRaises(c.Unavailable):
            self.verify(grant)

    def test_live_panel_does_not_require_offline_snapshot(self):
        self.db.execute('DELETE FROM snapshots')
        panel = self.panel()
        grant = self.issue(panel=panel)
        self.assertEqual(self.verify(grant, panel=panel), 'client-A')

    def test_panel_error_never_replays_cached_authorization(self):
        grant = self.issue()
        def fail():
            raise c.Unavailable('fixture private upstream diagnostic')
        panel = self.panel(fail)
        for call in (lambda: self.issue(panel=panel), lambda: self.verify(grant, panel=panel)):
            with self.assertRaises(c.Unavailable):
                call()

    def test_session_revocation_during_panel_read(self):
        grant = self.issue()
        panel = self.panel(lambda: self.db.execute(
            "UPDATE sessions SET revoked_at=10000 WHERE account_id='A'"))
        self.assertIsNone(self.verify(grant, panel=panel))
        self.db.execute("UPDATE sessions SET revoked_at=NULL WHERE account_id='A'")
        self.assertIsNone(self.issue(panel=panel))

    def test_revoke_restore_during_panel_read_is_fenced(self):
        def change_restore():
            self.db.execute("UPDATE sessions SET revoked_at=10000 WHERE account_id='A'")
            self.db.execute("UPDATE sessions SET revoked_at=NULL WHERE account_id='A'")
        with self.assertRaises(c.Unavailable):
            self.issue(panel=self.panel(change_restore))

    def test_binding_change_during_panel_read(self):
        panel = self.panel(lambda: self.db.execute(
            "UPDATE plans SET period_end=70000 WHERE account_id='A'"))
        with self.assertRaises(c.Unavailable):
            self.issue(panel=panel)

    def test_reissue_and_delete_during_verify_panel_read(self):
        grant = self.issue()
        panel = self.panel(lambda: self.issue())
        self.assertIsNone(self.verify(grant, panel=panel))
        grant = self.issue()
        panel = self.panel(lambda: c.revoke(self.path, 'token-A', grant['credentialId'], self.clock))
        self.assertIsNone(self.verify(grant, panel=panel))

    def test_migration_is_additive_and_idempotent(self):
        self.db.execute('CREATE TABLE sandbox_orders (id TEXT PRIMARY KEY)')
        self.db.execute("INSERT INTO sandbox_orders VALUES ('keep')")
        grant = self.issue()
        c.migrate(self.path)
        c.migrate(self.path)
        self.assertEqual(self.verify(grant), 'client-A')
        self.assertEqual(self.db.execute('SELECT * FROM sandbox_orders').fetchall(), [('keep',)])
        missing = self.path.with_name('missing.sqlite')
        with self.assertRaises(c.Unavailable):
            c.migrate(missing)
        self.assertFalse(missing.exists())

    def test_migration_upgrades_the_original_account_scope(self):
        grant = self.issue()
        self.db.execute('DROP INDEX node_credentials_session_scope')
        self.db.execute('CREATE UNIQUE INDEX node_credentials_scope ON '
                        'node_credentials(account_id, node_id, context_id, mode) WHERE revoked=0')
        c.migrate(self.path)
        c.migrate(self.path)
        self.db.execute('INSERT INTO sessions VALUES (?, ?, 100000, NULL)',
                        (hashlib.sha256(b'second-session-A').digest(), 'A'))
        other = self.issue('second-session-A')
        self.assertEqual(self.verify(grant), 'client-A')
        self.assertEqual(self.verify(other), 'client-A')

    def test_untrusted_node_configuration_rejected(self):
        for host in ('https://node.test', 'user:pass@node.test', 'node.test/path',
                     'node.test?secret', 'node.test\r\nX: y', '', 'node_test', '[::1]'):
            with self.assertRaises(ValueError):
                c.ManagedNode('node', host, 443, admitted_clients={'client-A'})
        for ttl in (0, -1, 300001, True):
            with self.assertRaises(ValueError):
                c.ManagedNode('node', 'node.test', 443, ttl, admitted_clients={'client-A'})

    def test_node_admission_is_required_finite_and_immutable(self):
        for admitted in (None, [], 'client-A', set(), {'*'}, {None}, {''}):
            with self.assertRaises(ValueError):
                c.ManagedNode('node', 'node.test', 443, admitted_clients=admitted)
        with self.assertRaises(TypeError):
            c.ManagedNode('node', 'node.test', 443)
        admitted = {'client-A'}
        node = c.ManagedNode('node', 'node.test', 443, admitted_clients=admitted)
        admitted.add('client-B')
        self.assertEqual(node.admitted_clients, frozenset({'client-A'}))
        for config in (None, {}, {'nodeId': 'node', 'upstreams': {}},
                       {'nodeId': 'node', 'upstreams': {'client-A': True}},
                       {'nodeId': 'node', 'upstreams': {'client-A': 0}},
                       {'nodeId': 'node', 'upstreams': {'client-A': '1080'}},
                       {'nodeId': 'node', 'upstreams': {'client-A': 1080, 'client-B': 1080}}):
            with self.assertRaises(ValueError):
                c.ManagedNode.from_config(config, 'node.test', 443)


class CredentialHTTPTest(CredentialFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.server = create_server(self.path, clock_ms=self.clock, managed_node=self.node,
                                    sandbox_orders=True)
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever,
                                  kwargs={'poll_interval': 0.01}, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)

    def request(self, method='POST', path='/v1/me/node-credentials', body=None, token='token-A',
                headers=None):
        client = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        self.addCleanup(client.close)
        headers = dict(headers or {})
        if token is not None:
            headers['Authorization'] = 'Bearer ' + token
        if body is None and method == 'POST':
            body = json.dumps({'contextId': self.context, 'mode': 'regular'})
        if method == 'POST':
            headers.setdefault('Content-Type', 'application/json')
        client.request(method, path, body=body, headers=headers)
        response = client.getresponse()
        self.assertEqual(response.getheader('Cache-Control'), 'no-store')
        return response.status, json.loads(response.read())

    def test_http_contract_and_compatibility(self):
        status, grant = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(self.verify(grant), 'client-A')
        self.assertEqual(self.request('GET', '/v1/me/entitlement')[0], 200)
        path = '/v1/me/node-credentials/' + grant['credentialId']
        for token in ('token-B', 'token-A', 'token-A'):
            self.assertEqual(self.request('DELETE', path, token=token), (200, {}))
        self.assertIsNone(self.verify(grant))
        self.assertEqual(self.request('DELETE', '/v1/me/node-credentials/' + str(uuid.uuid4())), (200, {}))
        self.server.managed_node = None
        self.assertEqual(self.request()[0], 404)
        self.assertEqual(self.request('GET', '/v1/me/entitlement')[0], 200)

    def test_http_renew_preserves_grant_and_fails_closed(self):
        _, grant = self.request()
        path = '/v1/me/node-credentials/' + grant['credentialId'] + '/renew'
        self.now += 10000
        expected = {k: grant[k] for k in ('accountId', 'periodId', 'contextId', 'mode', 'credentialId')}
        self.assertEqual(self.request(path=path), (200, dict(expected, expiresAt=80000)))
        self.assertEqual(self.verify(grant), 'client-A')
        for token, status in (('token-B', 403), ('unknown', 401), (None, 401)):
            self.assertEqual(self.request(path=path, token=token)[0], status)
        for context, mode in ((str(uuid.uuid4()), 'regular'), (self.context, 'private')):
            body = json.dumps({'contextId': context, 'mode': mode})
            self.assertEqual(self.request(path=path, body=body)[0], 403)
        self.now = grant['expiresAt']
        self.assertEqual(self.request(path=path)[0], 503)  # stale stored snapshot
        self.server.panel = self.panel()
        self.assertEqual(self.request(path=path), (200, dict(expected, expiresAt=80000)))
        self.now = 80000
        self.assertEqual(self.request(path=path)[0], 403)

    def test_http_auth_input_and_errors_are_private(self):
        for token in (None, 'unknown'):
            self.assertEqual(self.request(token=token), (401, {'error': 'unauthorized'}))
        for body in ('{}', '[]', '{', '{"contextId":"' + self.context + '","mode":"private",'
                     '"host":"attacker.test"}', '{"contextId":"' + self.context + '",'
                     '"mode":"regular","mode":"private"}'):
            self.assertEqual(self.request(body=body)[0], 400)
        for path in ('/v1/me/node-credentials?account=B', '//v1/me/node-credentials'):
            self.assertEqual(self.request(path=path)[0], 404)
        def fail():
            raise c.Unavailable('SECRET fixture diagnostic')
        self.server.panel = self.panel(fail)
        self.assertEqual(self.request(), (503, {'error': 'credentials_unavailable'}))

    def test_missing_upstream_does_not_return_usable_credentials(self):
        self.server.managed_node = c.ManagedNode('node-one', 'node.test', 443,
                                                 admitted_clients={'client-B'})
        self.assertEqual(self.request(), (503, {'error': 'credentials_unavailable'}))
        self.assertEqual(self.db.execute('SELECT count(*) FROM node_credentials').fetchone()[0], 0)

    def test_orders_and_credentials_share_server_without_changing_redemption(self):
        orders.record(self.path, order_id='fixture-order', account_id='A', plan_id='plan-A',
                      period_id='period-A', panel_client='client-A', quota_bytes=500,
                      duration_ms=1000, paid=True)
        old = self.request()[1]
        route, body = '/v1/me/orders/redeem', '{"orderId":"fixture-order"}'
        self.assertEqual(self.request(path=route, body=body, token='token-B'),
                         (409, {'error': 'order_unavailable'}))
        self.assertEqual(self.request(path=route, body=body, token=None),
                         (401, {'error': 'unauthorized'}))
        receipt = self.request(path=route, body=body)
        self.assertEqual(receipt, (200, {'orderId': 'fixture-order', 'grantedAt': self.now,
                                        'mode': 'sandbox'}))
        self.assertIsNone(self.verify(old))  # Changed plan expiry revokes old grants.
        new = self.request()[1]
        self.assertEqual(self.request(path=route, body=body), receipt)
        self.assertEqual(self.verify(new), 'client-A')
        status, entitlement = self.request('GET', '/v1/me/entitlement')
        self.assertEqual(status, 200)
        self.assertEqual((entitlement['quotaBytes'], entitlement['usedBytes']), ('10500', '5'))
        self.assertEqual(entitlement['expiresAt'], 81000)
        self.assertEqual(self.request(path=route), (400, {'error': 'invalid_request'}))
        self.assertEqual(self.request(body=body), (400, {'error': 'invalid_request'}))
        for path in (route + '?account=B', '/v1/me/node-credentials/extra', '/unknown'):
            self.assertEqual(self.request(path=path)[0], 404)
        self.server.sandbox_orders = False
        self.assertEqual(self.request(path=route, body=body)[0], 404)
        self.assertEqual(self.request()[0], 200)

    def test_shared_bearer_parser_rejects_duplicate_headers_on_each_route(self):
        for method, path in (('GET', '/v1/me/entitlement'), ('POST', '/v1/me/orders/redeem'),
                             ('POST', '/v1/me/node-credentials'),
                             ('DELETE', '/v1/me/node-credentials/' + str(uuid.uuid4()))):
            client = http.client.HTTPConnection(*self.server.server_address, timeout=3)
            self.addCleanup(client.close)
            client.putrequest(method, path)
            client.putheader('Authorization', 'Bearer token-A')
            client.putheader('Authorization', 'Bearer token-B')
            client.endheaders()
            response = client.getresponse()
            self.assertEqual(response.status, 401)
            self.assertEqual(response.getheader('Cache-Control'), 'no-store')
            self.assertEqual(json.loads(response.read()), {'error': 'unauthorized'})

    def test_cli_keeps_entitlement_options_and_adds_opt_in_node(self):
        result = subprocess.run([sys.executable, '-B', '-m', 'services.access_account.server', '--help'],
                                capture_output=True, text=True, check=True)
        for flag in ('--stored-snapshots', '--panel-url', '--database', '--port', '--node-config', '--sandbox-orders',
                     '--node-host', '--node-port', '--node-ttl-ms'):
            self.assertIn(flag, result.stdout)
        self.assertNotIn('--node-id', result.stdout)

    def test_cli_consumes_shared_node_config_and_preserves_sandbox_option(self):
        config_path = self.path.with_name('node.json')
        config_path.write_text(json.dumps({'nodeId': 'configured-node',
                                          'upstreams': {'client-A': 1080, 'client-B': 1081},
                                          'targets': {'example.test:443': '192.0.2.1'}}))
        args = ['server', '--database', str(self.path), '--port', '8080', '--stored-snapshots',
                '--sandbox-orders', '--node-config', str(config_path), '--node-host', 'node.test',
                '--node-port', '443', '--node-ttl-ms', '12000']
        with patch.object(sys, 'argv', args), patch.object(server, 'create_server') as create:
            server.main()
        node = create.call_args.kwargs['managed_node']
        self.assertEqual(node, c.ManagedNode('configured-node', 'node.test', 443, 12000,
                                             admitted_clients={'client-A', 'client-B'}))
        self.assertTrue(create.call_args.kwargs['sandbox_orders'])
        config_path.write_text('{"nodeId":"configured-node","upstreams":{}}')
        with patch.object(sys, 'argv', args), patch.object(server, 'create_server') as create:
            with patch('sys.stderr'), self.assertRaises(SystemExit) as error:
                server.main()
            self.assertEqual(error.exception.code, 2)
            create.assert_not_called()


if __name__ == '__main__':
    unittest.main()
