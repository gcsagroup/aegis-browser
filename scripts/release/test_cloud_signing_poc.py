"""Cloud PoC boundaries and identity checks; actual cloud signing needs Apple access."""
import datetime
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


poc = load('cloud_poc', 'cloud-signing-poc.py')
verifier = load('cloud_verifier', 'verify-signed-ios.py')


class CloudSigningTests(unittest.TestCase):
    def test_export_is_artifact_only_and_disables_version_mutation(self):
        value = poc.export_options('ABCDEFGHIJ')
        self.assertEqual(value['destination'], 'export')
        self.assertEqual(value['signingStyle'], 'automatic')
        self.assertIs(value['manageAppVersionAndBuildNumber'], False)
        self.assertNotIn('provisioningProfiles', value)

    def test_poc_does_not_accept_an_upload_destination_or_implicit_mode(self):
        with patch('sys.argv', ['poc', '--destination', 'app-store']), self.assertRaises(SystemExit):
            poc.main()

    def test_rejects_shell_metacharacters_in_native_identity(self):
        for values in [('1.0.1;echo', '16', 'ABCDEFGHIJ'), ('1.0.1', '0', 'ABCDEFGHIJ'),
                       ('1.0.1', '16', 'wrong')]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                poc.validate_identity(*values)

    def test_keychain_state_restored_on_archive_or_export_failure(self):
        for failure in ('archive', 'export', None):
            calls = []
            evidence = {}
            original = ['/original/keychain-db']
            with tempfile.TemporaryDirectory() as directory:
                def security(*args, **_kwargs):
                    calls.append(args)
                    if args[1] == 'default-keychain' and '-s' not in args:
                        return b'"/original/default-db"\n'
                    return b''
                with patch.object(poc, 'run', side_effect=security), patch.object(poc, 'keychains', return_value=original):
                    try:
                        with poc.isolated_keychain(Path(directory), evidence):
                            if failure:
                                raise RuntimeError(failure)
                    except RuntimeError:
                        pass
                self.assertTrue(evidence['keychainRestored'])
                self.assertFalse(evidence['distributionP12Imported'])
                self.assertIn(('security', 'list-keychains', '-d', 'user', '-s', *original), calls)
                self.assertIn(('security', 'default-keychain', '-d', 'user', '-s', '/original/default-db'), calls)
                self.assertFalse(any(c[1] == 'import' for c in calls))

    def test_rejects_local_distribution_identity(self):
        for kind in ('Apple Distribution', 'iPhone Distribution', 'Developer ID Application'):
            with patch.object(poc, 'run', return_value=f'1) ABC "{kind}: Team"'.encode()), self.assertRaises(ValueError):
                poc.no_distribution_identity()

    def profile(self):
        entitlements = {'application-identifier': 'ABCDEFGHIJ.com.gcsa.aegis',
                        'com.apple.developer.team-identifier': 'ABCDEFGHIJ', 'get-task-allow': False,
                        'com.apple.security.application-groups': ['group.com.gcsa.aegis.ios.share-inbox']}
        profile = {'Name': 'Rotated managed profile', 'UUID': 'ABCD1234-1234-1234-1234-123456789ABC',
                   'TeamIdentifier': ['ABCDEFGHIJ'], 'ExpirationDate': datetime.datetime.utcnow() + datetime.timedelta(days=1),
                   'DeveloperCertificates': [b'new certificate'], 'Entitlements': entitlements}
        return profile, dict(entitlements), hashlib.sha1(b'new certificate').hexdigest().upper()

    def test_cloud_accepts_rotated_certificate_bound_to_actual_profile(self):
        profile, signed, fingerprint = self.profile()
        verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint)

    def test_cloud_rejects_device_enterprise_expired_and_wrong_team_profiles(self):
        for change in ({'ProvisionedDevices': ['phone']}, {'ProvisionsAllDevices': True},
                       {'ExpirationDate': datetime.datetime(2000, 1, 1)}, {'TeamIdentifier': ['OTHERTEAM1']},
                       {'DeveloperCertificates': [b'wrong certificate']}, {'UUID': '../../escape'}):
            profile, signed, fingerprint = self.profile()
            profile.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint)

    def test_cloud_checks_signed_entitlements_in_addition_to_embedded_profile(self):
        for key, value in [('get-task-allow', True), ('get-task-allow', 0),
                           ('application-identifier', 'ABCDEFGHIJ.other'),
                           ('com.apple.security.application-groups', ['wrong'])]:
            profile, signed, fingerprint = self.profile()
            signed[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                verifier.validate_cloud_profile(profile, signed, 'com.gcsa.aegis', 'ABCDEFGHIJ', fingerprint)


if __name__ == '__main__':
    unittest.main()
