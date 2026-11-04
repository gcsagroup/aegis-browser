import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('dsym', Path(__file__).with_name('verify-ios-dsyms.py'))
dsym = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dsym)


class DsymTests(unittest.TestCase):
    def fixture(self, root):
        for relative, identifier in dsym.TARGETS.items():
            bundle = root / 'Products/Applications' / relative
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier,
                'CFBundleShortVersionString': '0.8.0', 'CFBundleVersion': '101', 'CFBundleExecutable': 'Fixture'}))

    def test_all_three_target_uuid_sets_must_match_their_dwarf_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            values = [('arm64', 'A' * 36)]
            with patch.object(dsym, 'uuids', return_value=values):
                self.assertEqual(dsym.verify(root, '0.8.0', '101')['targetCount'], 3)
            with patch.object(dsym, 'uuids', side_effect=lambda p: values if 'DWARF' not in p.parts else [('arm64', 'B' * 36)]):
                with self.assertRaisesRegex(ValueError, 'UUID differs'):
                    dsym.verify(root, '0.8.0', '101')

    def test_wrong_native_identity_and_symlink_symbols_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            with self.assertRaisesRegex(ValueError, 'identity differs'):
                dsym.verify(root, '0.8.1', '101')
            (root / 'dSYMs').mkdir()
            (root / 'dSYMs/link').symlink_to(root / 'Info.plist')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                dsym.export_zip(root, root / 'symbols.zip')


if __name__ == '__main__':
    unittest.main()
