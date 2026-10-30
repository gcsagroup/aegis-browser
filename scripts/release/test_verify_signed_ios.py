"""Host-independent hostile archive regressions; genuine signing is tested on macOS."""
import json
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(__file__).with_name("verify-signed-ios.py")
PROFILES = {"com.gcsa.aegis": "App Store App", "com.gcsa.aegis.safari": "App Store Safari Extension", "com.gcsa.aegis.share": "App Store Share Extension"}

class SignedIpaArchiveTests(unittest.TestCase):
    def test_encryption_declaration_matches_committed_boolean_and_rejects_missing_or_wrong_type(self):
        spec = importlib.util.spec_from_file_location('verify_signed', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(hasattr(module, 'verify_encryption_declaration'), 'source/export declaration comparison missing')
        key = 'ITSAppUsesNonExemptEncryption'
        self.assertIs(module.verify_encryption_declaration({key: False}, {key: False}), False)
        self.assertIs(module.verify_encryption_declaration({key: True}, {key: True}), True)
        self.assertIsNone(module.verify_encryption_declaration({}, {}))
        for value in [{}, {key: True}, {key: 'false'}, {key: 0}]:
            with self.subTest(exported=value), self.assertRaises(ValueError):
                module.verify_encryption_declaration({key: False}, value)
        for value in ['false', 0, None]:
            with self.subTest(source=value), self.assertRaises(ValueError):
                module.verify_encryption_declaration({key: value}, {key: False})

    def reject(self, members, expected):
        with tempfile.TemporaryDirectory() as directory:
            ipa = Path(directory) / "input.ipa"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(ipa, "w") as archive:
                    for name, content, mode in members:
                        info = zipfile.ZipInfo(name)
                        if mode:
                            info.create_system = 3
                            info.external_attr = mode << 16
                        archive.writestr(info, content)
            result = subprocess.run([sys.executable, str(SCRIPT), str(ipa), "1.0.0", "6", "alpha",
                                     "--team", "ABCDEFGHIJ", "--certificate-sha1", "A" * 40,
                                     "--profiles-json", json.dumps(PROFILES), "--source-root", str(ROOT)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertRegex(result.stderr, expected)
            self.assertFalse((Path(directory).parent / "aegis-escaped-test-file").exists())

    def test_parent_path_is_rejected_before_extraction(self):
        self.reject([("../aegis-escaped-test-file", b"escape", 0)], "Unsafe archive path")

    def test_absolute_path_is_rejected_before_extraction(self):
        self.reject([("/private/aegis-escaped-test-file", b"escape", 0)], "Unsafe archive path")

    def test_symbolic_link_is_rejected_before_extraction(self):
        self.reject([("Payload/Aegis.app/link", b"/private", 0o120777)], "Archive symlink")

    def test_duplicate_member_is_rejected_before_metadata_or_signing(self):
        self.reject([("Payload/Aegis.app/Info.plist", b"first", 0),
                     ("Payload/Aegis.app/Info.plist", b"second", 0)], "Duplicate archive member")

if __name__ == "__main__":
    unittest.main()
