from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from urllib.parse import quote
import zipfile


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load('android_github_release', 'android-github-release.py')
archive = load('android_package_archive', 'android_package_archive.py')
verifier = load('verify_aab', 'verify-aab.py')

SHA = 'a' * 40
TREE = 'b' * 40
PACKAGE_RUN = 41
STATUS_RUN = 42
DIGEST = 'cd' * 32


def job(job_id, name, run_id):
    return {'id': job_id, 'name': name, 'run_id': run_id, 'run_attempt': 1, 'head_sha': SHA,
            'status': 'completed', 'conclusion': 'success'}


def workflow_run(run_id, path, jobs):
    return {'id': run_id, 'run_attempt': 1, 'head_sha': SHA, 'head_branch': 'main',
            'status': 'completed', 'conclusion': 'success', 'event': 'workflow_dispatch', 'path': path,
            'repository': {'id': release.REPOSITORY_ID, 'full_name': release.REPOSITORY},
            'head_repository': {'id': release.REPOSITORY_ID, 'full_name': release.REPOSITORY},
            'jobs': jobs}


def evidence(profile='release', symbols=True, observed_at=None):
    version, build = '7.2.0.339', '2007000339'
    aab, symbols_name = archive.asset_names(version, build)
    assets = [{'name': aab, 'size': 4, 'sha256': 'ab' * 32}]
    if symbols:
        assets.append({'name': symbols_name, 'size': 4, 'sha256': 'ef' * 32})
    manifest = {'repository': release.REPOSITORY, 'platform': 'android', 'applicationId': release.APPLICATION_ID,
                'profile': profile, 'version': version, 'build': build,
                'source': {'sha': SHA, 'tree': TREE, 'dirty': False}, 'assets': assets,
                'details': {'certificateSha256': DIGEST}}
    origin = {'repository': release.REPOSITORY, 'runId': PACKAGE_RUN, 'attempt': 1, 'sourceSha': SHA,
              'sourceTree': TREE, 'runIdLocal': f'android-gh-{PACKAGE_RUN}-1', 'manifestSha256': DIGEST}
    intent = release.play.draft_intent(version, build, 'release', DIGEST, 'internal')
    return {'version': version, 'build': build,
            'repository': {'id': release.REPOSITORY_ID, 'full_name': release.REPOSITORY, 'default_branch': 'main'},
            'current_sha': SHA, 'current_tree': TREE,
            'package_run': workflow_run(PACKAGE_RUN, '.github/workflows/android-delivery.yml',
                                        [job(11, 'delivery / package', PACKAGE_RUN), job(12, 'delivery / store', PACKAGE_RUN)]),
            'upload_run': workflow_run(PACKAGE_RUN, '.github/workflows/android-delivery.yml',
                                       [job(12, 'delivery / store', PACKAGE_RUN)]),
            'package_record': {'origin': origin, 'profile': profile, 'version': version, 'build': build,
                               'package_job_id': 11, 'artifact_id': 70, 'artifact_name': f'android-package-{PACKAGE_RUN}-1',
                               'artifact_digest': 'sha256:' + '11' * 32},
            'package_artifact': {'id': 70, 'name': f'android-package-{PACKAGE_RUN}-1', 'expired': False,
                                 'digest': 'sha256:' + '11' * 32},
            'manifest': manifest, 'manifest_sha256': DIGEST, 'upload_start': intent,
            'upload_result': {'intent': intent, 'uploadRunId': PACKAGE_RUN, 'uploadRunAttempt': 1,
                              'result': {'status': 'uploaded_draft', 'packageName': release.APPLICATION_ID,
                                         'track': 'internal', 'releaseStatus': 'draft', 'versionCode': int(build)}},
            'status_run': workflow_run(STATUS_RUN, '.github/workflows/android-delivery.yml',
                                       [job(21, 'delivery / query', STATUS_RUN)]),
            'status_artifact': {'id': 80, 'name': f'android-release-status-{STATUS_RUN}-1', 'expired': False,
                                'digest': 'sha256:' + '22' * 32, 'run_id': STATUS_RUN},
            'status': {'platform': 'android', 'applicationId': release.APPLICATION_ID, 'version': version, 'build': build,
                       'queryMode': 'release-wait', 'readOnly': True, 'packageProvenanceVerified': False,
                       'querySource': {'sha': SHA, 'tree': TREE, 'dirty': False},
                       'remote': {'packageName': release.APPLICATION_ID, 'versionCode': int(build),
                                  'processingState': 'VALID', 'expired': False, 'uploadState': 'COMPLETE',
                                  'buildIdentitySha256': '33' * 32,
                                  'observedAt': observed_at or datetime.now(timezone.utc).isoformat()}}}


