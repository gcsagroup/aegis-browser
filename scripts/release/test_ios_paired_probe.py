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


class CertificateSANTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("certificate_san", PROBE.with_name("certificate_san.py"))
        cls.decoder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.decoder)

    @staticmethod
    def leaf_with_sans(names):
        # Small synthetic leaf envelopes for testing the SAN decoder.
        extension = b"\x06\x03\x55\x1d\x11" + bytes([0x04, len(names) + 2]) + bytes([0x30, len(names)]) + names
        extensions = bytes([0xa3, len(extension) + 4, 0x30, len(extension) + 2, 0x30, len(extension)]) + extension
        body = b"\x02\x01\x01" + b"\x30\x00" * 5 + extensions
        fields = bytes([0x30, len(body)]) + body + b"\x30\x00\x03\x01\x00"
        return bytes([0x30, len(fields)]) + fields

    def test_other_name_with_high_tag_preserves_dns_evidence(self):
        dns = b"\x82\x0bexample.com"
        high_tagged_value = b"\x9f\x81\x00\x01A"
        other_name = b"\xa0\x0c\x06\x03\x2a\x03\x04\xa0\x05" + high_tagged_value
        self.assertEqual(self.decoder.dns_subject_alternative_names(self.leaf_with_sans(dns + other_name)),
                         ["example.com"])

    def test_constructed_directory_attribute_rejects_truncated_child(self):
        truncated_value = b"\x30\x03\x0c\x02A"
        directory_name = b"\xa4\x10\x30\x0e\x31\x0c\x30\x0a\x06\x03\x55\x04\x03" + truncated_value
        with self.assertRaisesRegex(ValueError, "Truncated DER value"):
            self.decoder.dns_subject_alternative_names(self.leaf_with_sans(directory_name))

    def test_invalid_universal_forms_cannot_hide_a_constructed_value(self):
        for invalid in (b"\x10\x00", b"\x11\x00", b"\x20\x00"):
            with self.subTest(invalid=invalid):
                other_name = b"\xa0\x09\x06\x03\x2a\x03\x04\xa0\x02" + invalid
                with self.assertRaisesRegex(ValueError, "Invalid universal DER tag form"):
                    self.decoder.dns_subject_alternative_names(self.leaf_with_sans(other_name))


if __name__ == "__main__":
    unittest.main()
