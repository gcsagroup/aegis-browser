import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'apps/ios/scripts'))
import firebase_config as firebase


IDENTITIES = {
    'dev': {'project': 'aegis-dev-fixture', 'app': '1:123:ios:abc'},
    'prod': {'project': 'aegis-prod-fixture', 'app': '1:456:ios:def'},
}


def config(tier):
    target = IDENTITIES[tier]
    return plistlib.dumps({
        'BUNDLE_ID': 'com.gcsa.aegis',
        'PROJECT_ID': target['project'],
        'GOOGLE_APP_ID': target['app'],
        'GCM_SENDER_ID': target['app'].split(':')[1],
        'API_KEY': 'fixture-key',
        'IS_ANALYTICS_ENABLED': True,
    })


class FirebaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'identities.json').write_text(json.dumps(IDENTITIES))

    def test_channels_select_only_the_expected_registration(self):
        for channel, expected in [('dev', 'dev'), ('alpha', 'dev'), ('beta', 'dev'), ('release', 'prod')]:
            with self.subTest(channel=channel):
                self.assertEqual(firebase.environment(channel), expected)
                self.assertEqual(firebase.validate(config(expected), IDENTITIES, channel)['PROJECT_ID'],
                                 IDENTITIES[expected]['project'])
                with self.assertRaises(ValueError):
                    firebase.validate(config('prod' if expected == 'dev' else 'dev'), IDENTITIES, channel)
        with self.assertRaises(ValueError):
            firebase.environment('production')

    def test_a_single_project_cannot_be_registered_as_both_environments(self):
        with self.assertRaises(ValueError):
            firebase.validate(config('dev'), {'dev': IDENTITIES['dev'], 'prod': IDENTITIES['dev']}, 'beta')

    def test_bundle_sender_and_app_must_match(self):
        for field, value in [('BUNDLE_ID', 'other.app'), ('GCM_SENDER_ID', '456'),
                             ('GOOGLE_APP_ID', '1:123:ios:bad'), ('API_KEY', '')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                firebase.validate(plistlib.dumps({**plistlib.loads(config('dev')), field: value}), IDENTITIES, 'dev')

    def test_unconfigured_build_removes_stale_resource_and_signed_channel_rejects_missing_input(self):
        destination = self.root / firebase.RESOURCE
        destination.write_bytes(config('prod'))
        firebase.install(self.root, destination, 'disabled')
        self.assertFalse(destination.exists())
        firebase.install(self.root, destination, 'dev')
        self.assertFalse(destination.exists())
        with self.assertRaises(FileNotFoundError):
            firebase.install(self.root, destination, 'alpha')

    def test_stage_and_ipa_verification_bind_the_selected_bytes_and_reject_extra_config(self):
        with patch.dict(os.environ, {
            'AEGIS_IOS_FIREBASE_DEV_PLIST_BASE64': base64.b64encode(config('dev')).decode(),
        }, clear=True):
            firebase.stage(self.root, 'beta')
        source = self.root / 'dev' / 'GoogleService-Info.plist'
        self.assertEqual(source.read_bytes(), config('dev'))
        self.assertFalse((self.root / 'prod').exists())

        ipa = self.root / 'candidate.ipa'
        app_root = 'Payload/Aegis.app/'
        with zipfile.ZipFile(ipa, 'w') as bundle:
            bundle.writestr(app_root + 'Info.plist', plistlib.dumps({
                'CFBundleIdentifier': 'com.gcsa.aegis', 'AegisReleaseProfile': 'beta',
                'AegisFirebaseChannel': 'beta',
            }))
            bundle.writestr(app_root + firebase.RESOURCE, config('dev'))
        firebase.verify_ipa(self.root, ipa, 'beta')
        prod = self.root / 'prod' / 'GoogleService-Info.plist'
        prod.parent.mkdir()
        prod.write_bytes(config('prod'))
        with self.assertRaisesRegex(ValueError, 'channel mismatch'):
            firebase.verify_ipa(self.root, ipa, 'release')
        with zipfile.ZipFile(ipa, 'a') as bundle:
            bundle.writestr(app_root + 'PlugIns/ShareExtension.appex/' + firebase.RESOURCE, config('prod'))
        with self.assertRaises(ValueError):
            firebase.verify_ipa(self.root, ipa, 'beta')


if __name__ == '__main__':
    unittest.main()
