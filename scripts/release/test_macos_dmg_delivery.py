#!/usr/bin/env python3
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('macos_dmg_delivery', Path(__file__).with_name('macos-dmg-delivery.py'))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)
package_spec = importlib.util.spec_from_file_location('macos_dmg', Path(__file__).with_name('macos-dmg.py'))
packager = importlib.util.module_from_spec(package_spec)
package_spec.loader.exec_module(packager)

SHA = 'a' * 40
REPOSITORY = 'gcsagroup/aegis-browser'


def environment(**changes):
    value = {
        'AEGIS_MACOS_DELIVERY_ENABLED': 'true',
        'GITHUB_REPOSITORY': REPOSITORY,
        'GITHUB_EVENT_NAME': 'workflow_dispatch',
        'GITHUB_REF': 'refs/heads/main',
        'GITHUB_SHA': SHA,
        'GITHUB_RUN_ATTEMPT': '1',
        'AEGIS_IOS_RUNNER_LABEL': 'aegis-ios-fork-migration',
    }
    value.update(changes)
    return value


def inputs(**changes):
    value = {
        'operation': 'Package',
        'version': '0.8.0',
        'build': '800001',
        'package_kind': 'ad-hoc',
        'signing_mode': 'ad-hoc',
        'approved_source_sha': SHA,
        'tag_release': 'no',
        'bot_callback': 'yes',
    }
    value.update(changes)
    return value


def write_package(root, version='0.8.0', package_kind='ad-hoc', body=b'arm64-dmg', receipt_digest=None):
    root.mkdir()
    filename = f'GCSA-aegis-{version}-mac-arm64.dmg'
    (root / filename).write_bytes(body)
    digest = hashlib.sha256(body).hexdigest() if receipt_digest is None else receipt_digest
    signing = 'developer-id' if package_kind in {'host-signed', 'notarized'} else 'ad-hoc'
    receipt = {'notarized': False, 'signingMode': signing, 'version': version, 'arch': 'arm64',
               'sourceSha': SHA, 'packagingSourceSha': SHA, 'notarizationSigning': package_kind == 'notarized',
               'dmg': {'name': filename, 'sha256': digest}}
    (root / 'macos-delivery-receipt.json').write_text(json.dumps(receipt), encoding='utf-8')
    return hashlib.sha256(body).hexdigest()


class PlanTests(unittest.TestCase):
    def test_plan_admits_one_arm64_dmg_and_aliases_unsigned(self):
        planned = delivery.plan(environment(), inputs(package_kind='unsigned-dmg', signing_mode='none', tag_release='yes'))
        self.assertEqual(planned['package_kind'], 'ad-hoc')
        self.assertEqual(planned['signing_mode'], 'ad-hoc')
        self.assertEqual(planned['upload'], 'false')
        self.assertEqual(planned['tag_release'], 'true')
        self.assertEqual(planned['architectures'], 'arm64')
        self.assertEqual(json.loads(planned['runner']), ['self-hosted', 'macOS', 'ARM64', 'aegis-ios-fork-migration'])

    def test_fork_admits_the_full_matrix_before_upstream_promotion(self):
        planned = delivery.plan(environment(GITHUB_REPOSITORY='quinn521/aegis-browser'), inputs(package_kind='host-signed', signing_mode='host-signed'))
        self.assertEqual(planned['repository'], 'quinn521/aegis-browser')
        self.assertEqual(planned['package_kind'], 'host-signed')
        with self.assertRaises(delivery.DeliveryError):
            delivery.promote_candidate(lambda *a, **k: None, 'candidate/macos/0.8.0-notarized.800001', 'quinn', True,
                                       repository='quinn521/aegis-browser')

    def test_macos_runner_label_wins_and_the_gate_must_be_exactly_true(self):
        planned = delivery.plan(environment(AEGIS_MACOS_RUNNER_LABEL='aegis-mac-1'), inputs(package_kind='notarized', signing_mode='notarized'))
        self.assertIn('aegis-mac-1', planned['runner'])
        with self.assertRaises(delivery.DeliveryError):
            delivery.plan(environment(AEGIS_MACOS_DELIVERY_ENABLED='yes'), inputs())
        with self.assertRaises(delivery.DeliveryError):
            delivery.plan(environment(), inputs(package_kind='host-signed', signing_mode='ad-hoc'))
        with self.assertRaises(delivery.DeliveryError):
            delivery.plan(environment(), inputs(approved_source_sha='b' * 40))
        with self.assertRaises(delivery.DeliveryError):
            delivery.plan(environment(), inputs(operation='Package and upload'))


