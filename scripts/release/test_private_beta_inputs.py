import base64
from email.message import Message
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import zipfile

spec = importlib.util.spec_from_file_location('private_beta', Path(__file__).with_name('private-beta-inputs.py'))
beta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(beta)

NODE = b'vless://fixture@192.0.2.1:443?security=reality&type=tcp'
QUOTA = json.dumps({'subscriptionInfoURL': 'https://example.invalid/sub/test?format=info',
                    'allowedTestClient': 'fixture', 'expectedQuotaBytes': 10000000000,
                    'trafficReset': 'daily'}).encode()


class PrivateBetaTests(unittest.TestCase):
    def quota_response(self, value=None):
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.geturl.return_value = json.loads(QUOTA)['subscriptionInfoURL']
        response.headers = Message()
        response.headers['Content-Type'] = 'application/json'
        response.read.return_value = json.dumps(value or {
            'sId': 'test', 'emails': ['fixture'], 'uploadByte': 123, 'downloadByte': 456,
            'totalByte': 10000000000, 'expire': 0, 'enabled': True}).encode()
        return response

    def test_live_quota_requires_identity_available_allowance_and_valid_transport(self):
        configuration = json.loads(QUOTA)
        valid = json.loads(self.quota_response().read.return_value)
        with patch.object(beta.urllib.request, 'build_opener') as factory:
            factory.return_value.open.return_value = self.quota_response()
            beta.check_live_quota(configuration)
            request = factory.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, configuration['subscriptionInfoURL'])
            self.assertEqual(request.get_header('User-agent'), 'Aegis-Alpha/1.0')
            self.assertEqual(factory.return_value.open.call_args.kwargs, {'timeout': 20})
            invalid = [dict(valid, **{key: value}) for key, value in (
                ('sId', 'other'), ('emails', ['fixture', 'other']), ('totalByte', 1),
                ('enabled', False), ('enabled', 1), ('uploadByte', -1),
                ('downloadByte', True), ('downloadByte', 1 << 64),
                ('downloadByte', 10000000000), ('expire', 1), ('expire', 253402300800))]
            for value in invalid:
                factory.return_value.open.return_value = self.quota_response(value)
                with self.subTest(value=value), self.assertRaises(ValueError):
                    beta.check_live_quota(configuration)
            for change in ('status', 'redirect', 'mime', 'oversized', 'malformed', 'array'):
                response = self.quota_response()
                if change == 'status': response.status = 403
                if change == 'redirect': response.geturl.return_value = 'https://other.invalid/'
                if change == 'mime': response.headers.replace_header('Content-Type', 'text/html')
                if change == 'oversized': response.read.return_value = b' ' * 65537
                if change == 'malformed': response.read.return_value = b'not json'
                if change == 'array': response.read.return_value = b'[]'
                factory.return_value.open.return_value = response
                with self.subTest(change=change), self.assertRaises(ValueError):
                    beta.check_live_quota(configuration)
            with self.assertRaises(ValueError):
                beta.check_live_quota(dict(configuration, subscriptionInfoURL='http://example.invalid/sub/test'))
        with self.assertRaises(ValueError):
            beta.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.invalid/')

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
                    with patch.object(beta.urllib.request, 'build_opener') as factory:
                        factory.return_value.open.return_value = self.quota_response()
                        beta.verify(directory, ipa, live_quota=True)
                        factory.return_value.open.assert_called_once()
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
