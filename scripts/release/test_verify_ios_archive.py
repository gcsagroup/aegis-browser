import importlib.util
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("archive_check", Path(__file__).with_name("verify-ios-archive.py"))
archive_check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive_check)


class ArchiveVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name)
        self.app = self.archive / "Products/Applications/Aegis.app"
        for name, app_id in [("", "com.gcsa.aegis"), ("PlugIns/SafariWebExtension.appex", "com.gcsa.aegis.safari"),
                             ("PlugIns/ShareExtension.appex", "com.gcsa.aegis.share")]:
            bundle = self.app / name
            bundle.mkdir(parents=True, exist_ok=True)
            (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": app_id,
                "CFBundleShortVersionString": "0.8.0", "CFBundleVersion": "1"}))
        resources = Path(__file__).resolve().parents[2] / "apps/ios/SharedWebExtension"
        for source in resources.iterdir():
            if source.name == "manifest.json" or source.suffix == ".png":
                shutil.copyfile(source, self.app / "PlugIns/SafariWebExtension.appex" / source.name)

    def test_complete_archive_is_diagnostic_only(self):
        result = archive_check.verify(self.archive, "0.8.0", "1")
        self.assertEqual(len(result["applications"]), 3)
        self.assertFalse(result["IPA"])
        self.assertFalse(result["TestFlight"])
        self.assertFalse(result["releaseReady"])

    def test_wrong_app_id_version_or_build_fails(self):
        path = self.app / "PlugIns/ShareExtension.appex/Info.plist"
        original = plistlib.loads(path.read_bytes())
        for key, value in [("CFBundleIdentifier", "com.gcsa.aegis.ios.app.share"),
                           ("CFBundleShortVersionString", "3.2"), ("CFBundleVersion", "69")]:
            with self.subTest(key=key):
                path.write_bytes(plistlib.dumps({**original, key: value}))
                with self.assertRaisesRegex(ValueError, "identity mismatch"):
                    archive_check.verify(self.archive, "0.8.0", "1")

    def test_missing_extension_fails(self):
        path = self.app / "PlugIns/ShareExtension.appex"
        (path / "Info.plist").unlink()
        path.rmdir()
        with self.assertRaisesRegex(ValueError, "app extensions"):
            archive_check.verify(self.archive, "0.8.0", "1")

    def test_safari_manifest_missing_icons_fails_before_store_upload(self):
        (self.app / "PlugIns/SafariWebExtension.appex/manifest.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "90849"):
            archive_check.verify(self.archive, "0.8.0", "1")


if __name__ == "__main__":
    unittest.main()
