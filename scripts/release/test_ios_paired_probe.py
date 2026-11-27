import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


PROBE = Path(__file__).resolve().parents[2] / "apps/ios/scripts/paired-probe/local-relay.py"


class PairedProbeAddressTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("paired_probe_relay", PROBE)
        cls.relay = importlib.util.module_from_spec(spec)
        with mock.patch.dict(os.environ, {"AEGIS_PROBE_OUTPUT": "/tmp"}):
            spec.loader.exec_module(cls.relay)

    def test_private_address_is_accepted(self):
        with mock.patch.object(self.relay.subprocess, "check_output",
                               side_effect=["   interface: en0\n", "192.168.1.12\n"]) as execute:
            self.assertEqual(self.relay.local_address(), "192.168.1.12")
        self.assertEqual(execute.call_args_list, [
            mock.call(["/sbin/route", "-n", "get", "default"], text=True),
            mock.call(["/usr/sbin/ipconfig", "getifaddr", "en0"], text=True),
        ])

    def test_non_lan_addresses_are_rejected(self):
        for address in ("8.8.8.8", "127.0.0.1", "169.254.10.10", "0.0.0.0", "240.0.0.1"):
            with self.subTest(address=address), mock.patch.object(
                self.relay.subprocess, "check_output", side_effect=["   interface: en0\n", address + "\n"]
            ):
                with self.assertRaisesRegex(RuntimeError, "requires a private local address"):
                    self.relay.local_address()

    def test_unexpected_route_interface_does_not_reach_ipconfig(self):
        with mock.patch.object(self.relay.subprocess, "check_output",
                               return_value="   interface: -unexpected\n") as execute:
            with self.assertRaisesRegex(RuntimeError, "default network interface"):
                self.relay.local_address()
        execute.assert_called_once()

    def test_xray_requires_an_absolute_executable_file(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "xray"
            executable.touch(mode=0o600)
            for invalid in ("", "./xray", str(executable), directory, str(executable.with_name("missing"))):
                with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, "absolute path"):
                    self.relay.xray_executable(invalid)
            executable.chmod(0o700)
            self.assertEqual(self.relay.xray_executable(str(executable)), executable.resolve())


if __name__ == "__main__":
    unittest.main()
