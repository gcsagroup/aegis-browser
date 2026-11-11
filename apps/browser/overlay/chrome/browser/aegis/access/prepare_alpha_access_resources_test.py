import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

from prepare_alpha_access_resources import stage


class AlphaResourcesTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = self.root / "input"
        self.source.mkdir()
        self.binary = b"fixture executable - never run"
        self.node = json.dumps({"outbounds": [{"protocol": "vless",
            "streamSettings": {"network": "tcp", "security": "reality"}}]}).encode()
        (self.source / "xray").write_bytes(self.binary)
        (self.source / "node.json").write_bytes(self.node)
        self.manifest = {"schemaVersion": 1, "channel": "alpha",
            "binaryRelativePath": "xray", "nodeConfigRelativePath": "node.json",
            "binarySha256": hashlib.sha256(self.binary).hexdigest(),
            "nodeConfigSha256": hashlib.sha256(self.node).hexdigest()}
        self.write_manifest()

    def write_manifest(self):
        (self.source / "core-manifest.json").write_text(json.dumps(self.manifest))

    def test_alpha_pins_private_modes_and_bytes(self):
        output = self.root / "output"
        stage(self.source, output, "alpha")
        self.assertEqual((output / "node.json").read_bytes(), self.node)
        self.assertEqual(output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((output / "node.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((output / "xray").stat().st_mode & 0o777, 0o700)

    def test_other_channels_do_not_create_resources(self):
        for channel in ("dev", "stable", "release", ""):
            output = self.root / ("output-" + channel)
            with self.assertRaises(ValueError):
                stage(self.source, output, channel)
            self.assertFalse(output.exists())

    def test_beta_requires_matching_manifest_and_preserves_bytes(self):
        output = self.root / "output"
        with self.assertRaises(ValueError):
            stage(self.source, output, "beta")
        self.assertFalse(output.exists())
        self.manifest["channel"] = "beta"
        self.write_manifest()
        with self.assertRaises(ValueError):
            stage(self.source, output, "alpha")
        self.assertFalse(output.exists())
        stage(self.source, output, "beta")
        self.assertEqual((output / "node.json").read_bytes(), self.node)

    def test_tampered_node_or_binary_is_rejected_before_output(self):
        for name, original in (("node.json", self.node), ("xray", self.binary)):
            (self.source / name).write_bytes(original + b"tamper")
            output = self.root / "output"
            with self.assertRaises(ValueError):
                stage(self.source, output, "alpha")
            self.assertFalse(output.exists())
            (self.source / name).write_bytes(original)

    def test_manifest_cannot_select_outside_bundle(self):
        self.manifest["binaryRelativePath"] = "../external"
        self.write_manifest()
        with self.assertRaises(ValueError):
            stage(self.source, self.root / "output", "alpha")

    def test_existing_immutable_candidate_inode_is_preserved(self):
        output = self.root / "output"
        stage(self.source, output, "alpha")
        prior = self.root / "prior-node"
        os.link(output / "node.json", prior)
        previous_inode = prior.stat().st_ino
        stage(self.source, output, "alpha")
        self.assertEqual(prior.read_bytes(), self.node)
        self.assertEqual(prior.stat().st_ino, previous_inode)
        self.assertNotEqual((output / "node.json").stat().st_ino, previous_inode)


if __name__ == "__main__":
    unittest.main()