class SealTests(unittest.TestCase):
    def test_seal_rejects_wrong_source_and_missing_distribution_signing(self):
        for changes in ({'sourceSha': 'b' * 40}, {'packagingSourceSha': 'b' * 40}, {'notarizationSigning': False}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / 'package'
                write_package(root, package_kind='notarized')
                path = root / 'macos-delivery-receipt.json'
                path.write_text(json.dumps(dict(json.loads(path.read_text()), **changes)))
                with self.assertRaises(delivery.DeliveryError):
                    delivery.seal(root, 'notarized', '0.8.0', '800001', SHA, REPOSITORY)
                self.assertFalse((root / 'macos-delivery-manifest.json').exists())

    def test_real_packager_output_can_be_sealed_without_weakening_directory_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / 'apps/GCSA-aegis.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_text('fixture')
            (app.parent / '.aegis').mkdir()
            output = root / 'output'

            def runner(command):
                if command[0].endswith('hdiutil'):
                    stage = Path(command[command.index('-srcfolder') + 1])
                    self.assertTrue((stage / app.name).is_dir())
                    Path(command[-1]).write_bytes(b'packaged-dmg')

            env = environment(MACOS_VERSION='0.8.0', MACOS_SIGNING_MODE='ad-hoc',
                              MACOS_APP_PATH=str(app), AEGIS_MACOS_APP_ROOT=str(app.parent),
                              MACOS_OUTPUT_DIR=str(output))
            with patch.object(packager, 'verify_app_identity', return_value={'source': {'root': {'sha': SHA}}}):
                packager.package(env, runner)
            self.assertTrue((app / 'Contents/Info.plist').is_file())
            self.assertEqual(sorted(p.name for p in output.iterdir()),
                             ['GCSA-aegis-0.8.0-mac-arm64.dmg', 'macos-delivery-receipt.json'])
            manifest = delivery.seal(output, 'ad-hoc', '0.8.0', '800001', SHA, REPOSITORY)
            self.assertEqual(manifest['artifacts'][0]['sha256'], hashlib.sha256(b'packaged-dmg').hexdigest())

    def test_seal_records_the_file_digest_and_keeps_the_low_level_receipt_unnotarized(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'out'
            digest = write_package(root, package_kind='notarized', body=b'stapled', receipt_digest='b' * 64)
            manifest = delivery.seal(root, 'notarized', '0.8.0', '800001', SHA, REPOSITORY)
            self.assertTrue(manifest['notarized'])
            self.assertFalse(manifest['artifacts'][0]['uploadable'])
            self.assertEqual(manifest['artifacts'][0]['sha256'], digest)
            with self.assertRaises(delivery.DeliveryError):
                delivery.seal(root, 'notarized', '0.8.0', '800001', SHA, REPOSITORY)

    def test_ad_hoc_seal_rejects_a_host_signed_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'out'
            write_package(root, package_kind='host-signed')
            with self.assertRaises(delivery.DeliveryError):
                delivery.seal(root, 'ad-hoc', '0.8.0', '800001', SHA, REPOSITORY)


class TagTests(unittest.TestCase):
    def artifact(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name) / 'out'
        digest = write_package(root, package_kind='notarized', body=b'stapled', receipt_digest='b' * 64)
        manifest = delivery.seal(root, 'notarized', '0.8.0', '800001', SHA, REPOSITORY)
        raw = (root / 'macos-delivery-manifest.json').read_bytes()
        planned = delivery.plan_dmg_tag(manifest, hashlib.sha256(raw).hexdigest(), SHA)
        self.assertEqual(planned['tag'], 'candidate/macos/0.8.0-notarized.800001')
        self.assertTrue(planned['prerelease'])
        self.assertEqual(planned['makeLatest'], 'false')
        return planned, root / 'GCSA-aegis-0.8.0-mac-arm64.dmg', digest

    def test_candidate_release_uploads_the_one_dmg_and_does_not_replace_a_tag(self):
        planned, dmg, digest = self.artifact()
        calls = []

        def api(path, method='GET', body=None, data=None, content_type=None):
            calls.append((method, path, body, data, content_type))
            if method == 'GET':
                raise delivery.DeliveryStatus(404)
            if path.endswith('/git/tags'):
                return {'sha': 'c' * 40}
            if path.endswith('/releases'):
                return {'id': 9, 'prerelease': True, 'draft': False,
                        'upload_url': 'https://uploads.github.com/repos/' + REPOSITORY + '/releases/9/assets{?name,label}'}
            if path.startswith('https://uploads.github.com/'):
                self.assertEqual(hashlib.sha256(data).hexdigest(), digest)
                self.assertEqual(content_type, 'application/octet-stream')
                return {'id': 11, 'name': dmg.name, 'state': 'uploaded'}
            return {}

        created = delivery.create_dmg_tag_release(api, planned, dmg)
        self.assertEqual(created['releaseId'], 9)
        self.assertEqual(created['assetId'], 11)
        self.assertTrue(any(path.startswith('https://uploads.github.com/') for _method, path, _body, _data, _type in calls))
        self.assertFalse(any(path.startswith('/repos/') and path.endswith('/assets') for _method, path, _body, _data, _type in calls))

        def present(path, method='GET', body=None, data=None, content_type=None):
            return {'ref': path}

        with self.assertRaises(delivery.DeliveryError):
            delivery.create_dmg_tag_release(present, planned, dmg)
        self.assertEqual([method for method, *_rest in calls if method == 'POST'], ['POST', 'POST', 'POST', 'POST'])

    def test_promote_accepts_only_an_approved_notarized_candidate(self):
        planned, _dmg, digest = self.artifact()
        stable = []
        asset = {'id': 71, 'name': _dmg.name, 'state': 'uploaded', 'size': _dmg.stat().st_size,
                 'digest': 'sha256:' + digest}

        def api(path, method='GET', body=None, data=None, content_type=None):
            stable.append((method, path, body))
            if path.endswith('/permission'):
                return {'permission': 'admin'}
            if path.endswith('/git/ref/tags/candidate/macos/0.8.0-ad-hoc.800001'):
                return {'object': {'type': 'tag', 'sha': 'e' * 40}}
            if path.endswith('/git/tags/' + 'e' * 40):
                return {'message': planned['message'].replace('"packageKind":"notarized"', '"packageKind":"ad-hoc"'),
                        'object': {'type': 'commit', 'sha': SHA}}
            if '/git/ref/tags/candidate/' in path:
                return {'object': {'type': 'tag', 'sha': 'd' * 40}}
            if path.endswith('/git/tags/' + 'd' * 40):
                return {'message': planned['message'], 'object': {'type': 'commit', 'sha': SHA}}
            if path.endswith('/git/ref/tags/v0.8.0'):
                raise delivery.DeliveryStatus(404)
            if '/releases/tags/' in path:
                return {'id': 12, 'tag_name': planned['tag'], 'prerelease': True, 'draft': False, 'assets': [asset]}
            if path.endswith('/git/refs') and method == 'POST':
                self.assertEqual(body, {'ref': 'refs/tags/v0.8.0', 'sha': SHA})
                return {'ref': body['ref']}
            if path.endswith('/releases/12') and method == 'PATCH':
                return {'id': 12, 'tag_name': 'v0.8.0', 'prerelease': False, 'draft': False, 'assets': [asset]}
            raise AssertionError(path)

        promoted = delivery.promote_candidate(api, planned['tag'], 'quinn', True)
        self.assertEqual(promoted['tag'], 'v0.8.0')
        self.assertFalse(promoted['prerelease'])
        self.assertEqual(promoted['assetId'], 71)
        self.assertFalse(any(method == 'POST' and path.endswith('/releases') for method, path, _ in stable))
        self.assertEqual(stable[-1][0], 'PATCH')
        self.assertEqual(stable[-1][2]['make_latest'], 'true')
        with self.assertRaises(delivery.DeliveryError):
            delivery.promote_candidate(api, 'candidate/macos/0.8.0-ad-hoc.800001', 'quinn', True)
        with self.assertRaises(delivery.DeliveryError):
            delivery.promote_candidate(api, planned['tag'], 'quinn', False)

        for change in [{'digest': 'sha256:' + '0' * 64}, {'state': 'new'}, {'size': 0}, {'name': 'wrong.dmg'}]:
            with self.subTest(change=change):
                original = dict(asset)
                asset.update(change)
                stable.clear()
                with self.assertRaises(delivery.DeliveryError):
                    delivery.promote_candidate(api, planned['tag'], 'quinn', True)
                self.assertTrue(all(method == 'GET' for method, _path, _body in stable))
                asset.clear()
                asset.update(original)

    def test_accept_complete_records_one_package_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'receipt.json'
            receipt = delivery.accept_complete({
                'AEGIS_IOS_DELIVERY_BOT': json.dumps({'actorId': 50, 'appId': 40, 'slug': 'aegis-delivery'}),
                'GITHUB_REPOSITORY': REPOSITORY,
                'GITHUB_REF': 'refs/heads/main',
                'GITHUB_ACTOR': 'aegis-delivery[bot]',
                'GITHUB_ACTOR_ID': '50',
                'AEGIS_MACOS_INPUT_COMPLETED_OPERATION': 'package',
                'AEGIS_MACOS_INPUT_VERSION': '0.8.0',
                'AEGIS_MACOS_INPUT_BUILD': '800001',
                'AEGIS_MACOS_INPUT_APPROVED_SOURCE_SHA': SHA,
                'AEGIS_MACOS_INPUT_PARENT_RUN_ID': '88',
                'AEGIS_MACOS_INPUT_MANIFEST_SHA256': 'e' * 64,
                'AEGIS_MACOS_INPUT_PACKAGE_KIND': 'notarized',
                'AEGIS_MACOS_INPUT_SIGNING_MODE': 'notarized',
                'AEGIS_MACOS_INPUT_CANDIDATE_TAG': 'candidate/macos/0.8.0-notarized.800001',
            }, destination)
            self.assertEqual(receipt['operation'], 'package')
            self.assertEqual(receipt['parentRunId'], 88)
            self.assertEqual(receipt['candidateTag'], 'candidate/macos/0.8.0-notarized.800001')
            with self.assertRaises(delivery.DeliveryError):
                delivery.accept_complete({
                    **{
                        'AEGIS_IOS_DELIVERY_BOT': json.dumps({'actorId': 50, 'appId': 40, 'slug': 'aegis-delivery'}),
                        'GITHUB_REPOSITORY': REPOSITORY,
                        'GITHUB_REF': 'refs/heads/main',
                        'GITHUB_ACTOR': 'aegis-delivery[bot]',
                        'GITHUB_ACTOR_ID': '50',
                    },
                    'AEGIS_MACOS_INPUT_COMPLETED_OPERATION': 'package-upload',
                    'AEGIS_MACOS_INPUT_VERSION': '0.8.0',
                    'AEGIS_MACOS_INPUT_BUILD': '800001',
                    'AEGIS_MACOS_INPUT_APPROVED_SOURCE_SHA': SHA,
                    'AEGIS_MACOS_INPUT_PARENT_RUN_ID': '88',
                    'AEGIS_MACOS_INPUT_MANIFEST_SHA256': 'e' * 64,
                }, Path(directory) / 'other.json')


if __name__ == '__main__':
    unittest.main()
