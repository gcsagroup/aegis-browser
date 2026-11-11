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
                                     module=Mock(return_value=SimpleNamespace(verify=Mock())))
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
        value = {'schema': 'aegis-development-archive-v1', 'source': identity, 'version': '1.0.0',
                 'build': '20', 'team': 'ABCDEFGHIJ', 'profile': 'alpha', 'keychainRestored': True,
                 'files': {path: hashlib.sha256(content).hexdigest() for path, content in original.items()},
                 'archive_sha256': hashlib.sha256((root / 'archive.zip').read_bytes()).hexdigest()}
        (root / 'archive-manifest.json').write_text(json.dumps(value))
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
            archive.extract(root, output, identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha')
            self.assertEqual((output / 'Products/Applications/Aegis.app/Aegis').read_bytes(), b'native')
            self.assertEqual((output / 'Products/Applications/Aegis.app/Aegis').stat().st_mode & 0o777, 0o755)

    def test_cross_source_and_archive_tampering_are_rejected_before_extraction(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root)
            with self.assertRaises(ValueError):
                archive.extract(root, root / 'bad', dict(identity, sha='c' * 40), '1.0.0', '20', 'ABCDEFGHIJ', 'alpha')
            (root / 'archive.zip').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                archive.extract(root, root / 'bad', identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha')
            self.assertFalse((root / 'bad').exists())

    def test_archive_zip_escape_is_rejected_even_with_a_matching_transfer_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            identity = self.fixture(root, '../escape')
            with self.assertRaises(ValueError):
                archive.extract(root, root / 'bad', identity, '1.0.0', '20', 'ABCDEFGHIJ', 'alpha')
            self.assertFalse((root / 'bad').exists())
            self.assertFalse((root.parent / 'escape').exists())


if __name__ == '__main__':
    unittest.main()
