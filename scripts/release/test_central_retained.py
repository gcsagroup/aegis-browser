import base64
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

from test_central_ios import central, p, request


class RetainedTests(unittest.TestCase):
    def test_repository_root_api_has_no_trailing_slash(self):
        with patch.object(central.subprocess, 'check_output', return_value=b'{"id":1364015229}') as command:
            self.assertEqual(central.github_json('gcsagroup/apple-signing', '', 'fixture-token')['id'], 1364015229)
            self.assertEqual(command.call_args.args[0], ['gh', 'api', 'repos/gcsagroup/apple-signing'])

    def fixture(self, directory, expected=p.PROD):
        value = request()
        if expected == p.QUINN:
            value.update(schema=expected.schema, scope=expected.scope)
            value['source'].update(repository=p.source_identity(expected), ref='refs/heads/develop')
            value['producer']['workflow'] = expected.producer_workflow
        execution = {'run_id': 999, 'attempt': 1, 'workflow': expected.workflow,
                     'workflow_commit': 'f' * 40}
        prepared = {'request': value, 'request_sha256': p.digest(value), 'execution': execution,
                    'executor_commit': 'e' * 40}
        if expected == p.QUINN:
            prepared.update(scope=expected.scope, purpose='development-test-only')
        names = {'Aegis.ipa', 'Aegis.dSYM.zip', 'signature-verification.json', 'dsym-verification.json',
                 'cloud-upload-reservation.json', 'result.json', 'archive.zip', 'prepared.json', 'native-export.json'}
        for name in names:
            (directory / name).write_bytes(b'fixture-original')
        (directory / 'prepared.json').write_bytes(p.canonical(prepared))
        original = {'request': value, 'execution': execution, 'executor_commit': 'e' * 40}
        if expected == p.QUINN:
            original.update(schema='aegis-central-develop-export-result-v1', scope=expected.scope,
                            purpose='development-test-only', uploadAuthorized=False,
                            submissionAuthorized=False, releaseReady=False)
        (directory / 'result.json').write_bytes(p.canonical(original))
        result = {'request_sha256': p.digest(value), 'execution': execution, 'destination': 'export-only',
                  'repository': value['producer']['repository'], 'repository_id': value['producer']['repository_id'],
                  'release_id': 12345, 'result_sha256': p.file_digest(directory / 'result.json'),
                  'assets': [{'id': i + 1, 'name': name, 'size': (directory / name).stat().st_size,
                              'digest': 'sha256:' + p.file_digest(directory / name)} for i, name in enumerate(sorted(names))]}
        run = {'id': 999, 'run_attempt': 1, 'path': execution['workflow'], 'head_sha': 'f' * 40,
               'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success',
               'repository': {'id': 1364015229}, 'head_repository': {'id': 1364015229}}
        if expected == p.QUINN:
            result.update(scope=expected.scope, uploadAuthorized=False, submissionAuthorized=False, releaseReady=False)
            run.update(actor={'id': expected.actor_id}, triggering_actor={'id': expected.actor_id})
        return prepared, result, run

    def test_expired_actions_artifact_not_needed_and_original_dsym_is_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / 'downloaded'
            original.mkdir()
            start, result, run = self.fixture(original)
            before = {path.name: path.read_bytes() for path in original.iterdir()}
            calls = []
            def modules(name, filename):
                if filename == 'cloud-signing-poc.py':
                    return SimpleNamespace(source=lambda: {'sha': 'a' * 40, 'tree': 'b' * 40})
                if filename == 'verify-signed-ios.py':
                    return SimpleNamespace(verify=lambda *args, **kwargs: {'ipaVerified': True})
                def verify_delivered(ipa, dsym, version, build):
                    calls.append((ipa, dsym))
                    return {'downloadedIpaVerified': True}
                return SimpleNamespace(verify_delivered=verify_delivered)
            with patch.object(central, 'central_record', side_effect=lambda kind, key, token: start if kind == 'start' else result), \
                    patch.object(central, 'github_json', return_value=run), patch.object(central, 'module', side_effect=modules):
                central.verify_retained(SimpleNamespace(work=original, output=root / 'new-check'),
                                        {'AEGIS_CENTRAL_READ_TOKEN': 'fixture-read-only-token'})
            self.assertEqual(calls, [(original / 'Aegis.ipa', original / 'Aegis.dSYM.zip')])
            self.assertEqual(before, {path.name: path.read_bytes() for path in original.iterdir()})
            self.assertTrue(p.parse((root / 'new-check/retained-verification.json').read_bytes())['centralProvenanceVerified'])

    def test_changed_original_is_rejected_before_native_verification(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            start, result, run = self.fixture(root)
            (root / 'Aegis.dSYM.zip').write_bytes(b'changed-symbols')
            with patch.object(central, 'central_record', side_effect=lambda kind, key, token: start if kind == 'start' else result), \
                    patch.object(central, 'github_json', return_value=run), patch.object(central, 'module') as native:
                with self.assertRaises(ValueError):
                    central.verify_retained(SimpleNamespace(work=root, output=root / 'new-check'),
                                            {'AEGIS_CENTRAL_READ_TOKEN': 'fixture-read-only-token'})
                native.assert_not_called()


    def test_develop_retained_result_requires_explicit_scope_and_stays_non_deliverable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'original'; source.mkdir()
            start, result, run = self.fixture(source, p.QUINN)
            def modules(name, filename):
                if filename == 'cloud-signing-poc.py':
                    return SimpleNamespace(source=lambda: {'sha': 'a' * 40, 'tree': 'b' * 40})
                if filename == 'verify-signed-ios.py': return SimpleNamespace(verify=lambda *a, **k: {'ipaVerified': True})
                return SimpleNamespace(verify_delivered=lambda *a: {'symbolsVerified': True})
            with patch.object(central, 'central_record', side_effect=lambda kind, key, token: start if kind == 'start' else result), patch.object(central, 'github_json', return_value=run), patch.object(central, 'module', side_effect=modules):
                with self.assertRaises(ValueError):
                    central.verify_retained(SimpleNamespace(work=source, output=root / 'production'), {'AEGIS_CENTRAL_READ_TOKEN': 'fixture'})
                central.verify_retained(SimpleNamespace(work=source, output=root / 'develop', scope=p.QUINN.scope), {'AEGIS_CENTRAL_READ_TOKEN': 'fixture'})
            report = p.parse((root / 'develop/retained-verification.json').read_bytes())
            self.assertFalse(report['releaseReady']); self.assertFalse(report['uploadAuthorized'])
            self.assertFalse(report['submissionAuthorized']); self.assertEqual(report['scope'], p.QUINN.scope)

    def test_develop_archive_envelope_keeps_explicit_ref_and_shared_budget(self):
        import zipfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); archive = root / 'archive'; archive.mkdir(); (archive / 'binary').write_bytes(b'fixture')
            value = request(); original_budget = p.allocation(value)
            value.update(schema=p.QUINN.schema, scope=p.QUINN.scope)
            value['source'].update(repository=p.source_identity(p.QUINN), ref='refs/heads/develop')
            value['producer']['workflow'] = p.QUINN.producer_workflow
            central.bundle(archive, root / 'output', value, p.QUINN)
            delivered = p.parse((root / 'output/request.json').read_bytes())
            p.validate(delivered, p.QUINN); self.assertEqual(p.allocation(delivered), original_budget)
            with self.assertRaises(ValueError): p.validate(delivered)

    def test_operator_originals_use_frozen_authority_and_reject_changed_proof_digest(self):
        from test_central_operator import fixture, operator, server
        for tamper in ('none', 'proof_digest', 'request', 'executor', 'registry'):
            with self.subTest(tamper=tamper), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); source = root / 'original'; source.mkdir()
                start, result, run = self.fixture(source, p.QUINN)
                api, approval, now = fixture()
                policy = p.parse(base64.b64decode(api.rows['repos/' + operator.CENTRAL + '/contents/'
                    + operator.POLICY_PATH + '?ref=' + '1' * 40]['content']))
                if tamper != 'request': approval['request_sha256'] = start['request_sha256']
                api = server(approval, policy, now)
                proof = operator.authenticate(api, approval, '3' * 40, p, now=now)
                start.update(authorization=approval, operator_authorization=proof,
                             registry_commit='3' * 40, executor_commit=('9' if tamper == 'executor' else '1') * 40)
                start['execution']['workflow_commit'] = run['head_sha'] = '3' * 40
                original = p.parse((source / 'result.json').read_bytes())
                original.update(execution=start['execution'], executor_commit=start['executor_commit'])
                (source / 'prepared.json').write_bytes(p.canonical(start))
                (source / 'result.json').write_bytes(p.canonical(original))
                result['result_sha256'] = p.file_digest(source / 'result.json')
                result['registry_commit'] = ('9' if tamper == 'registry' else '3') * 40
                result['operator_authorization_sha256'] = '0' * 64 if tamper == 'proof_digest' else p.digest(proof)
                for asset in result['assets']:
                    path = source / asset['name']
                    asset.update(size=path.stat().st_size, digest='sha256:' + p.file_digest(path))
                before = {path.name: path.read_bytes() for path in source.iterdir()}
                prefix = 'repos/gcsagroup/apple-signing'
                del api.rows[prefix + '/collaborators/GCSA-ToolsTeam/permission']
                del api.rows[prefix + '/git/ref/heads/main']
                def github(repository, path, token):
                    return run if path.startswith('actions/runs/') else api(prefix + ('/' + path if path else ''))
                def modules(name, filename):
                    if filename == 'central_operator_authorization.py': return operator
                    if filename == 'cloud-signing-poc.py':
                        return SimpleNamespace(source=lambda: {'sha': 'a' * 40, 'tree': 'b' * 40})
                    if filename == 'verify-signed-ios.py': return SimpleNamespace(verify=lambda *a, **k: {'ipaVerified': True})
                    return SimpleNamespace(verify_delivered=lambda *a: {'symbolsVerified': True})
                with patch.object(central, 'central_record', side_effect=lambda kind, key, token: start if kind == 'start' else result), \
                        patch.object(central, 'github_json', side_effect=github), patch.object(central, 'module', side_effect=modules):
                    options = SimpleNamespace(work=source, output=root / 'check', scope=p.QUINN.scope)
                    if tamper != 'none':
                        with self.assertRaises(ValueError): central.verify_retained(options, {'AEGIS_CENTRAL_READ_TOKEN': 'fixture'})
                    else:
                        central.verify_retained(options, {'AEGIS_CENTRAL_READ_TOKEN': 'fixture'})
                        report = p.parse((root / 'check/retained-verification.json').read_bytes())
                        self.assertEqual(report['activationOperator']['id'], 316909304)
                        self.assertFalse(report['independentHumanApproval'])
                        self.assertIsNone(report['environmentBypassObserved'])
                self.assertEqual(before, {path.name: path.read_bytes() for path in source.iterdir()})


if __name__ == '__main__':
    unittest.main()
