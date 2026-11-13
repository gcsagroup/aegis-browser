import base64
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('private_beta', Path(__file__).with_name('private-beta-inputs.py'))
beta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beta)

NODE = b'vless://fixture@192.0.2.1:443?security=reality&type=tcp'
QUOTA = json.dumps({'subscriptionInfoURL': 'https://example.invalid/sub/test?format=info',
                    'allowedTestClient': 'fixture', 'expectedQuotaBytes': 10000000000,
                    'trafficReset': 'daily'}).encode()


class PrivateBetaTests(unittest.TestCase):
    def environment(self):
        return {'AEGIS_IOS_TEST_NODE_BASE64': base64.b64encode(NODE).decode(),
                'AEGIS_IOS_TEST_SUBSCRIPTION_BASE64': base64.b64encode(QUOTA).decode()}

    def test_exact_export_is_required_and_inputs_are_private(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            beta.stage(directory, self.environment())
            for path in directory.iterdir():
                self.assertEqual(path.stat().st_mode & 0o077, 0)
            for change in ('none', 'missing', 'different', 'release'):
                ipa = directory / (change + '.ipa')
                with zipfile.ZipFile(ipa, 'w') as archive:
                    root = 'Payload/Aegis.app/'
                    archive.writestr(root + 'Info.plist', plistlib.dumps({
                        'AegisAccessReleaseChannel': 'beta',
                        'AegisReleaseProfile': 'release' if change == 'release' else 'beta'}))
                    archive.writestr(root + 'AegisPrivateTestNode.vless',
                                     b'wrong' if change == 'different' else NODE)
                    if change != 'missing':
                        archive.writestr(root + 'AegisPrivateTestSubscription.json',
                                         (directory / 'expected-subscription').read_bytes())
                if change == 'none':
                    beta.verify(directory, ipa)
                else:
                    with self.assertRaises((ValueError, KeyError)):
                        beta.verify(directory, ipa)

    def test_missing_partial_malformed_and_invalid_quota_fail_before_build(self):
        cases = [{}, {'AEGIS_IOS_TEST_NODE_BASE64': base64.b64encode(NODE).decode()},
                 dict(self.environment(), AEGIS_IOS_TEST_NODE_BASE64='!invalid!'),
                 dict(self.environment(), AEGIS_IOS_TEST_SUBSCRIPTION_BASE64=base64.b64encode(b'{}').decode()),
                 dict(self.environment(), AEGIS_IOS_TEST_NODE_BASE64='A' * 11001)]
        for environment in cases:
            with tempfile.TemporaryDirectory() as temp, self.assertRaises((ValueError, KeyError)):
                beta.stage(Path(temp), environment)

    def test_existing_input_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / 'node.vless').write_bytes(b'preserve')
            with self.assertRaises(FileExistsError):
                beta.stage(directory, self.environment())
            self.assertEqual((directory / 'node.vless').read_bytes(), b'preserve')


if __name__ == '__main__':
    unittest.main()
