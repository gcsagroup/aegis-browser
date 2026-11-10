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

    def fixture(self, directory):
        value = request()
        execution = {'run_id': 999, 'attempt': 1, 'workflow': '.github/workflows/aegis-ios-export.yml',
                     'workflow_commit': 'f' * 40}
        prepared = {'request': value, 'request_sha256': p.digest(value), 'execution': execution,
                    'executor_commit': 'e' * 40}
        names = {'Aegis.ipa', 'Aegis.dSYM.zip', 'signature-verification.json', 'dsym-verification.json',
                 'cloud-upload-reservation.json', 'result.json', 'archive.zip', 'prepared.json', 'native-export.json'}
        for name in names:
            (directory / name).write_bytes(b'fixture-original')
        (directory / 'prepared.json').write_bytes(p.canonical(prepared))
        (directory / 'result.json').write_bytes(p.canonical({'request': value, 'execution': execution,
                                                          'executor_commit': 'e' * 40}))
        result = {'request_sha256': p.digest(value), 'execution': execution, 'destination': 'export-only',
                  'repository': value['producer']['repository'], 'repository_id': value['producer']['repository_id'],
                  'release_id': 12345, 'result_sha256': p.file_digest(directory / 'result.json'),
                  'assets': [{'id': i + 1, 'name': name, 'size': (directory / name).stat().st_size,
                              'digest': 'sha256:' + p.file_digest(directory / name)} for i, name in enumerate(sorted(names))]}
        run = {'id': 999, 'run_attempt': 1, 'path': execution['workflow'], 'head_sha': 'f' * 40,
               'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success',
               'repository': {'id': 1364015229}, 'head_repository': {'id': 1364015229}}
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


if __name__ == '__main__':
    unittest.main()
