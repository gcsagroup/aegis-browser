# Copyright 2026 GCSA
import unittest
import plistlib
import subprocess  # nosec B404 - exercise the build action through its CLI.
import sys
import tempfile
from pathlib import Path
import verify_access_build_identity as identity


class BuildIdentityTests(unittest.TestCase):
    def test_internal_channels_require_explicit_capability(self):
        for product in ("unknown", "debug", "alpha", "beta", "stable"):
            for enabled in (False, True):
                with self.subTest(product=product, enabled=enabled):
                    if enabled and product not in ("debug", "alpha"):
                        with self.assertRaises(ValueError):
                            identity.validate_identity(product, enabled, False, {})
                    else:
                        self.assertEqual(identity.validate_identity(product, enabled, False, {}), "unknown")

    def test_known_release_metadata_rejects_conflicting_identity(self):
        for channel, metadata in (("beta", {"KSProductID": "Chrome", "KSChannelID": "arm64-beta"}), ("stable", {"KSProductID": "Chrome"})):
            for product in ("unknown", "debug", "alpha", "beta", "stable"):
                with self.subTest(channel=channel, product=product):
                    if product not in ("unknown", channel):
                        with self.assertRaises(ValueError):
                            identity.validate_identity(product, False, True, metadata)
                    else:
                        self.assertEqual(identity.validate_identity(product, False, True, metadata), channel)

    def test_channel_metadata_matches_chromium_mac_parsing(self):
        for tag, expected in ((None, "stable"), ("arm64", "stable"),
                              ("universal", "stable"), ("extended", "stable"),
                              ("arm64-extended", "stable"), ("universal-beta", "beta"),
                              ("dev", "dev"), ("arm64-canary", "canary"),
                              ("", "unknown"), ("future", "unknown")):
            with self.subTest(tag=tag):
                metadata = {"KSProductID": "Chrome"}
                if tag is not None:
                    metadata["KSChannelID"] = tag
                self.assertEqual(identity.chromium_channel(True, metadata), expected)
                self.assertEqual(identity.chromium_channel(False, metadata), "unknown")

    def test_branded_build_without_keystone_has_unknown_channel(self):
        for metadata in ({}, {"KSChannelID": "beta"}, {"KSChannelID": "arm64"}):
            self.assertEqual(identity.chromium_channel(True, metadata), "unknown")
            for product in ("debug", "alpha", "beta"):
                self.assertEqual(identity.validate_identity(product, False, True, metadata), "unknown")
        self.assertEqual(identity.chromium_channel(True, {"KSProductID": ""}), "stable")

    def test_branded_internal_dev_can_use_explicit_internal_identity(self):
        for product in ("debug", "alpha"):
            self.assertEqual(identity.validate_identity(product, True, True, {"KSProductID": "Chrome", "KSChannelID": "dev"}), "dev")
        with self.assertRaises(ValueError):
            identity.validate_identity("future", False, False, {})

    def test_build_action_rejects_conflict_before_writing_stamp(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info = root / "Info.plist"
            stamp = root / "verified.stamp"
            info.write_bytes(plistlib.dumps({"KSProductID": "Chrome", "KSChannelID": "beta"}))
            command = [sys.executable, "-B", str(Path(identity.__file__)),
                       "--plist", str(info), "--product-channel", "alpha",
                       "--internal-options", "false", "--chrome-branded", "true",
                       "--stamp", str(stamp)]
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
            conflict = subprocess.run(command, capture_output=True, text=True)  # nosec B603 - test interpreter and local fixture.
            self.assertNotEqual(conflict.returncode, 0)
            self.assertIn("conflicts", conflict.stderr)
            self.assertFalse(stamp.exists())
            command[command.index("alpha")] = "beta"
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
            accepted = subprocess.run(command, capture_output=True, text=True)  # nosec B603 - test interpreter and local fixture.
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertTrue(stamp.is_file())


if __name__ == "__main__":
    unittest.main()
