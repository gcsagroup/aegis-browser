import configparser
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import prepare_alpha_access_resources as resources
from prepare_alpha_access_resources import stage
from prepare_access_installer_release import prepare


class AlphaResourcesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "input"
        self.source.mkdir()
        self.binary = b"fixture executable - never run"
        self.binary_name = "xray.exe" if os.name == "nt" else "xray"
        self.node = json.dumps({"outbounds": [{"protocol": "vless",
            "streamSettings": {"network": "tcp", "security": "reality"}}]}).encode()
        (self.source / self.binary_name).write_bytes(self.binary)
        (self.source / "node.json").write_bytes(self.node)
        self.manifest = {"schemaVersion": 1, "channel": "alpha",
            "binaryRelativePath": self.binary_name, "nodeConfigRelativePath": "node.json",
            "binarySha256": hashlib.sha256(self.binary).hexdigest(),
            "nodeConfigSha256": hashlib.sha256(self.node).hexdigest()}
        self.write_manifest()

    def write_manifest(self):
        (self.source / "core-manifest.json").write_text(json.dumps(self.manifest))

    def stage(self, output, channel="alpha"):
        stage(self.source, output, channel, self.binary_name)

    def test_alpha_pins_private_modes_and_bytes(self):
        output = self.root / "output"
        self.stage(output)
        self.assertEqual((output / "node.json").read_bytes(), self.node)
        self.assertEqual((output / self.binary_name).read_bytes(), self.binary)
        if os.name != "nt":
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual((output / "node.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual((output / self.binary_name).stat().st_mode & 0o777, 0o700)

    def test_windows_staging_uses_system_tool_and_isolates_its_environment(self):
        system = self.root / "system" / "System32"
        output = self.root / "private staging"
        with mock.patch.dict(os.environ, {"SystemRoot": str(self.root / "other"),
                                         "PSModulePath": "caller modules"}), \
                mock.patch.object(resources, "windows_system_directory", return_value=system), \
                mock.patch.object(resources.subprocess, "run") as execute:
            execute.return_value.returncode = 0
            resources.stage_windows_directory(output)
        argv, = execute.call_args.args
        options = execute.call_args.kwargs
        home = system / "WindowsPowerShell" / "v1.0"
        self.assertEqual(Path(argv[0]), home / "powershell.exe")
        self.assertEqual(options["cwd"], system)
        self.assertEqual(Path(options["env"]["SystemRoot"]), system.parent)
        self.assertEqual(Path(options["env"]["PSModulePath"]), home / "Modules")
        self.assertEqual(options["env"]["AEGIS_PRIVATE_ACCESS_STAGE"], str(output))
        self.assertNotIn(str(output), argv[-1])

    def test_ninja_precreated_output_parent_is_secured_before_staging(self):
        output = self.root / "ninja-parent"
        output.mkdir()
        self.stage(output)
        self.assertEqual((output / "node.json").read_bytes(), self.node)
        self.assertEqual((output / self.binary_name).read_bytes(), self.binary)

    @unittest.skipUnless(os.name == "nt", "Windows reparse point regression")
    def test_reparse_output_is_rejected_without_touching_its_destination(self):
        destination = self.root / "external"
        destination.mkdir()
        marker = destination / "node.json"
        marker.write_bytes(b"unrelated")
        output = self.root / "linked-output"
        try:
            output.symlink_to(destination, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"Directory symlink unavailable: {error.winerror}")
        with self.assertRaises(ValueError):
            self.stage(output)
        self.assertEqual(marker.read_bytes(), b"unrelated")
        self.assertFalse((destination / self.binary_name).exists())

    def test_other_channels_do_not_create_resources(self):
        for channel in ("dev", "stable", "release", ""):
            output = self.root / ("output-" + channel)
            with self.assertRaises(ValueError):
                self.stage(output, channel)
            self.assertFalse(output.exists())

    def test_beta_requires_matching_manifest_and_preserves_bytes(self):
        output = self.root / "output"
        with self.assertRaises(ValueError):
            self.stage(output, "beta")
        self.assertFalse(output.exists())
        self.manifest["channel"] = "beta"
        self.write_manifest()
        with self.assertRaises(ValueError):
            self.stage(output)
        self.assertFalse(output.exists())
        self.stage(output, "beta")
        self.assertEqual((output / "node.json").read_bytes(), self.node)

    def test_tampered_node_or_binary_is_rejected_before_output(self):
        for name, original in (("node.json", self.node), (self.binary_name, self.binary)):
            (self.source / name).write_bytes(original + b"tamper")
            output = self.root / "output"
            with self.assertRaises(ValueError):
                self.stage(output)
            self.assertFalse(output.exists())
            (self.source / name).write_bytes(original)

    def test_manifest_cannot_select_outside_bundle(self):
        self.manifest["binaryRelativePath"] = "../external"
        self.write_manifest()
        with self.assertRaises(ValueError):
            self.stage(self.root / "output")

    def test_existing_immutable_candidate_inode_is_preserved(self):
        output = self.root / "output"
        self.stage(output)
        prior = self.root / "prior-node"
        os.link(output / "node.json", prior)
        previous_inode = prior.stat().st_ino
        self.stage(output)
        self.assertEqual(prior.read_bytes(), self.node)
        self.assertEqual(prior.stat().st_ino, previous_inode)
        self.assertNotEqual((output / "node.json").stat().st_ino, previous_inode)


class PrivateInstallerManifestTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.source = self.root / "chrome.release"
        self.output = self.root / "generated" / "private.release"
        self.template = "[GENERAL]\nchrome.exe: %(ChromeDir)s\\\n\n[HIDPI]\n"
        self.source.write_text(self.template)

    def test_private_channels_install_exact_resources_beside_chrome_dll(self):
        for channel in ("alpha", "beta"):
            with self.subTest(channel=channel):
                prepare(self.source, self.output, channel)
                config = configparser.ConfigParser(defaults={
                    "ChromeDir": "Chrome-bin", "VersionDir": "Chrome-bin/1.2.3.4"})
                config.read(self.output)
                for name in ("core-manifest.json", "node.json", "xray.exe"):
                    self.assertEqual(config.get("GENERAL", "AegisAlphaAccess\\" + name),
                                     "Chrome-bin/1.2.3.4\\AegisAlphaAccess\\")
                self.assertEqual(config.get("GENERAL", "chrome.exe"), "Chrome-bin\\")
                self.assertEqual(self.source.read_text(), self.template)

    def test_ordinary_channels_cannot_generate_private_installer_entries(self):
        for channel in ("dev", "stable", "release", ""):
            with self.assertRaises(ValueError):
                prepare(self.source, self.output, channel)
            self.assertFalse(self.output.exists())
        self.assertEqual(self.source.read_text(), self.template)

    def test_unexpected_or_already_private_template_is_rejected(self):
        for template in ("[GENERAL]\n", self.template + "\n[HIDPI]\n",
                         self.template + "\n# AegisAlphaAccess\\node.json\n"):
            self.source.write_text(template)
            with self.assertRaises(ValueError):
                prepare(self.source, self.output, "alpha")
            self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
