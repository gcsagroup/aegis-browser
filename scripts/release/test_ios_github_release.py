import hashlib
import importlib.util
import json
import copy
from datetime import datetime, timezone, timedelta
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    'ios_github_release', Path(__file__).with_name('ios-github-release.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)

SHA = 'a' * 40
TREE = 'b' * 40
MANIFEST_SHA = 'c' * 64
PACKAGE_RUN = 44204667020
STATUS_RUN = 44207029721


def run(run_id, path, jobs):
    return {
        'id': run_id, 'run_attempt': 1, 'head_sha': SHA, 'head_branch': 'main',
        'status': 'completed', 'conclusion': 'success', 'event': 'workflow_dispatch',
        'path': path, 'repository': {'id': 1348409663, 'full_name': 'gcsagroup/aegis-browser'},
        'head_repository': {'id': 1348409663, 'full_name': 'gcsagroup/aegis-browser'},
        'jobs': jobs,
    }


def job(name, run_id):
    return {'id': run_id + 10, 'name': name, 'run_id': run_id, 'run_attempt': 1,
            'head_sha': SHA, 'status': 'completed', 'conclusion': 'success'}


def valid_evidence(profile='beta', version='1.1.0', build='8'):
    upload_intent = {'operation': 'apple-upload', 'platform': 'ios',
                     'applicationId': 'com.gcsa.aegis', 'version': version, 'build': build,
                     'profile': profile, 'format': 'ipa', 'manifestSha256': MANIFEST_SHA, 'parameters': {}}
    manifest = {
        'repository': 'gcsagroup/aegis-browser', 'platform': 'ios', 'applicationId': 'com.gcsa.aegis',
        'profile': profile, 'version': version, 'build': build,
        'source': {'sha': SHA, 'tree': TREE, 'dirty': False},
        'details': {'signingMode': 'manual'},
        'assets': [
            {'name': f'Aegis-{profile}-{version}-{build}-ios.ipa', 'size': 40, 'sha256': '1' * 64},
            {'name': f'Aegis-{profile}-{version}-{build}-ios.app.dSYM.zip', 'size': 50, 'sha256': '2' * 64},
        ],
    }
    package = {
        'origin': {'repository': 'gcsagroup/aegis-browser', 'runId': PACKAGE_RUN, 'attempt': 1,
                   'sourceSha': SHA, 'sourceTree': TREE, 'manifestSha256': MANIFEST_SHA,
                   'runIdLocal': f'ios-gh-{PACKAGE_RUN}-1'},
        'package_job_id': PACKAGE_RUN + 10, 'artifact_id': 3101,
        'artifact_digest': 'sha256:' + '3' * 64,
        'artifact_name': f'ios-package-{PACKAGE_RUN}-1',
        'version': version, 'build': build, 'profile': profile,
    }
    status = {
        'platform': 'ios', 'applicationId': 'com.gcsa.aegis', 'version': version, 'build': build,
        'queryMode': 'release-wait', 'readOnly': True, 'packageProvenanceVerified': False,
        'querySource': {'sha': SHA, 'tree': TREE, 'dirty': False},
        'remote': {'appId': '6827988433', 'buildIdentitySha256': '8' * 64,
                   'processingState': 'VALID', 'expired': False, 'uploadState': 'COMPLETE',
                   'observedAt': datetime.now(timezone.utc).isoformat()},
    }
    return {
        'repository': {'id': 1348409663, 'full_name': 'gcsagroup/aegis-browser', 'default_branch': 'main'},
        'current_sha': SHA, 'current_tree': TREE, 'requested_profile': profile,
        'version': version, 'build': build,
        'package_run': run(PACKAGE_RUN, '.github/workflows/ios-delivery.yml',
                           [job('ios-package', PACKAGE_RUN), job('seal-package', PACKAGE_RUN), job('upload-new', PACKAGE_RUN)]),
        'package_record': package,
        'package_artifact': {'id': 3101, 'name': package['artifact_name'],
                             'digest': package['artifact_digest'], 'expired': False},
        'manifest_sha256': MANIFEST_SHA,
        'upload_start': upload_intent,
        'upload_result': {'intent': upload_intent, 'result': {'status': 'uploaded_processing_unverified', 'appId': '6827988433'}},
        'manifest': manifest,
        'status_run': run(STATUS_RUN, '.github/workflows/ios-delivery.yml', [job('status-query', STATUS_RUN)]),
        'status_artifact': {'id': 4101, 'name': f'ios-release-status-{STATUS_RUN}-1', 'expired': False,
                            'digest': 'sha256:' + '4' * 64, 'run_id': STATUS_RUN},
        'status': status,
    }


class CandidateEvidenceTests(unittest.TestCase):
    def test_repository_root_has_no_trailing_slash(self):
        result = subprocess.CompletedProcess([], 0, '{}', '')
        with patch.object(release.subprocess, 'run', return_value=result) as command:
            release._api('')
        self.assertEqual(command.call_args.args[0][-1], 'repos/gcsagroup/aegis-browser')

    def test_only_build_8_preview_accepts_a_verified_historical_producer(self):
        evidence = valid_evidence()
        main = '9' * 40
        evidence.update(current_sha=main, current_tree='8' * 40)
        evidence['status_run']['head_sha'] = main
        evidence['status_run']['jobs'][0]['head_sha'] = main
        evidence['status']['querySource'].update(sha=main, tree='8' * 40)
        relation = {'merge_base_commit': {'sha': SHA},
                    'base_commit': {'commit': {'tree': {'sha': TREE}}}}
        with patch.object(release, '_api', return_value=relation) as api:
            candidate = release.validate_delivery_evidence(evidence, 'beta', preview=True)
            self.assertEqual(candidate['source'], {'sha': SHA, 'tree': TREE})
            api.assert_called_once_with(f'compare/{SHA}...{main}')
        with self.assertRaisesRegex(ValueError, 'no longer current main'):
            release.validate_delivery_evidence(evidence, 'beta')
        with patch.object(release, '_api', return_value={}):
            with self.assertRaisesRegex(ValueError, 'not an ancestor'):
                release.validate_delivery_evidence(evidence, 'beta', preview=True)

    def test_full_combined_upload_accepts_only_its_qualified_successful_jobs(self):
        evidence = valid_evidence('beta', '1.2.0', '9')
        producer = evidence['package_run']
        producer['path'] = '.github/workflows/ios-delivery-full.yml'
        for item in producer['jobs']:
            item['name'] = 'delivery / ' + item['name']
        self.assertEqual(release.validate_delivery_evidence(evidence, 'beta')['packageRunId'], PACKAGE_RUN)
        producer['jobs'][-1]['conclusion'] = 'skipped'
        with self.assertRaisesRegex(ValueError, 'upload-new'):
            release.validate_delivery_evidence(evidence, 'beta')

    def test_valid_uploaded_package_and_apple_build_bind_to_one_source(self):
        candidate = release.validate_delivery_evidence(valid_evidence(), 'beta')

        self.assertEqual((candidate['profile'], candidate['version'], candidate['build']), ('beta', '1.1.0', '8'))
        self.assertEqual(candidate['source'], {'sha': SHA, 'tree': TREE})
        self.assertEqual(candidate['packageRunId'], PACKAGE_RUN)
        self.assertEqual(candidate['statusRunId'], STATUS_RUN)
        self.assertEqual(candidate['appleBuildIdentitySha256'], '8' * 64)

    def test_beta_release_plan_is_prerelease_and_never_latest(self):
        plan = release.build_release_plan(release.validate_delivery_evidence(valid_evidence(), 'beta'))

        self.assertEqual(plan['tag'], 'ios/1.1.0-beta.8')
        self.assertTrue(plan['prerelease'])
        self.assertFalse(plan['makeLatest'])
        self.assertIn(SHA, plan['body'])
        self.assertRegex(plan['planSha256'], r'^[0-9a-f]{64}$')

    def test_approval_digest_binds_both_exact_actions_artifacts(self):
        evidence = valid_evidence('release', '1.2.0', '9')
        def plan(raw):
            return release.build_release_plan(release.validate_delivery_evidence(raw, 'stable'))
        original = plan(evidence)
        for artifact in ('package_artifact', 'status_artifact'):
            for key, value in (('id', 8000), ('digest', 'sha256:' + 'f' * 64)):
                with self.subTest(artifact=artifact, key=key):
                    updated = copy.deepcopy(evidence)
                    updated[artifact][key] = value
                    if artifact == 'package_artifact':
                        record_key = 'artifact_id' if key == 'id' else 'artifact_digest'
                        updated['package_record'][record_key] = value
                    revised = plan(updated)
                    self.assertNotEqual(original['planSha256'], revised['planSha256'])
                    self.assertEqual(original['releaseIdentitySha256'], revised['releaseIdentitySha256'])

    def test_release_receipt_requires_a_recognized_apple_upload_state(self):
        evidence = valid_evidence()
        for state in ('', 'UNKNOWN', 'PROCESSING,', 'COMPLETE,UNKNOWN'):
            with self.subTest(state=state), self.assertRaises(ValueError):
                evidence['status']['remote']['uploadState'] = state
                release.validate_delivery_evidence(evidence, 'beta', preview=True)
        evidence['status']['remote']['uploadState'] = 'PROCESSING'
        release.validate_delivery_evidence(evidence, 'beta', preview=True)

    def test_stable_release_rejects_a_beta_package(self):
        with self.assertRaisesRegex(ValueError, 'profile'):
            release.validate_delivery_evidence(valid_evidence('beta'), 'stable')

    def test_cloud_signed_package_keeps_its_sealed_public_asset_names(self):
        evidence = valid_evidence()
        evidence['manifest']['details']['signingMode'] = 'cloud'
        evidence['manifest']['assets'][0]['name'] = 'Aegis-cloud-poc-1.1.0-8.ipa'
        evidence['manifest']['assets'][1]['name'] = 'Aegis-cloud-poc-1.1.0-8.dSYM.zip'

        candidate = release.validate_delivery_evidence(evidence, 'beta')

        self.assertEqual(candidate['profile'], 'beta')
        self.assertEqual([item['name'] for item in evidence['manifest']['assets']], [
            'Aegis-cloud-poc-1.1.0-8.ipa', 'Aegis-cloud-poc-1.1.0-8.dSYM.zip',
        ])

    def test_downloaded_status_archive_must_match_immutable_artifact_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / 'status.zip'
            payload = b'{"processingState":"VALID"}'
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('status.json', payload)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            destination = root / 'out' / 'status.json'

            release.extract_verified_status_archive(archive, destination, digest)

            self.assertEqual(destination.read_bytes(), payload)
            destination.unlink()
            with self.assertRaisesRegex(ValueError, 'artifact digest'):
                release.extract_verified_status_archive(archive, destination, '0' * 64)
            self.assertFalse(destination.exists())

    def test_download_returns_metadata_for_the_verified_status_receipt(self):
        receipt = valid_evidence()['status']
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            archive = directory / 'envelope.zip'
            with zipfile.ZipFile(archive, 'w') as out:
                out.writestr('status.json', json.dumps(receipt))
            raw = archive.read_bytes()
            artifact = {'id': 4101, 'name': f'ios-release-status-{STATUS_RUN}-1', 'expired': False,
                        'digest': 'sha256:' + hashlib.sha256(raw).hexdigest()}
            inventory = {'total_count': 1, 'artifacts': [artifact]}
            def download(artifact_id, destination):
                self.assertEqual(artifact_id, artifact['id'])
                destination.write_bytes(raw)
            path = directory / 'receipt.json'
            with patch.object(release, '_api', return_value=inventory), \
                 patch.object(release, '_download_actions_artifact_zip', side_effect=download) as fetch:
                metadata = release.download_status_artifact(STATUS_RUN, 4101, path)
                self.assertEqual(metadata, {**artifact, 'run_id': STATUS_RUN})
                self.assertEqual(json.loads(path.read_text()), receipt)
                inventory['artifacts'] = [{**artifact, 'id': 4102}]
                with self.assertRaisesRegex(ValueError, 'missing or ambiguous'):
                    release.download_status_artifact(STATUS_RUN, 4101, directory / 'second.json')
                fetch.assert_called_once()

    def test_downloaded_package_envelope_must_match_immutable_artifact_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / 'package-artifact.zip'
            payload = b'sealed package zip bytes'
            with zipfile.ZipFile(archive, 'w') as zipped:
                zipped.writestr('package.zip', payload)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            destination = root / 'out' / 'package.zip'

            release.extract_verified_package_archive(archive, destination, digest)

            self.assertEqual(destination.read_bytes(), payload)
            destination.unlink()
            with self.assertRaisesRegex(ValueError, 'artifact digest'):
                release.extract_verified_package_archive(archive, destination, '0' * 64)
            self.assertFalse(destination.exists())

    def test_unverified_apple_build_cannot_be_published(self):
        evidence = valid_evidence()
        evidence['status']['remote']['processingState'] = 'PROCESSING'

        with self.assertRaisesRegex(ValueError, 'VALID'):
            release.validate_delivery_evidence(evidence, 'beta')

    def test_stale_apple_valid_observation_requires_a_new_wait(self):
        evidence = valid_evidence()
        evidence['status']['remote']['observedAt'] = (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()
        with self.assertRaisesRegex(ValueError, 'stale'):
            release.validate_delivery_evidence(evidence, 'beta')

    def test_package_and_apple_status_must_match_exact_successful_attempts(self):
        for mutate, message in [
            (lambda value: value['package_run'].__setitem__('run_attempt', 2), 'producer'),
            (lambda value: value['package_run']['jobs'][0].__setitem__('conclusion', 'skipped'), 'ios-package'),
            (lambda value: value['upload_result']['intent'].__setitem__('manifestSha256', 'd' * 64), 'upload'),
            (lambda value: value['status_artifact'].__setitem__('expired', True), 'artifact'),
            (lambda value: value['status']['remote'].__setitem__('expired', True), 'VALID'),
        ]:
            evidence = valid_evidence()
            mutate(evidence)
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                release.validate_delivery_evidence(evidence, 'beta')

    def test_current_1_1_0_build_8_is_preview_only(self):
        plan = release.build_release_plan(release.validate_delivery_evidence(valid_evidence(), 'beta'))
        with patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': plan['planSha256']}):
            with self.assertRaisesRegex(ValueError, 'preview-only'):
                release.publish_release(plan, [])

    def test_public_inventory_excludes_private_signing_and_delivery_proofs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "sealed"
            root.mkdir()
            names = [
                'Aegis-beta-1.1.0-8-ios.ipa',
                'Aegis-beta-1.1.0-8-ios.app.dSYM.zip',
                'ios-manifest.json', 'ios-manifest.json.sha256',
                'package-origin.json', 'signature-verification.json',
                'apple-upload-started.json', 'apple-upload-result.json',
            ]
            for name in names:
                (root / name).write_bytes(name.encode())
            manifest = valid_evidence()['manifest']
            manifest['assets'] = [
                {'name': name, 'size': (root / name).stat().st_size,
                 'sha256': hashlib.sha256((root / name).read_bytes()).hexdigest()}
                for name in names if name.endswith(('.ipa', '.dSYM.zip'))
            ]
            manifest['details']['certificateSha1'] = 'internal-signing-fingerprint'
            manifest['assets'].append({'name': 'signature-verification.json', 'sha256': '5'*64, 'size': 123})
            manifest_bytes = json.dumps(manifest, sort_keys=True).encode()
            (root / 'ios-manifest.json').write_bytes(manifest_bytes)
            digest = hashlib.sha256(manifest_bytes).hexdigest()
            (root / 'ios-manifest.json.sha256').write_text(f'{digest}  ios-manifest.json\n')

            selected = release.public_asset_manifest(root, manifest, digest)
            paths = {item['name']: Path(item['path']) for item in selected}
            public = paths['ios-manifest.json'].read_bytes()
            self.assertNotIn(b'internal-signing-fingerprint', public)
            self.assertNotIn(b'signature-verification.json', public)
            self.assertNotIn('details', json.loads(public))
            self.assertEqual(paths['ios-manifest.json.sha256'].read_text(),
                             f"{hashlib.sha256(public).hexdigest()}  ios-manifest.json\n")
            self.assertEqual((root / 'ios-manifest.json').read_bytes(), manifest_bytes)

        self.assertEqual({item['name'] for item in selected}, {
            'Aegis-beta-1.1.0-8-ios.ipa', 'Aegis-beta-1.1.0-8-ios.app.dSYM.zip',
            'ios-manifest.json', 'ios-manifest.json.sha256',
        })
        self.assertNotIn('signature-verification.json', {item['name'] for item in selected})


class FakePublisher:
    def __init__(self):
        self.tag = None
        self.release = None
        self.create_calls = []
        self.upload_calls = []
        self.ruleset = json.loads((ROOT / '.github/ios-public-release-tag-ruleset.json').read_text())
        self.ruleset.update(id=700)
        self.environment = {'id': 901, 'name': release.PRODUCTION_ENVIRONMENT,
            'can_admins_bypass': False,
            'deployment_branch_policy': {'protected_branches': True, 'custom_branch_policies': False},
            'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': True,
                'reviewers': [{'type': 'User', 'reviewer': {'id': 2, 'login': 'reviewer'}}]}]}
        self.admins = [
            {'id': 1, 'login': 'controller', 'permissions': {'admin': True}},
            {'id': 2, 'login': 'reviewer', 'permissions': {'admin': True}},
        ]
        self.approvals = []

    def get(self, path):
        if path.startswith('rulesets?'):
            return [{'id': self.ruleset['id'], 'name': self.ruleset['name']}]
        if path == 'rulesets/700':
            return self.ruleset
        if path.startswith('git/ref/tags/'):
            if self.tag is None:
                raise release.NotFoundError('missing tag')
            return {'ref': 'refs/tags/' + self.tag['name'],
                    'object': {'type': 'tag', 'sha': self.tag['tag_sha']}}
        if path.startswith('git/tags/'):
            return {'object': {'type': 'commit', 'sha': self.tag['source_sha']},
                    'message': self.tag['message']}
        if path.startswith('releases/tags/'):
            if self.release is None or self.release['draft']:
                raise release.NotFoundError('missing release')
            return copy.deepcopy(self.release)
        if path.startswith('environments/'):
            return self.environment
        if path.startswith('collaborators?'):
            return self.admins
        if path.endswith('/approvals'):
            return self.approvals
        if path.startswith('releases?'):
            return [copy.deepcopy(self.release)] if self.release else []
        if path == 'releases/500':
            return copy.deepcopy(self.release)
        if path.startswith('releases/500/assets?'):
            return copy.deepcopy(self.release['assets'])
        if path == 'releases/latest':
            if self.release is None:
                raise release.NotFoundError('no latest')
            return copy.deepcopy(self.release)
        raise AssertionError(path)

    def request(self, path, payload=None):
        self.create_calls.append((path, payload))
        if path == 'git/tags':
            self.tag = {'name': payload['tag'], 'tag_sha': 'd' * 40,
                        'source_sha': payload['object'], 'message': payload['message']}
            return {'sha': self.tag['tag_sha']}
        if path == 'git/refs':
            return {'ref': payload['ref'], 'object': {'sha': payload['sha']}}
        if path == 'releases':
            self.release = {'id': 500, 'tag_name': payload['tag_name'], 'name': payload['name'],
                'body': payload['body'], 'draft': payload['draft'], 'prerelease': payload['prerelease'], 'assets': []}
            return copy.deepcopy(self.release)
        if path == 'releases/500':
            if len(self.release['assets']) != 4:
                raise AssertionError('Cannot publish before all four assets are staged')
            self.release['draft'] = payload['draft']
            return copy.deepcopy(self.release)
        raise AssertionError(path)


