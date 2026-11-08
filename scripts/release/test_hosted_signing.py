import datetime
import base64
import hashlib
import importlib.util
import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('hosted_signing', Path(__file__).with_name('hosted-signing.py'))
hosted = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hosted)


class HostedSigningTest(unittest.TestCase):
    def profile(self):
        cert = b'certificate'
        return {'Name': 'Expected', 'UUID': 'ABCD1234-1234-1234-1234-123456789ABC',
                'TeamIdentifier': ['ABCDEFGHIJ'], 'ExpirationDate': datetime.datetime.utcnow() + datetime.timedelta(days=1),
                'DeveloperCertificates': [cert], 'Entitlements': {'application-identifier': 'ABCDEFGHIJ.com.gcsa.aegis',
                'get-task-allow': False, 'com.apple.security.application-groups': ['group.com.gcsa.aegis.ios.share-inbox']}}

    def test_accepts_matching_app_store_profile(self):
        profile = self.profile()
        self.assertEqual(hosted.validate_profile(profile, 'com.gcsa.aegis', 'Expected', 'ABCDEFGHIJ',
                          hashlib.sha1(b'certificate').hexdigest()), profile['UUID'])

    def test_rejects_mismatched_or_development_profile(self):
        for change in ({'ProvisionedDevices': ['device']}, {'Name': 'Wrong'}, {'UUID': '../../escape'},
                       {'DeveloperCertificates': [b'other']}, {'ExpirationDate': datetime.datetime(2001, 1, 1)}):
            profile = self.profile()
            profile.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                hosted.validate_profile(profile, 'com.gcsa.aegis', 'Expected', 'ABCDEFGHIJ', hashlib.sha1(b'certificate').hexdigest())

    def test_rejects_non_github_hosted_runner(self):
        with self.assertRaises(ValueError):
            hosted.check_host({'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted'})

    def test_identity_uses_exact_fingerprint_and_distribution_type(self):
        fingerprint = 'A1' * 20
        output = f'  1) {fingerprint} "Apple Distribution: Fixture Team (ABCDEFGHIJ)"\n     1 valid identities found\n'
        self.assertTrue(hosted.has_identity(output, fingerprint.lower()))
        self.assertFalse(hosted.has_identity(output, 'B2' * 20))
        self.assertFalse(hosted.has_identity(output.replace('Apple Distribution:', 'Apple Development:'), fingerprint))

    def test_temporary_assets_are_removed_after_success_and_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                certificate = b'certificate'
                fingerprint = hashlib.sha1(certificate).hexdigest().upper()
                profile_bytes = {}
                for index, identifier in enumerate(hosted.TARGETS):
                    profile = self.profile()
                    profile['UUID'] = f'ABCD123{index}-1234-1234-1234-123456789ABC'
                    profile['Entitlements']['application-identifier'] = 'ABCDEFGHIJ.' + identifier
                    profile_bytes[identifier] = plistlib.dumps(profile)
                environment = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'macOS',
                               'RUNNER_TEMP': str(root), 'AEGIS_APPLE_TEAM_ID': 'ABCDEFGHIJ',
                               'AEGIS_IOS_CERT_SHA1': fingerprint,
                               'AEGIS_IOS_PROFILES': json.dumps(dict.fromkeys(hosted.TARGETS, 'Expected')),
                               'AEGIS_IOS_DISTRIBUTION_P12_BASE64': base64.b64encode(b'p12').decode(),
                               'AEGIS_IOS_DISTRIBUTION_P12_PASSWORD': 'fixture'}
                environment.update({secret: base64.b64encode(profile_bytes[identifier]).decode()
                                    for identifier, secret in hosted.TARGETS.items()})

                def security(*args):
                    self.assertNotIn('AEGIS_IOS_DISTRIBUTION_P12_PASSWORD', os.environ)
                    if args[1:3] == ('cms', '-D'):
                        return Path(args[-1]).read_bytes()
                    if args[1] == 'create-keychain':
                        Path(args[-1]).touch()
                    if args[1] == 'import' and fail:
                        raise ValueError('fixture failure')
                    if args[1] == 'find-identity':
                        return f'1) {fingerprint} "Apple Distribution: Fixture"'.encode()
                    return b''

                with patch.dict(os.environ, environment, clear=True), patch.object(Path, 'home', return_value=root), patch.object(hosted, 'run', side_effect=security):
                    if fail:
                        with self.assertRaises(ValueError):
                            hosted.setup()
                    else:
                        hosted.setup()
                        self.assertEqual(len(list(root.rglob('*.mobileprovision'))), 6)
                        hosted.cleanup()
                    self.assertFalse((root / 'aegis-ios-signing').exists())
                    self.assertEqual(list(root.rglob('*.mobileprovision')), [])
