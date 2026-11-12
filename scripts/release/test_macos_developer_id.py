#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('macos_developer_id', Path(__file__).with_name('macos-developer-id.py'))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class DeveloperIdTests(unittest.TestCase):
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