class ReleaseEvidenceTests(unittest.TestCase):
    def test_plan_digest_tracks_artifacts_and_publication_separately(self):
        candidate = release.validate_delivery_evidence(evidence(), 'stable', 'prerelease')
        first = release.build_release_plan(candidate)
        changed = release.build_release_plan({**candidate, 'artifactId': 71})
        stable = release.validate_delivery_evidence(evidence(), 'stable', 'stable')
        promoted = release.build_release_plan(stable, stable_release_id=37)
        replacement = release.build_release_plan(stable, stable_release_id=38)
        self.assertNotIn('releaseId', first)
        self.assertEqual(promoted['releaseId'], 37)
        self.assertNotEqual(promoted['planSha256'], replacement['planSha256'])
        self.assertEqual(promoted['releaseIdentitySha256'], replacement['releaseIdentitySha256'])
        self.assertEqual(release._expected_tag_message(promoted), release._expected_tag_message(replacement))
        for invalid in (None, True, 0, -1, '37'):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ValueError, 'positive GitHub Release ID'):
                release.build_release_plan(stable, stable_release_id=invalid)
        self.assertNotEqual(first['planSha256'], changed['planSha256'])
        self.assertEqual(first['releaseIdentitySha256'], changed['releaseIdentitySha256'])
        self.assertEqual(first['releaseIdentitySha256'], promoted['releaseIdentitySha256'])
        self.assertNotEqual(first['planSha256'], promoted['planSha256'])
        self.assertEqual(first['tag'], 'android/7.2.0.339-release.2007000339')
        public = archive.public_manifest_payloads(candidate['manifest'])
        self.assertNotIn(b'certificate', public['android-manifest.json'])

    def test_stale_profile_and_symbols_fail_closed(self):
        stale = evidence(observed_at='2020-01-01T00:00:00+00:00')
        with self.assertRaises(ValueError):
            release.validate_delivery_evidence(stale, 'stable', 'prerelease')
        alpha = evidence(profile='alpha')
        with self.assertRaises(ValueError):
            release.validate_delivery_evidence(alpha, 'stable', 'prerelease')
        with self.assertRaises(ValueError):
            release.validate_delivery_evidence(evidence(symbols=False), 'stable', 'prerelease')

    def test_status_archive_and_certificate_parser(self):
        raw = io.BytesIO()
        with zipfile.ZipFile(raw, 'w') as zipped:
            zipped.writestr('status.json', '{"ok":true}')
        blob = raw.getvalue()
        digest = hashlib.sha256(blob).hexdigest()
        with tempfile.TemporaryDirectory() as temp:
            bundle = Path(temp) / 'status.zip'
            bundle.write_bytes(blob)
            release.extract_verified_status_archive(bundle, Path(temp) / 'status.json', digest)
            self.assertEqual((Path(temp) / 'status.json').read_text(), '{"ok":true}')
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'bundle.aab'
            with zipfile.ZipFile(path, 'w') as bundle:
                bundle.writestr('BundleConfig.pb', b'config')
            with mock.patch.object(verifier.subprocess, 'run',
                                   return_value=mock.Mock(returncode=0, stdout=DIGEST + '\n')) as java:
                self.assertEqual(verifier.certificate_sha256(path), DIGEST)
                args = java.call_args.args[0]
                self.assertEqual(args[0], 'java')
                self.assertTrue(args[1].endswith('VerifiedAabCertificate.java'))
            with mock.patch.object(verifier.subprocess, 'run', return_value=mock.Mock(returncode=1)):
                with self.assertRaisesRegex(ValueError, 'single verified certificate'):
                    verifier.certificate_sha256(path)


    def test_ruleset_allows_omitted_bypass_and_promotion_needs_a_prerelease(self):
        desired = json.loads((Path(__file__).resolve().parents[2] / release.TAG_RULESET).read_text())
        live = {key: value for key, value in desired.items() if key != 'bypass_actors'}
        live['id'] = 7

        def fake_api(path, payload=None, method=None):
            if path.startswith('rulesets?'):
                return [{'id': 7, 'name': desired['name']}]
            if path == 'rulesets/7':
                return live
            raise AssertionError(path)

        original = release._api
        release._api = fake_api
        try:
            release._verify_tag_ruleset()
        finally:
            release._api = original
        candidate = release.validate_delivery_evidence(evidence(), 'stable', 'stable')
        plan = release.build_release_plan(candidate, stable_release_id=37)

        def missing(path, payload=None, method=None):
            if path.startswith('releases/tags/'):
                raise release.NotFoundError('missing')
            if path == 'releases':
                return []
            raise AssertionError(path)

        with (mock.patch.object(release, '_current_repository', return_value=({}, SHA, TREE)),
              mock.patch.object(release, '_api', side_effect=missing)):
            with self.assertRaisesRegex(ValueError, 'public prerelease'):
                release._promote_to_stable(plan)

    def test_stable_promotion_rejects_retagged_prerelease_before_patch(self):
        candidate = release.validate_delivery_evidence(evidence(), 'stable', 'stable')
        plan = release.build_release_plan(candidate, stable_release_id=37)
        prerelease = {'id': 37, 'tag_name': plan['tag'], 'draft': False, 'prerelease': True,
                      'assets': [{'name': name, 'state': 'uploaded', 'digest': 'sha256:' + digest}
                                 for name, digest in plan['assets'].items()]}
        original_tag = quote(plan['tag'], safe='')
        tag_sha = 'c' * 40
        responses = {
            f'releases/tags/{original_tag}': prerelease,
            f'git/ref/tags/{original_tag}': {'object': {'type': 'tag', 'sha': tag_sha}},
            f'git/tags/{tag_sha}': {'object': {'type': 'commit', 'sha': SHA},
                                   'message': release._expected_tag_message(plan)},
            'releases/37': {**prerelease, 'tag_name': 'android/retagged'},
        }

        with (mock.patch.dict(release.os.environ, {'GITHUB_RUN_ID': '51'}),
              mock.patch.object(release, '_current_repository', return_value=({}, SHA, TREE)),
              mock.patch.object(release, '_check_approval'),
              mock.patch.object(release, '_api', side_effect=responses.__getitem__) as api):
            with self.assertRaisesRegex(ValueError, 'Release ID or tag changed'):
                release._promote_to_stable(plan)

        self.assertEqual(api.call_args_list, [
            mock.call(f'releases/tags/{original_tag}'),
            mock.call(f'git/ref/tags/{original_tag}'), mock.call(f'git/tags/{tag_sha}'),
            mock.call(f'git/ref/tags/{original_tag}'), mock.call(f'git/tags/{tag_sha}'),
            mock.call('releases/37'),
        ])

    def test_seal_round_trip(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            aab = root / 'app.aab'
            symbols = root / 'symbols.zip'
            with zipfile.ZipFile(aab, 'w') as zipped:
                zipped.writestr('BundleConfig.pb', b'bundle')
            with zipfile.ZipFile(symbols, 'w') as zipped:
                zipped.writestr('libchrome.so', b'ELF')
            version, build = '7.2.0.339', '2007000339'
            names = archive.asset_names(version, build)
            manifest = {'schema': 'aegis-android-manifest-v1', 'repository': archive.REPOSITORY, 'platform': 'android',
                        'applicationId': archive.APPLICATION_ID, 'profile': 'release', 'version': version, 'build': build,
                        'source': {'sha': SHA, 'tree': TREE, 'dirty': False},
                        'details': {'certificateSha256': DIGEST},
                        'assets': [{'name': names[0], 'size': aab.stat().st_size, 'sha256': archive.sha256(aab)},
                                   {'name': names[1], 'size': symbols.stat().st_size, 'sha256': archive.sha256(symbols)}]}
            digest, origin = archive.seal(root / 'sealed', manifest,
                                          {'repository': archive.REPOSITORY, 'runId': 9, 'attempt': 1,
                                           'sourceSha': SHA, 'sourceTree': TREE, 'runIdLocal': 'android-gh-9-1'},
                                          {'schema': 'aegis-android-signature-v1', 'certificateSha256': DIGEST,
                                           'artifactSha256': archive.sha256(aab)},
                                          {names[0]: aab, names[1]: symbols})
            archive.zip_flat(root / 'sealed', root / 'package.zip')
            archive.extract_flat(root / 'package.zip', root / 'again')
            self.assertEqual(archive.verify_package(root / 'again', SHA, TREE, digest)['profile'], 'release')
            self.assertEqual(origin['manifestSha256'], digest)


if __name__ == '__main__':
    unittest.main()
