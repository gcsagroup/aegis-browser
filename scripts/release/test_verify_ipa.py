import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile
import zlib

spec = importlib.util.spec_from_file_location("verify_ipa", Path(__file__).with_name("verify-ipa.py"))
ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipa)


class VerifyIPATests(unittest.TestCase):
    def fixture(self, path, *, identifier="com.gcsa.aegis", extension_build="70", profile=True, manifest=None, icon_data=None, dictionary_versions=None):
        with zipfile.ZipFile(path, "w") as archive:
            for suffix, app_id, build in [("", identifier, "70"),
                                          ("PlugIns/SafariWebExtension.appex/", "com.gcsa.aegis.safari", extension_build),
                                          ("PlugIns/ShareExtension.appex/", "com.gcsa.aegis.share", "70")]:
                root = "Payload/Aegis.app/" + suffix
                archive.writestr(root + "Info.plist", plistlib.dumps({"CFBundleIdentifier": app_id,
                                 "CFBundleInfoDictionaryVersion": (dictionary_versions or {}).get(app_id, "6.0"),
                                 "CFBundleShortVersionString": "3.2", "CFBundleVersion": build,
                                 "AegisReleaseProfile": "alpha"}))
                if profile:
                    archive.writestr(root + "embedded.mobileprovision", "fixture")
            safari = "Payload/Aegis.app/PlugIns/SafariWebExtension.appex/"
            if manifest is None:
                manifest = {"icons": {"48": "icon.png"}}
            archive.writestr(safari + "manifest.json", json.dumps(manifest))

            def chunk(name, data):
                return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))

            image = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 48, 48, 8, 6, 0, 0, 0))
            image += chunk(b"IDAT", zlib.compress((b"\x00" + b"\x00\x40\x80\xff" * 48) * 48))
            archive.writestr(safari + "icon.png", icon_data if icon_data is not None else image + chunk(b"IEND", b""))

    def test_identity_and_extensions(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "test.ipa"
            self.fixture(path)
            self.assertTrue(ipa.verify(path, "3.2", "70"))
            self.assertTrue(ipa.verify(path, "3.2", "70", "alpha"))
            with self.assertRaises(ValueError):
                ipa.verify(path, "3.2", "70", "release")

    def test_stale_identity_extension_build_or_unsigned_package(self):
        for kwargs in ({"identifier": "com.gcsa.aegis.ios.app"}, {"extension_build": "69"}, {"profile": False}):
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "test.ipa"
                self.fixture(path, **kwargs)
                with self.assertRaises(ValueError):
                    ipa.verify(path, "3.2", "70")

    def test_plist_structure_version_is_checked_for_app_and_each_extension(self):
        for identifier in ["com.gcsa.aegis", "com.gcsa.aegis.safari", "com.gcsa.aegis.share"]:
            with self.subTest(identifier=identifier), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "test.ipa"
                self.fixture(path, dictionary_versions={identifier: "7.0"})
                with self.assertRaisesRegex(ValueError, "plist structure version"):
                    ipa.verify(path, "3.2", "70", "alpha")

    def test_committed_app_and_extension_plists_use_the_supported_structure_version(self):
        root = Path(__file__).resolve().parents[2] / "apps/ios"
        for target in ["AegisApp", "SafariWebExtension", "ShareExtension"]:
            with self.subTest(target=target):
                info = plistlib.loads((root / target / "Info.plist").read_bytes())
                self.assertEqual(info["CFBundleInfoDictionaryVersion"], "6.0")

    def test_store_rejected_safari_manifests_and_missing_or_wrong_icons_are_caught_locally(self):
        for manifest in [{}, {"icons": []}, {"icons": {"48": 48}}, {"icons": {"bad": "icon.png"}},
                         {"icons": {"48": "../escape.png"}}, {"icons": {"48": "/absolute.png"}},
                         {"icons": {"48": "missing.png"}}, {"icons": {"64": "icon.png"}}]:
            with self.subTest(manifest=manifest), tempfile.TemporaryDirectory() as temp:
                path = Path(temp) / "test.ipa"
                self.fixture(path, manifest=manifest)
                with self.assertRaises((ValueError, KeyError)):
                    ipa.verify(path, "3.2", "70")

    def test_real_xcode_optimized_icon_remains_valid_after_export(self):
        # Captured from an Xcode 26.6 IPA; its CgBI chunk precedes IHDR.
        icon = (Path(__file__).parent / "fixtures/safari-icon-xcode.png").read_bytes()
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "test.ipa"
            self.fixture(path, icon_data=icon)
            self.assertTrue(ipa.verify(path, "3.2", "70", "alpha"))


if __name__ == "__main__":
    unittest.main()
