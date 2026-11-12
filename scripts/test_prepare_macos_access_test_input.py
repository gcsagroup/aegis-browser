import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("prepare-macos-access-test-input.py")
URI = ("vless://00000000-0000-4000-8000-000000000001@test.invalid:443?"
       "security=reality&pbk=fixture-key&sni=example.invalid&sid=abcd&fp=chrome")


class PrivateTestInput(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.binary = root / "test-xray"
        self.binary.write_bytes(b"offline synthetic executable")
        self.pin = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.output = root / "private-input"

    def invoke(self, channel="beta", uri=URI, pin=None, extra=()):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--channel", channel,
             "--xray", str(self.binary), "--xray-sha256", pin or self.pin,
             "--output-dir", str(self.output), *extra],
            env={**os.environ, "AEGIS_ACCESS_TEST_NODE_URI": uri},
            capture_output=True, text=True, check=False,
        )

    def test_secret_to_pinned_beta_input(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")
        manifest = json.loads((self.output / "core-manifest.json").read_bytes())
        self.assertEqual(manifest["channel"], "beta")
        self.assertEqual(manifest["binarySha256"], self.pin)
        node = (self.output / "node.json").read_bytes()
        self.assertEqual(manifest["nodeConfigSha256"], hashlib.sha256(node).hexdigest())
        outbound = json.loads(node)["outbounds"][0]
        self.assertEqual(outbound["settings"]["vnext"][0]["address"], "test.invalid")
        self.assertEqual(outbound["streamSettings"]["realitySettings"]["shortId"], "abcd")
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.output / "node.json").stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual((self.output / "node.json").read_bytes(), node)

    def test_file_input_keeps_alpha_compatibility(self):
        path = self.binary.with_name("node-uri")
        path.write_text(URI)
        result = self.invoke("alpha", uri="", extra=("--node-file", str(path)))
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads((self.output / "core-manifest.json").read_bytes())
        self.assertEqual(manifest["channel"], "alpha")

    def test_node_file_selects_tcp_from_mixed_outbounds(self):
        tcp = {"type": "vless", "server": "test.invalid", "server_port": 443,
               "uuid": "00000000-0000-4000-8000-000000000001",
               "tls": {"server_name": "example.invalid",
                       "reality": {"enabled": True, "public_key": "fixture-key",
                                   "short_id": "abcd"}}}
        ws = {"protocol": "vless", "streamSettings": {"wsSettings": {}}}
        path = self.binary.with_name("client.json")
        path.write_text(json.dumps({"outbounds": [ws, tcp],
                                    "unrelated": {"allowInsecure": True}}))
        result = self.invoke(uri="", extra=("--node-file", str(path)))
        self.assertEqual(result.returncode, 0, result.stderr)
        emitted = json.loads((self.output / "node.json").read_bytes())["outbounds"]
        self.assertEqual(len(emitted), 1)
        self.assertEqual(emitted[0]["streamSettings"]["network"], "tcp")

    def test_ws_only_or_insecure_selected_node_is_rejected(self):
        path = self.binary.with_name("client.json")
        for stream in ({"wsSettings": {}}, {"network": "tcp", "security": "reality",
                       "realitySettings": {"allowInsecure": True, "serverName": "test.invalid",
                                          "publicKey": "fixture-key", "shortId": "abcd"}}):
            with self.subTest(stream=stream):
                node = {"protocol": "vless", "settings": {"vnext": [
                        {"address": "test.invalid", "port": 443, "users": [{"id": "fixture"}]}]},
                        "streamSettings": stream}
                path.write_text(json.dumps({"outbounds": [node]}))
                result = self.invoke(uri="", extra=("--node-file", str(path)))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())

    def test_off_channel_pin_and_private_errors(self):
        for opts in ({"channel": "stable"}, {"pin": "0" * 64},
                     {"uri": URI + "&flow=fixture-secret-should-not-leak"}, {"uri": ""}):
            with self.subTest(opts=tuple(opts.keys())):
                result = self.invoke(**opts)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("fixture-secret", result.stderr + result.stdout)
                self.assertNotIn("test.invalid", result.stderr + result.stdout)
                self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
