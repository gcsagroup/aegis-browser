#!/usr/bin/env python3
import importlib.util
import base64
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('macos_developer_id', Path(__file__).with_name('macos-developer-id.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class DeveloperIdTests(unittest.TestCase):
    def test_keychain_unlock_lifetime_covers_the_admitted_build_and_cleanup_stays_local(self):
        for seconds in ('3600', '21600', '24000'):
            with self.subTest(seconds=seconds), tempfile.TemporaryDirectory() as directory:
                root = Path(directory).resolve()
                env = {'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'RUNNER_OS': 'macOS',
                       'RUNNER_TEMP': str(root), 'AEGIS_MACOS_SIGNING_KEYCHAIN_TIMEOUT_SECONDS': seconds,
                       'AEGIS_MACOS_DEVELOPER_ID_P12_BASE64': base64.b64encode(b'\x30\x82fixture').decode(),
                       'AEGIS_MACOS_DEVELOPER_ID_P12_PASSWORD': 'fixture-password'}
                calls = []

                def runner(args):
                    calls.append(args)
                    if args[1] == 'create-keychain':
                        Path(args[-1]).touch()
                    if args[1] == 'delete-keychain':
                        Path(args[-1]).unlink()
                    if args[1] == 'find-identity':
                        return b'1) ABC "Developer ID Application: GCSA (R3JK7R29AC)"\n'
                    return b''

                signing.setup(env, runner)
                settings = next(args for args in calls if args[1] == 'set-keychain-settings')
                self.assertEqual(settings[2:4], ['-lut', seconds])
                self.assertFalse(any('list-keychains' in args for args in calls))
                self.assertFalse((root / 'aegis-macos-developer-id/developer-id.p12').exists())
                signing.cleanup(env, runner)
                self.assertFalse((root / 'aegis-macos-developer-id').exists())
                for invalid in ('0', '3599', '24001', 'infinite'):
                    env['AEGIS_MACOS_SIGNING_KEYCHAIN_TIMEOUT_SECONDS'] = invalid
                    with self.assertRaisesRegex(signing.SigningError, 'timeout'):
                        signing.setup(env, runner)
                    self.assertFalse((root / 'aegis-macos-developer-id').exists())

    def test_host_must_be_self_hosted_macos_actions(self):
        signing.check_host({'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'self-hosted', 'RUNNER_OS': 'macOS'})
        with self.assertRaises(signing.SigningError):
            signing.check_host({'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'RUNNER_OS': 'macOS'})

    def test_exactly_one_developer_id_for_the_team(self):
        text = '1) ABC "Developer ID Application: GCSA (R3JK7R29AC)"\n'
        self.assertIn('R3JK7R29AC', signing.identity_from_find_output(text, 'R3JK7R29AC'))
        with self.assertRaises(signing.SigningError):
            signing.identity_from_find_output(text + text, 'R3JK7R29AC')
        with self.assertRaises(signing.SigningError):
            signing.identity_from_find_output(text, 'AAAAAAAAAA')

    def test_rejects_non_pkcs12_payload(self):
        with self.assertRaises(signing.SigningError):
            signing.decode_p12('bm90LWEjZXJ0')


if __name__ == '__main__':
    unittest.main()
