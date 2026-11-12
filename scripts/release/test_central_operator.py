import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import unittest
from unittest.mock import patch

import central_operator_authorization as operator
import central_ios_protocol as p


def fixture():
    now = datetime.now(timezone.utc)
    approval = {'executor_commit': '1' * 40, 'request_sha256': 'a' * 64,
                'issued_at': operator.utc(now - timedelta(minutes=1)),
                'expires_at': operator.utc(now + timedelta(hours=23))}
    policy = {'schema': 'aegis-develop-operator-policy-v1', 'mode': operator.MODE, 'status': 'configured',
              'operator': {'id': 316909304, 'login': 'GCSA-ToolsTeam', 'type': 'User'},
              'maximum_authorization_seconds': 86400, 'independentHumanApproval': False}
    return server(approval, policy, now), approval, now


def server(approval, policy, now):
    base = 'repos/' + operator.CENTRAL
    registry = {'schema': p.QUINN.registry_schema, 'scope': p.QUINN.scope,
                'status': 'active', 'authorizations': [approval]}

    def content(path, value):
        raw = p.canonical(value)
        return {'path': path, 'type': 'file', 'encoding': 'base64', 'size': len(raw),
                'content': base64.b64encode(raw).decode(),
                'sha': hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()}

    grant = content(operator.GRANT_PATH, registry)
    rows = {
        base: {'id': operator.CENTRAL_ID, 'full_name': operator.CENTRAL, 'private': True},
        base + '/contents/' + operator.POLICY_PATH + '?ref=' + '1' * 40: content(operator.POLICY_PATH, policy),
        base + '/contents/' + operator.GRANT_PATH + '?ref=' + '3' * 40: grant,
        base + '/commits/' + '3' * 40 + '/pulls?per_page=100': [
            {'number': 7, 'merged_at': operator.utc(now), 'merge_commit_sha': '3' * 40}],
        base + '/pulls/7': {'id': 500, 'number': 7, 'merged': True, 'state': 'closed', 'draft': False,
            'merge_commit_sha': '3' * 40, 'merged_at': operator.utc(now), 'merged_by': policy['operator'].copy(),
            'base': {'ref': 'main', 'sha': '1' * 40, 'repo': {'id': operator.CENTRAL_ID}},
            'head': {'sha': '2' * 40, 'repo': {'id': operator.CENTRAL_ID}}},
        base + '/git/commits/' + '3' * 40: {'sha': '3' * 40, 'tree': {'sha': '4' * 40}, 'parents': [{'sha': '1' * 40}]},
        base + '/git/commits/' + '2' * 40: {'sha': '2' * 40, 'tree': {'sha': '4' * 40}},
        base + '/compare/' + '1' * 40 + '...' + '3' * 40: {
            'base_commit': {'sha': '1' * 40}, 'merge_base_commit': {'sha': '1' * 40}, 'status': 'ahead',
            'ahead_by': 1, 'behind_by': 0, 'total_commits': 1,
            'files': [{'filename': operator.GRANT_PATH, 'status': 'modified'}]},
        base + '/git/trees/' + '4' * 40 + '?recursive=1': {'sha': '4' * 40, 'truncated': False,
            'tree': [{'path': operator.GRANT_PATH, 'mode': '100644', 'type': 'blob', 'sha': grant['sha']}]},
        base + '/collaborators/GCSA-ToolsTeam/permission': {'permission': 'admin', 'user': policy['operator'].copy()},
        base + '/git/ref/heads/main': {'object': {'sha': '3' * 40}},
    }

    class Server:
        def __init__(self):
            self.rows = rows
            self.calls = []
            self.before = lambda path: None

        def __call__(self, path):
            self.calls.append(path)
            self.before(path)
            return copy.deepcopy(self.rows[path])

    return Server()


