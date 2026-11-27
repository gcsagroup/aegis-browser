import importlib.util
import os
from pathlib import Path
import unittest
from unittest import mock


PROBE = Path(__file__).resolve().parents[2] / "apps/ios/scripts/paired-probe/local-relay.py"


class PairedProbeAddressTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("paired_probe_relay", PROBE)
        cls.relay = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"AEGIS_PROBE_OUTPUT": "/tmp", "AEGIS_PROBE_XRAY": "/usr/bin/false"}):
            spec.loader.exec_module(cls.relay)

    def local_address(self, address):
        responses = ["   interface: en0\n", address + "\n"]
        with mock.patch.object(self.relay.subprocess, "check_output", side_effect=responses):
            return self.relay.local_address()

    def test_private_address_is_accepted(self):
        self.assertEqual(self.local_address("192.168.1.12"), "192.168.1.12")

    def test_public_address_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "requires a private local address"):
            self.local_address("8.8.8.8")


if __name__ == "__main__":
    unittest.main()