class PublicReleaseMutationTests(unittest.TestCase):
    def test_read_only_ruleset_checks_live_rules_when_bypass_fields_are_redacted(self):
        state = FakePublisher()
        del state.ruleset['bypass_actors']
        with patch.object(release, '_api', side_effect=state.get):
            release._verify_tag_ruleset()
            state.ruleset['rules'] = [{'type': 'deletion'}]
            with self.assertRaisesRegex(ValueError, 'protect update/deletion'):
                release._verify_tag_ruleset()

    def test_unreconciled_upload_leaves_draft_unpublished_and_can_resume(self):
        plan = release.build_release_plan(release.validate_delivery_evidence(valid_evidence('beta', '1.2.0', '9'), 'beta'))
        assets = [{'name': name, 'sha256': digest} for name, digest in plan['assets'].items()]
        state = FakePublisher()

        def api(path, payload=None, method=None):
            return state.request(path, payload) if payload is not None else state.get(path)

        def uploaded(_release_id, asset):
            state.release['assets'].append({'name': asset['name'], 'state': 'uploaded',
                                            'digest': 'sha256:' + asset['sha256']})
            raise OSError('response lost')

        with patch.object(release, '_api', side_effect=api), patch.object(release, 'GitHub', return_value=state), \
             patch.object(release, '_assert_current_release_source'), \
             patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': plan['planSha256']}):
            with patch.object(release, '_upload_asset_once', side_effect=OSError('uncommitted')) as upload:
                with self.assertRaisesRegex(ValueError, 'outcome unknown'):
                    release.publish_release(plan, assets)
                upload.assert_called_once()
            self.assertTrue(state.release['draft'])
            self.assertEqual(state.release['assets'], [])
            with patch.object(release, '_upload_asset_once', side_effect=uploaded) as upload:
                release.publish_release(plan, assets)
                self.assertEqual(upload.call_count, 4)
        self.assertFalse(state.release['draft'])
        self.assertNotIn(plan['appleBuildIdentitySha256'], state.release['body'])

    def test_main_move_after_approval_stops_before_any_mutation(self):
        plan = release.build_release_plan(release.validate_delivery_evidence(valid_evidence('release', '1.2.0', '9'), 'stable'))
        with patch.object(release, '_verify_tag_ruleset'), patch.object(release, '_check_approval') as approval, \
             patch.object(release, '_current_repository', return_value=({}, '9' * 40, TREE)), \
             patch.object(release, '_api') as api, patch.dict('os.environ', {
                 'EXPECTED_PLAN_SHA256': plan['planSha256'], 'GITHUB_RUN_ID': '444'}):
            with self.assertRaisesRegex(ValueError, 'no longer current main'):
                release.publish_release(plan, [])
        approval.assert_called_once()
        api.assert_not_called()

    def test_freshness_and_draft_are_rechecked_after_stable_approval(self):
        evidence = valid_evidence('release', '1.2.0', '9')
        plan = release.build_release_plan(release.validate_delivery_evidence(evidence, 'stable'))
        assets = [{'name': name, 'sha256': digest} for name, digest in plan['assets'].items()]
        for failure in ('stale', 'edited', 'main-moved'):
            with self.subTest(failure=failure):
                state = FakePublisher()
                checks = 0

                def api(path, payload=None, method=None):
                    return state.request(path, payload) if payload is not None else state.get(path)

                main_moved = False
                expired = False

                def read_release(path, payload=None, method=None):
                    nonlocal main_moved, expired
                    result = api(path, payload, method)
                    if path == 'releases/500' and payload is None:
                        main_moved = failure == 'main-moved'
                        expired = failure == 'stale'
                    return result

                def verify_current(_plan):
                    if main_moved:
                        raise ValueError('main moved')

                def verify_fresh(_observed_at):
                    if expired:
                        raise ValueError('stale')

                def upload(_id, asset):
                    state.release['assets'].append({'name': asset['name'], 'state': 'uploaded',
                                                    'digest': 'sha256:' + asset['sha256']})

                def approval(_plan, _run_id):
                    nonlocal checks
                    checks += 1
                    if checks == 2 and failure == 'edited':
                        state.release['body'] = 'Changed outside the Bot'

                with patch.object(release, '_api', side_effect=read_release), patch.object(release, 'GitHub', return_value=state), \
                     patch.object(release, '_assert_current_release_source', side_effect=verify_current), patch.object(release, '_upload_asset_once', side_effect=upload), \
                     patch.object(release, '_check_approval', side_effect=approval), patch.dict('os.environ', {
                         'EXPECTED_PLAN_SHA256': plan['planSha256'], 'GITHUB_RUN_ID': '444'}):
                    with patch.object(release, '_require_fresh_observation',
                                      side_effect=verify_fresh):
                        with self.assertRaisesRegex(ValueError, 'stale|metadata conflicts|main moved'):
                            release.publish_release(plan, assets)
                self.assertEqual(checks, 2)
                self.assertTrue(state.release['draft'])
                self.assertEqual(len(state.release['assets']), 4)

    def test_stable_preview_rejects_team_reviewers(self):
        state = FakePublisher()
        state.environment['protection_rules'][0]['reviewers'].append({'type': 'Team', 'reviewer': {'id': 20}})
        with patch.object(release, '_api', side_effect=state.get), \
             patch.dict('os.environ', {'AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS': '2'}):
            with self.assertRaisesRegex(ValueError, 'named User reviewers only'):
                release._production_environment_config()

    def test_stale_observation_stops_before_creating_public_tag_ref(self):
        evidence = valid_evidence('beta', '1.2.0', '9')
        plan = release.build_release_plan(release.validate_delivery_evidence(evidence, 'beta'))
        plan['appleObservedAt'] = (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()
        state = FakePublisher()
        with patch.object(release, '_tag_target', return_value=None), \
             patch.object(release, '_assert_current_release_source'):
            with self.assertRaisesRegex(ValueError, 'stale'):
                release._create_tag(plan, state)
        self.assertEqual(state.create_calls, [])

    def test_recovery_with_existing_tag_ref_cannot_create_draft_after_expiry(self):
        evidence = valid_evidence('beta', '1.2.0', '9')
        plan = release.build_release_plan(release.validate_delivery_evidence(evidence, 'beta'))
        plan['appleObservedAt'] = (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()
        state = FakePublisher()
        state.tag = {'name': plan['tag'], 'tag_sha': 'd' * 40, 'source_sha': SHA,
                     'message': release._expected_tag_message(plan)}

        def api(path, payload=None, method=None):
            return state.request(path, payload) if payload is not None else state.get(path)

        with patch.object(release, '_api', side_effect=api), patch.object(release, 'GitHub', return_value=state), \
             patch.object(release, '_assert_current_release_source'), \
             patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': plan['planSha256']}):
            with self.assertRaisesRegex(ValueError, 'stale'):
                release.publish_release(plan, [])
        self.assertEqual(state.create_calls, [])

    def test_beta_publish_is_annotated_prerelease_not_latest_and_idempotent(self):
        candidate = release.validate_delivery_evidence(valid_evidence('beta', '1.2.0', '9'), 'beta')
        plan = release.build_release_plan(candidate)
        assets = [{'name': name, 'path': '/tmp/' + name, 'size': 10, 'sha256': digest}
                  for name, digest in plan['assets'].items()]
        state = FakePublisher()

        def api(path, payload=None, method=None):
            return state.request(path, payload) if payload is not None else state.get(path)

        def upload(release_id, asset):
            self.assertEqual(release_id, 500)
            self.assertTrue(state.release['draft'])
            state.upload_calls.append(asset['name'])
            state.release['assets'].append({'name': asset['name'], 'state': 'uploaded',
                'digest': 'sha256:' + asset['sha256'], 'size': asset['size']})

        with patch.object(release, '_api', side_effect=api), patch.object(release, 'GitHub', return_value=state), \
             patch.object(release, '_assert_current_release_source'), patch.object(release, '_upload_asset_once', side_effect=upload), \
             patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': plan['planSha256']}):
            release.publish_release(plan, assets)
            first_create_count = len(state.create_calls)
            first_upload_count = len(state.upload_calls)
            release.publish_release(plan, assets)

        self.assertEqual(plan['tag'], 'ios/1.2.0-beta.9')
        self.assertTrue(plan['prerelease'])
        self.assertFalse(plan['makeLatest'])
        payload = next(payload for path, payload in state.create_calls if path == 'releases')
        self.assertIs(payload['prerelease'], True)
        self.assertIs(payload['draft'], True)
        self.assertIn(('releases/500', {'draft': False, 'make_latest': 'false'}), state.create_calls)
        self.assertEqual(first_create_count, len(state.create_calls))
        self.assertEqual(first_upload_count, len(state.upload_calls))
        self.assertEqual({item['name'] for item in state.release['assets']}, set(plan['assets']))

    def test_stable_approval_requires_exact_digest_and_a_separate_current_admin(self):
        candidate = release.validate_delivery_evidence(valid_evidence('release', '1.2.0', '9'), 'stable')
        plan = release.build_release_plan(candidate)
        environment = {'id': 901, 'name': release.PRODUCTION_ENVIRONMENT,
            'can_admins_bypass': False,
            'deployment_branch_policy': {'protected_branches': True, 'custom_branch_policies': False},
            'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': True,
                'reviewers': [{'type': 'User', 'reviewer': {'id': 2, 'login': 'reviewer'}}]}]}
        admins = [
            {'id': 1, 'login': 'controller', 'permissions': {'admin': True}},
            {'id': 2, 'login': 'reviewer', 'permissions': {'admin': True}},
        ]
        approval = {'state': 'approved', 'comment': 'publish ' + plan['planSha256'],
            'environments': [{'id': 901, 'name': release.PRODUCTION_ENVIRONMENT}],
            'user': {'id': 2, 'login': 'reviewer'}}
        def api(path, payload=None, method=None):
            if path.startswith('environments/'):
                return environment
            if path.startswith('collaborators?'):
                return admins
            if path == 'actions/runs/444/approvals':
                return [approval]
            raise AssertionError(path)

        with patch.object(release, '_api', side_effect=api), patch.dict('os.environ', {
            'AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS': '2', 'CONTROLLER_ADMIN_IDS': '1'}):
            release._check_approval(plan, 444)
            approval['comment'] = 'approved'
            with self.assertRaisesRegex(ValueError, 'exact plan digest'):
                release._check_approval(plan, 444)

    def test_stable_environment_must_keep_its_protection_settings(self):
        candidate = release.validate_delivery_evidence(valid_evidence('release', '1.2.0', '9'), 'stable')
        plan = release.build_release_plan(candidate)
        environment = {'id': 901, 'can_admins_bypass': True,
            'deployment_branch_policy': {'protected_branches': True},
            'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': True,
                'reviewers': [{'type': 'User', 'reviewer': {'id': 2}}]}]}
        def api(path, payload=None, method=None):
            if path.startswith('environments/'):
                return environment
            if path.startswith('collaborators?'):
                return [{'id': 2, 'login': 'reviewer', 'permissions': {'admin': True}}]
            raise AssertionError(path)
        with patch.object(release, '_api', side_effect=api), patch.dict('os.environ', {'AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS': '2'}):
            with self.assertRaisesRegex(ValueError, 'admin bypass'):
                release._production_environment_config()

    def test_stable_approval_must_be_from_a_current_environment_reviewer(self):
        candidate = release.validate_delivery_evidence(valid_evidence('release', '1.2.0', '9'), 'stable')
        plan = release.build_release_plan(candidate)
        environment = {'id': 901, 'can_admins_bypass': False,
            'deployment_branch_policy': {'protected_branches': True},
            'protection_rules': [{'type': 'required_reviewers', 'prevent_self_review': True,
                'reviewers': [{'type': 'User', 'reviewer': {'id': 3, 'login': 'replacement'}}]}]}
        admins = [
            {'id': 1, 'login': 'controller', 'permissions': {'admin': True}},
            {'id': 2, 'login': 'reviewer', 'permissions': {'admin': True}},
            {'id': 3, 'login': 'replacement', 'permissions': {'admin': True}},
        ]
        approval = {'state': 'approved', 'comment': 'publish ' + plan['planSha256'],
            'environments': [{'id': 901, 'name': release.PRODUCTION_ENVIRONMENT}],
            'user': {'id': 2, 'login': 'reviewer'}}
        def api(path, payload=None, method=None):
            if path.startswith('environments/'):
                return environment
            if path.startswith('collaborators?'):
                return admins
            if path == 'actions/runs/444/approvals':
                return [approval]
            raise AssertionError(path)

        with patch.object(release, '_api', side_effect=api), patch.dict('os.environ', {
            'AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS': '2,3', 'CONTROLLER_ADMIN_IDS': '1'}):
            with self.assertRaisesRegex(ValueError, 'current Environment reviewer'):
                release._check_approval(plan, 444)

    def test_stable_preview_validates_environment_configuration(self):
        candidate = release.validate_delivery_evidence(valid_evidence('release', '1.2.0', '9'), 'stable')
        plan = release.build_release_plan(candidate)
        with patch.object(release, '_verify_tag_ruleset'), patch.object(release, '_tag_target', return_value=None), \
             patch.object(release, '_release_by_tag', return_value=None), \
             patch.object(release, '_production_environment_config') as environment_config:
            result = release.preview_release(plan)

        environment_config.assert_called_once_with()
        self.assertTrue(result['productionEnvironmentVerified'])
        self.assertEqual(result['draftStatus'], 'unverified')

    def test_release_identity_is_stable_across_fresh_wait_runs_for_reconciliation(self):
        first = valid_evidence('beta', '1.2.0', '9')
        second = valid_evidence('beta', '1.2.0', '9')
        second_status_run = STATUS_RUN + 1
        second['status_run'] = run(second_status_run, '.github/workflows/ios-delivery.yml',
                                   [job('status-query', second_status_run)])
        second['status_artifact'].update(id=4102, name=f'ios-release-status-{second_status_run}-1',
                                         run_id=second_status_run)
        plan_a = release.build_release_plan(release.validate_delivery_evidence(first, 'beta'))
        plan_b = release.build_release_plan(release.validate_delivery_evidence(second, 'beta'))

        self.assertNotEqual(plan_a['planSha256'], plan_b['planSha256'])
        self.assertEqual(plan_a['releaseIdentitySha256'], plan_b['releaseIdentitySha256'])
        self.assertEqual(plan_a['body'], plan_b['body'])
        state = FakePublisher()
        state.tag = {'name': plan_a['tag'], 'tag_sha': 'd' * 40,
                     'source_sha': plan_a['source']['sha'],
                     'message': release._expected_tag_message(plan_a)}
        with patch.object(release, '_api', side_effect=state.get), \
             patch.object(release, '_verify_tag_ruleset'):
            resumed = release.preview_release(plan_b)

        self.assertTrue(resumed['existingTag'])

    def test_stable_publish_requires_reviewed_plan_and_sets_latest(self):
        candidate = release.validate_delivery_evidence(valid_evidence('release', '1.2.0', '9'), 'stable')
        plan = release.build_release_plan(candidate)
        assets = [{'name': name, 'path': '/tmp/' + name, 'size': 10, 'sha256': digest}
                  for name, digest in plan['assets'].items()]
        state = FakePublisher()
        state.approvals = [{'state': 'approved', 'comment': 'publish ' + plan['planSha256'],
            'environments': [{'id': 901, 'name': release.PRODUCTION_ENVIRONMENT}],
            'user': {'id': 2, 'login': 'reviewer'}}]

        def api(path, payload=None, method=None):
            return state.request(path, payload) if payload is not None else state.get(path)

        def upload(release_id, asset):
            self.assertEqual(release_id, 500)
            self.assertTrue(state.release['draft'])
            state.upload_calls.append(asset['name'])
            state.release['assets'].append({'name': asset['name'], 'state': 'uploaded',
                'digest': 'sha256:' + asset['sha256'], 'size': asset['size']})

        with patch.object(release, '_api', side_effect=api), patch.object(release, 'GitHub', return_value=state), \
             patch.object(release, '_assert_current_release_source'), patch.object(release, '_upload_asset_once', side_effect=upload), patch.dict('os.environ', {
                'EXPECTED_PLAN_SHA256': plan['planSha256'], 'GITHUB_RUN_ID': '444',
                'AEGIS_IOS_GITHUB_RELEASE_ADMIN_IDS': '2', 'CONTROLLER_ADMIN_IDS': '1'}):
            release.publish_release(plan, assets)

        payload = next(payload for path, payload in state.create_calls if path == 'releases')
        self.assertIs(payload['prerelease'], False)
        self.assertIs(payload['draft'], True)
        self.assertEqual(payload['make_latest'], 'false')
        self.assertIn(('releases/500', {'draft': False, 'make_latest': 'true'}), state.create_calls)
        self.assertEqual(plan['tag'], 'ios/1.2.0-release.9')


if __name__ == '__main__':
    unittest.main()
