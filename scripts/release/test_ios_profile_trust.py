"""Real macOS CMS trust negatives; no keychain import or distribution credentials."""
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('profile_trust', Path(__file__).with_name('verify-signed-ios.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ProfileTrustTests(unittest.TestCase):
    def test_invalid_team_and_oversized_cms_fail_before_native_verification(self):
        for team in ['', 'R3JK7R29AC" or true', 'OTHER']:
            with self.subTest(team=team), self.assertRaises(ValueError):
                verifier.verify_distribution_signer(Path('/unused'), team)
        for raw in [b'', b'x' * (5 * 1024 * 1024 + 1)]:
            with self.assertRaises(ValueError):
                verifier.verified_profile(raw)

    @unittest.skipUnless(sys.platform == 'darwin', 'Native Apple trust regression requires macOS')
    def test_valid_self_signed_cms_cannot_claim_to_be_an_apple_provisioning_profile(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            payload, key, cert, cms = [root / name for name in ['payload.plist', 'fixture.key', 'fixture.pem', 'fixture.cms']]
            payload.write_bytes(plistlib.dumps({'TeamIdentifier': ['R3JK7R29AC']}))
            def openssl(*args):
                result = subprocess.run(['/usr/bin/openssl', *map(str, args)], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-keyout', key, '-out', cert,
                    '-subj', '/CN=Apple iPhone OS Provisioning Profile Signing/O=Apple Inc./C=US')
            openssl('smime', '-sign', '-binary', '-nodetach', '-in', payload, '-signer', cert, '-inkey', key, '-outform', 'DER', '-out', cms)
            openssl('smime', '-verify', '-noverify', '-inform', 'DER', '-in', cms, '-out', root / 'decoded.plist')
            self.assertEqual((root / 'decoded.plist').read_bytes(), payload.read_bytes())
            with self.assertRaisesRegex(ValueError, 'CMS signature or signer trust'):
                verifier.verified_profile(cms.read_bytes())

    @unittest.skipUnless(sys.platform == 'darwin', 'Native code-signing regression requires macOS')
    def test_adhoc_signature_cannot_pass_distribution_signer_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / 'fixture'
            shutil.copyfile('/bin/echo', binary)
            result = subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            with self.assertRaises(ValueError):
                verifier.verify_distribution_signer(binary, 'R3JK7R29AC')