class OperatorAuthorityTests(unittest.TestCase):
    def test_exact_operator_merge_yields_stable_honest_proof(self):
        api, approval, now = fixture()
        proof = operator.authenticate(api, approval, '3' * 40, p, now=now)
        self.assertEqual(proof, operator.authenticate(api, approval, '3' * 40, p, now=now))
        self.assertEqual((proof['operator']['id'], proof['pr_head'], proof['registry_commit']), (316909304, '2' * 40, '3' * 40))
        self.assertFalse(proof['independentHumanApproval'])
        self.assertIsNone(proof['environmentBypassObserved'])

    def test_other_operator_bot_downgrade_dirty_tree_and_non_grant_changes_fail_closed(self):
        mutations = [lambda rows, base: rows[base + '/pulls/7']['merged_by'].update(id=p.QUINN.actor_id),
            lambda rows, base: rows[base + '/pulls/7']['merged_by'].update(type='Bot'),
            lambda rows, base: rows[base + '/collaborators/GCSA-ToolsTeam/permission'].update(permission='write'),
            lambda rows, base: rows[base + '/git/commits/' + '2' * 40]['tree'].update(sha='5' * 40),
            lambda rows, base: rows[base + '/compare/' + '1' * 40 + '...' + '3' * 40]['files'].append(
                {'filename': '.github/workflows/evil.yml', 'status': 'added'}),
            lambda rows, base: rows[base + '/git/commits/' + '3' * 40]['parents'].append({'sha': '2' * 40}),
            lambda rows, base: rows[base + '/pulls/7']['base'].update(sha='6' * 40),
            lambda rows, base: rows[base + '/pulls/7']['head']['repo'].update(id=1),
            lambda rows, base: rows[base + '/git/trees/' + '4' * 40 + '?recursive=1']['tree'][0].update(mode='120000'),
            lambda rows, base: rows[base + '/contents/' + operator.GRANT_PATH + '?ref=' + '3' * 40].update(content='e30='),
            lambda rows, base: rows[base + '/git/ref/heads/main']['object'].update(sha='7' * 40)]
        for change in mutations:
            api, approval, now = fixture()
            change(api.rows, 'repos/' + operator.CENTRAL)
            with self.subTest(change=change), self.assertRaises(ValueError):
                operator.authenticate(api, approval, '3' * 40, p, now=now)

    def test_unconfigured_or_self_selecting_policy_cannot_authorize(self):
        for status, identity in [('not_configured', 316909304), ('configured', p.QUINN.actor_id)]:
            _, approval, now = fixture()
            policy = {'schema': 'aegis-develop-operator-policy-v1', 'mode': operator.MODE, 'status': status,
                      'operator': {'id': identity, 'login': 'operator', 'type': 'User'},
                      'maximum_authorization_seconds': 86400, 'independentHumanApproval': False}
            with self.assertRaises(ValueError):
                operator.authenticate(server(approval, policy, now), approval, '3' * 40, p, now=now)

    def test_expiry_during_last_network_read_is_checked_after_network(self):
        api, approval, now = fixture()
        current = [now]

        class Clock:
            fromisoformat = datetime.fromisoformat

            @staticmethod
            def now(tz):
                return current[0]

        def delayed(path):
            if path.endswith('/git/ref/heads/main'):
                current[0] = operator.timestamp(approval['expires_at'])
        api.before = delayed
        with patch.object(operator, 'datetime', Clock), self.assertRaisesRegex(ValueError, 'outside its window'):
            operator.authenticate(api, approval, '3' * 40, p)

    def test_future_merge_expired_grant_and_over_24_hour_grant_are_rejected(self):
        for change in ('future_merge', 'expired', 'oversized'):
            api, approval, now = fixture()
            policy = p.parse(base64.b64decode(api.rows['repos/' + operator.CENTRAL + '/contents/'
                + operator.POLICY_PATH + '?ref=' + '1' * 40]['content']))
            if change == 'expired': approval['expires_at'] = operator.utc(now)
            if change == 'oversized': approval['expires_at'] = operator.utc(now + timedelta(hours=25))
            api = server(approval, policy, now + timedelta(minutes=1) if change == 'future_merge' else now)
            with self.subTest(change=change), self.assertRaises(ValueError):
                operator.authenticate(api, approval, '3' * 40, p, now=now)

    def test_historical_proof_survives_expiry_admin_removal_main_advance_and_account_rename(self):
        api, approval, now = fixture()
        proof = operator.authenticate(api, approval, '3' * 40, p, now=now)
        base = 'repos/' + operator.CENTRAL
        del api.rows[base + '/collaborators/GCSA-ToolsTeam/permission']
        del api.rows[base + '/git/ref/heads/main']
        api.rows[base + '/pulls/7']['merged_by']['login'] = 'renamed-operator'
        api.calls.clear()
        self.assertEqual(operator.authenticate(api, approval, '3' * 40, p, historical_proof=proof,
                                             now=now + timedelta(days=365)), proof)
        self.assertFalse(any('/permission' in path or '/git/ref/heads/main' in path for path in api.calls))
        with self.assertRaises(ValueError):
            operator.authenticate(api, approval, '3' * 40, p, historical_proof=dict(proof, pr_id=1))
