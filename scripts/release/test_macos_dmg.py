#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

import importlib.util
spec = importlib.util.spec_from_file_location('macos_dmg', Path(__file__).with_name('macos-dmg.py'))
dmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dmg)

SHA = 'a' * 40


def environment(**extra):
    base = {
        'GITHUB_REPOSITORY': 'quinn521/aegis-browser',
        'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'MACOS_OPERATION': 'access',
        'MACOS_VERSION': '6.1.0.266',
        'MACOS_SIGNING_MODE': 'ad-hoc',
        'AEGIS_IOS_RUNNER_LABEL': 'aegis-ios-upstream-migration',
        'MACOS_ARCH': 'arm64',
        'GITHUB_SHA': SHA,
    }
    base.update(extra)
    return base


class MacosDmgTests(unittest.TestCase):
    def test_access_plan_reuses_existing_self_hosted_label_and_skips_dmg(self):
        plan = dmg.normalize(environment())
        self.assertEqual(plan['operation'], 'access')
        self.assertEqual(plan['dmg_name'], '')
        self.assertEqual(json.loads(plan['runner']),
                         ['self-hosted', 'macOS', 'ARM64', 'aegis-ios-upstream-migration'])
        self.assertNotIn('macos-26', plan['runner'])

    def test_dedicated_mac_label_wins_without_falling_back_to_github_hosted(self):
        plan = dmg.normalize(environment(AEGIS_MACOS_RUNNER_LABEL='aegis-mac-arm64'))
        self.assertEqual(plan['runner_label'], 'aegis-mac-arm64')

    def test_refuses_notarization_and_missing_runner(self):
        with self.assertRaises(dmg.DeliveryError):
            dmg.normalize(environment(MACOS_NOTARIZE='true'))
        with self.assertRaises(dmg.DeliveryError):
            dmg.normalize(environment(AEGIS_IOS_RUNNER_LABEL='', AEGIS_MACOS_RUNNER_LABEL=''))

    def test_package_signs_inside_out_without_deep_or_notary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'apps'
            app = root / 'GCSA-aegis.app'
            helper = app / 'Contents' / 'Frameworks' / 'Helper.app'
            helper.mkdir(parents=True)
            (app / 'Contents' / 'Info.plist').write_text('plist')
            (helper / 'Info.plist').write_text('helper')
            commands = dmg.sign_plan(app, '-')
            signed = [Path(command[-1]) for command in commands if command[1] == '--force']
            self.assertEqual(signed, [helper, app])
            self.assertTrue(all('--deep' not in command and 'notarytool' not in command for command in commands))
            output = Path(temporary) / 'out'
            calls = []

            def runner(command):
                calls.append(command)
                if command[0].endswith('hdiutil'):
                    Path(command[-1]).write_bytes(b'dmg-bytes')

            receipt = dmg.package(environment(
                MACOS_OPERATION='package',
                MACOS_APP_PATH=str(app),
                AEGIS_MACOS_APP_ROOT=str(root),
                MACOS_OUTPUT_DIR=str(output),
                MACOS_ACTUAL_ARCH='arm64',
            ), runner=runner)
            self.assertFalse(receipt['notarized'])
            self.assertEqual(receipt['notarization'], 'skipped')
            self.assertEqual(receipt['dmg']['sha256'], hashlib.sha256(b'dmg-bytes').hexdigest())
            self.assertTrue(any(command[0].endswith('codesign') for command in calls))

    def test_package_plan_accepts_a_remote_app_path_and_fork_ad_hoc_mode(self):
        plan = dmg.normalize(environment(
            MACOS_OPERATION='package',
            MACOS_SIGNING_MODE='',
            AEGIS_MACOS_REHEARSAL_SIGNING_MODE='temporary-ad-hoc',
            MACOS_APP_PATH='/opt/aegis-apps/GCSA-aegis.app',
            AEGIS_MACOS_APP_ROOT='/opt/aegis-apps',
        ))
        self.assertEqual(plan['signing_mode'], 'ad-hoc')
        self.assertEqual(plan['dmg_name'], 'GCSA-aegis-6.1.0.266-mac-arm64.dmg')
        self.assertFalse(Path('/opt/aegis-apps/GCSA-aegis.app').exists())

    def test_package_rejects_architecture_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'apps'
            app = root / 'GCSA-aegis.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents' / 'Info.plist').write_text('plist')
            with self.assertRaises(dmg.DeliveryError):
                dmg.package(environment(
                    MACOS_OPERATION='package',
                    MACOS_APP_PATH=str(app),
                    AEGIS_MACOS_APP_ROOT=str(root),
                    MACOS_OUTPUT_DIR=str(Path(temporary) / 'out'),
                    MACOS_ACTUAL_ARCH='x86_64',
                ), runner=lambda command: None)


class WorkflowContractTests(unittest.TestCase):
    def test_delivery_workflow_keeps_self_hosted_runner_and_access_tests(self):
        text = Path('.github/workflows/macos-delivery.yml').read_text()
        self.assertNotIn('macos-26', text)
        self.assertNotIn('notarytool', text)
        self.assertIn('macos-access-tests.sh', text)
        self.assertIn('AEGIS_IOS_RUNNER_LABEL', text)
        self.assertNotIn('secrets: inherit', text)
        ios = Path('.github/workflows/ios-delivery.yml').read_text()
        self.assertIn('AEGIS_IOS_RUNNER_LABEL', ios)
        self.assertNotIn('macos-26', ios)
        fork_ios = Path('.github/workflows/ios-fork-access.yml').read_text()
        self.assertIn('AEGIS_IOS_RUNNER_LABEL', fork_ios)
        self.assertNotIn('macos-26', fork_ios)
        self.assertNotIn('DISTRIBUTION_P12', fork_ios)
        self.assertIn('ios-access-tests.sh', fork_ios)


if __name__ == '__main__':
    unittest.main()
