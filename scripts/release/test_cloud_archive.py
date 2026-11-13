import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from contextlib import contextmanager
import zipfile

spec = importlib.util.spec_from_file_location('development_transfer', Path(__file__).with_name('cloud-archive.py'))
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class CloudArchiveTests(unittest.TestCase):
    def test_key_activation_precedes_isolation_and_private_probe_runs_before_the_archive(self):
        events = []
        @contextmanager
        def isolated(_output, _evidence, **_options):
            events.append('isolate')
            yield
        def run(*arguments, **_options):
            if '-version' in arguments:
                return b'Xcode 26.6\nBuild version fixture'
            events.append('archive')
            raise ValueError('stop at archive boundary')
        signing = SimpleNamespace(resolve=Mock(return_value=([], {'style': 'manual'})),
                                  require_identity=Mock(side_effect=lambda *_: events.append('identity')))
        access = SimpleNamespace(prepare=Mock(side_effect=lambda *_: events.append('prepare')),
                                 verify=Mock(side_effect=lambda *_: events.append('probe')))
        def module(_name, filename):
            return signing if filename == 'development_signing.py' else access if filename == 'development_key_access.py' else SimpleNamespace(verified_profile=Mock())
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'output'
            native = SimpleNamespace(validate_identity=Mock(), source=Mock(return_value={'sha': 'a' * 40}),
                                     run=run, stage=Mock(return_value=output / 'work'), module=module,
                                     isolated_keychain=isolated, key_access_runtime=lambda _env: native)
            with patch.object(archive, 'engine', return_value=native), self.assertRaisesRegex(ValueError, 'archive boundary'):
                archive.create(output, '1.0.2', '16', 'ABCDEFGHIJ', 'beta', {})
        self.assertEqual(events, ['prepare', 'isolate', 'identity', 'probe', 'archive'])

    def test_producer_digest_stays_bound_to_written_bytes_if_the_path_is_replaced_after_close(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'archive-manifest.json'
            original_fdopen = os.fdopen
            written = []
            @contextmanager
            def replace_after_close(*args, **kwargs):
                with original_fdopen(*args, **kwargs) as stream:
                    yield stream
                written.append(path.read_bytes())
                path.write_bytes(b'replaced after producer write')
            with patch.object(os, 'fdopen', side_effect=replace_after_close):
                digest = archive.write_manifest(path, {'developmentSigning': {'style': 'manual'}})
            self.assertEqual(digest, hashlib.sha256(written[0]).hexdigest())
            self.assertNotEqual(digest, hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_manifest_writer_preserves_existing_evidence_and_bounds_serialization(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'manifest.json'
            digest = archive.write_manifest(path, {'source': 'original'})
            with self.assertRaises(FileExistsError):
                archive.write_manifest(path, {'source': 'changed'})
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), digest)
            oversized = Path(temporary) / 'oversized.json'
            with self.assertRaisesRegex(ValueError, 'size limit'):
                archive.write_manifest(oversized, {'oversized': 'x' * (16 * 1024**2)})
            self.assertFalse(oversized.exists())

    def test_source_movement_during_build_cannot_publish_an_old_source_manifest(self):
        identity = {'sha': 'a' * 40, 'tree': 'b' * 40}
        @contextmanager
        def isolated(_output, evidence, **_options):
            yield
            evidence['keychainRestored'] = True
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / 'transfer'
            native = SimpleNamespace(validate_identity=Mock(), source=Mock(side_effect=[identity, dict(identity, sha='c' * 40)]),
                                     run=Mock(return_value=b'Xcode 26.6\nBuild version 17F113'),
                                     stage=Mock(return_value=output / 'work'), isolated_keychain=isolated,
                                     key_access_runtime=lambda _env: native,
                                     module=Mock(side_effect=lambda _name, file: SimpleNamespace(
                                         resolve=Mock(return_value=(['CODE_SIGN_STYLE=Automatic'], {'style': 'automatic'})),
                                         require_identity=Mock(), verify_archive=Mock()) if file == 'development_signing.py'
                                         else SimpleNamespace(prepare=Mock(return_value=None), verify=Mock(), verified_profile=Mock())))
            with patch.object(archive, 'engine', return_value=native), patch.object(archive, 'verify_development'), \
                    self.assertRaisesRegex(ValueError, 'Source changed'):
                archive.create(output, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha', {})
            self.assertFalse((output / 'archive-manifest.json').exists())
            self.assertFalse((output / 'archive.zip').exists())

    def fixture(self, root, name='Info.plist'):
        original = {'Info.plist': b'archive', 'Products/Applications/Aegis.app/Aegis': b'native'}
        with zipfile.ZipFile(root / 'archive.zip', 'w') as transfer:
            for path, content in original.items():
                item = zipfile.ZipInfo(path if path != 'Info.plist' else name)
                item.external_attr = 0o100755 << 16
                transfer.writestr(item, content)
        identity = {'sha': 'a' * 40, 'tree': 'b' * 40}
        value = {'schema': 'aegis-development-archive-v2', 'source': identity, 'version': '1.0.0',
                 'build': '20', 'team': 'ABCDEFGHIJ', 'profile': 'alpha', 'keychainRestored': True,
                 'developmentSigning': {'style': 'automatic'},
                 'files': {path: hashlib.sha256(content).hexdigest() for path, content in original.items()},
                 'archive_sha256': hashlib.sha256((root / 'archive.zip').read_bytes()).hexdigest()}
        (root / 'archive-manifest.json').write_text(json.dumps(value))
        self.producer_digest = hashlib.sha256((root / 'archive-manifest.json').read_bytes()).hexdigest()
        return identity

    def test_build_environment_removes_cloud_upload_and_github_credentials(self):
        environment = dict(os.environ, AEGIS_ASC_KEY_BASE64='secret', AEGIS_ASC_KEY_PATH='/secret',
                           APP_STORE_CONNECT_API_KEY_KEY_CONTENT='secret', ASC_KEY='secret',
                           GH_TOKEN='token', GITHUB_TOKEN='token', DEVELOPMENT_TEAM='ABCDEFGHIJ')
        result = archive.build_environment(environment)
        for key in ['AEGIS_ASC_KEY_BASE64', 'AEGIS_ASC_KEY_PATH', 'APP_STORE_CONNECT_API_KEY_KEY_CONTENT',
                    'ASC_KEY', 'GH_TOKEN', 'GITHUB_TOKEN']:
            self.assertNotIn(key, result)
        self.assertEqual(result['DEVELOPMENT_TEAM'], 'ABCDEFGHIJ')
        self.assertEqual(environment['AEGIS_ASC_KEY_BASE64'], 'secret')

    def test_original_archive_bytes_and_executable_mode_survive_the_transfer(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root)
            output = root / 'extracted'
            archive.extract(root, output, identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha',
                            expected_manifest_sha256=self.producer_digest)
            self.assertEqual((output / 'Products/Applications/Aegis.app/Aegis').read_bytes(), b'native')
            self.assertEqual((output / 'Products/Applications/Aegis.app/Aegis').stat().st_mode & 0o777, 0o755)

    def test_cross_source_and_archive_tampering_are_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root)
            with self.assertRaises(ValueError):
                archive.extract(root, root / 'bad', dict(identity, sha='c' * 40), '1.0.0', '20', 'ABCDEFGHIJ', 'alpha',
                                expected_manifest_sha256=self.producer_digest)
            (root / 'archive.zip').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                archive.extract(root, root / 'bad', identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha',
                                expected_manifest_sha256=self.producer_digest)
            self.assertFalse((root / 'bad').exists())

    def test_missing_development_selection_is_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root)
            path = root / 'archive-manifest.json'
            value = json.loads(path.read_text())
            value.pop('developmentSigning')
            path.write_text(json.dumps(value))
            producer_digest = hashlib.sha256(path.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):
                archive.extract(root, root / 'bad', identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha',
                                expected_manifest_sha256=producer_digest)
            self.assertFalse((root / 'bad').exists())

    def test_archive_zip_escape_is_rejected_even_with_a_matching_transfer_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root, '../escape')
            with self.assertRaises(ValueError):
                archive.extract(root, root / 'bad', identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha',
                                expected_manifest_sha256=self.producer_digest)
            self.assertFalse((root / 'bad').exists())
            self.assertFalse((root.parent / 'escape').exists())

    def test_sidecar_cannot_disable_manual_signer_checks_with_unchanged_archive_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root)
            path = root / 'archive-manifest.json'
            value = json.loads(path.read_text())
            value['developmentSigning'] = {
                'style': 'manual', 'certificateSha1': 'C' * 40, 'configurationSha256': 'd' * 64,
                'profiles': {identifier: {'uuid': 'abcdef01-2345-6789-abcd-123456789abc', 'sha256': 'e' * 64}
                             for identifier in ['com.gcsa.aegis', 'com.gcsa.aegis.safari', 'com.gcsa.aegis.share']}}
            path.write_text(json.dumps(value))
            original_digest = hashlib.sha256(path.read_bytes()).hexdigest()
            original_archive = (root / 'archive.zip').read_bytes()
            value['developmentSigning'] = {'style': 'automatic'}
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'producer job output'):
                archive.extract(root, root / 'bad', identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha',
                                expected_manifest_sha256=original_digest)
            self.assertEqual((root / 'archive.zip').read_bytes(), original_archive)
            self.assertFalse((root / 'bad').exists())

    def test_missing_or_invalid_independent_digest_fails_before_extraction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root)
            for digest in [None, '', 'A' * 64, '0' * 64, ['a' * 64]]:
                with self.subTest(digest=digest), self.assertRaisesRegex(ValueError, 'producer job output'):
                    archive.extract(root, root / 'bad', identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha',
                                    expected_manifest_sha256=digest)
                self.assertFalse((root / 'bad').exists())


if __name__ == '__main__':
    unittest.main()
