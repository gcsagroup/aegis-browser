"""Android delivery matrix: plan, Play, archive, records, evidence, and publication."""
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
from threading import Thread
import unittest
from unittest import mock
import zipfile


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


plan = load('android_delivery_plan_matrix', 'android-delivery-plan.py')
receipt = load('android_delivery_receipt_matrix', 'android-delivery-receipt.py')
play = load('android_play_matrix', 'android-play.py')
archive = load('android_package_archive_matrix', 'android_package_archive.py')
records = load('android_product_delivery_matrix', 'android_product_delivery.py')
delivery = load('android_delivery_matrix', 'android-delivery.py')
status = load('android_status_matrix', 'android-status.py')
drafts = load('android_draft_verify_matrix', 'android-draft-verify.py')
verifier = load('verify_aab_matrix', 'verify-aab.py')
release = load('android_github_release_matrix', 'android-github-release.py')

SHA = 'a' * 40
TREE = 'b' * 40
VERSION = '7.2.0.339'
BUILD = '2007000339'
OLDER = ('6.1.0.266', '2006000266')


def simple(operation, product, version=VERSION, build=BUILD, **extra):
    inputs = {'operation': operation, 'product': product, 'version': version, 'build': build, **extra}
    return plan.normalize('workflow_dispatch', 'refs/heads/main', inputs, source_sha=SHA)


def full(operation, product, target, advanced, attempt='1'):
    return plan.normalize('workflow_dispatch', 'refs/heads/main',
                          {'operation': operation, 'product': product, 'target': target, 'advanced': advanced},
                          mode='full', source_sha=SHA, attempt=attempt)


def receipt_for(profile='release', package_run='41', state_run='41', draft=False):
    return receipt.encode(profile, VERSION, BUILD, package_run, state_run, '1', 'ab' * 32, draft=draft)


class PlanMatrix(unittest.TestCase):
    def test_simple_operation_and_product_matrix(self):
        rows = [
            ('仅打包 / Package', 'Alpha · 仅内测 / Internal only', 'package', 'alpha', 'artifacts', ''),
            ('Package', 'Beta', 'package', 'beta', 'artifacts', ''),
            ('打包并上传 / Package and upload', 'Alpha · 仅内测 / Internal only', 'package-upload', 'alpha', 'play-draft', 'internal'),
            ('Package and upload', 'Beta · 内外测 / Internal and external', 'package-upload', 'beta', 'play-draft', 'beta'),
            ('Package and upload', 'Release · 通用 / Universal', 'package-upload', 'release', 'play-draft', 'internal'),
            ('查询状态 / Status', 'Release', 'status-query', 'release', 'play-internal', ''),
            ('等待状态 / Wait', 'Alpha', 'status-wait', 'alpha', 'play-internal', ''),
            ('发布核对 / Release Wait', 'Release', 'status-release-wait', 'release', 'play-internal', ''),
            ('Release Wait', 'Release', 'status-release-wait', 'release', 'play-internal', ''),
            ('Status', 'Alpha', 'status-query', 'alpha', 'play-internal', ''),
        ]
        for operation, product, expected, profile, destination, track in rows:
            with self.subTest(operation=operation, product=product):
                value = simple(operation, product)
                self.assertEqual((value['operation'], value['profile'], value['destination'], value['track']),
                                 (expected, profile, destination, track))
                self.assertFalse(value['tag'])
                self.assertNotIn('\n', json.dumps(value))

    def test_both_released_coordinates_bind_version_code(self):
        for version, build in ((VERSION, BUILD), OLDER):
            with self.subTest(version=version):
                value = simple('仅打包 / Package', 'Release', version, build)
                self.assertEqual((value['version'], value['build']), (version, build))
                self.assertEqual(receipt.require_version_code(version, build) % 10000, int(version.rsplit('.', 1)[1]))

    def test_simple_rejections(self):
        rejected = [
            dict(operation='打包并上传 / Package and upload', product='Release', build='2007000340'),
            dict(operation='仅打包 / Package', product='自动 / Auto'),
            dict(operation='Package and upload', product='Release', approved_source_sha='b' * 40),
            dict(operation='Status', product='Release', version='7.2.0', build='339'),
        ]
        for inputs in rejected:
            with self.subTest(inputs=inputs):
                with self.assertRaises(ValueError):
                    simple(**inputs)
        with self.assertRaises(ValueError):
            plan.normalize('workflow_dispatch', 'refs/heads/main',
                           {'operation': '打包并上传 / Package and upload', 'product': 'Release',
                            'version': VERSION, 'build': BUILD}, attempt='2', source_sha=SHA)
        with self.assertRaises(ValueError):
            plan.normalize('push', 'refs/heads/main',
                           {'operation': 'Status', 'product': 'Alpha', 'version': VERSION, 'build': BUILD})

    def test_full_track_fraction_and_submit_matrix(self):
        pinned = receipt_for('beta')
        beta_internal = full('完整模式 / Full', '自动 / Auto', pinned,
                             '{"operation":"upload","track":"internal"}')
        self.assertEqual((beta_internal['operation'], beta_internal['track'], beta_internal['destination']),
                         ('upload', 'internal', 'play-draft'))
        uploaded = receipt_for('beta', '41', '43', draft=True)
        beta_track = full('完整模式 / Full', 'Beta', uploaded, '{"operation":"distribute","track":"beta","userFraction":"0.1"}')
        self.assertEqual((beta_track['destination'], beta_track['user_fraction']), ('play-beta', '0.1'))
        for fraction in ('0.1', '0.001', '0.0001'):
            with self.subTest(fraction=fraction):
                value = full('完整模式 / Full', 'Auto', uploaded,
                             json.dumps({'operation': 'distribute', 'track': 'internal', 'userFraction': fraction}))
                self.assertEqual(value['user_fraction'], fraction)
        for fraction in ('0.10', '1', '0.1000', '0'):
            with self.subTest(fraction=fraction):
                with self.assertRaises(ValueError):
                    full('完整模式 / Full', 'Auto', uploaded,
                         json.dumps({'operation': 'distribute', 'track': 'internal', 'userFraction': fraction}))
        alpha = receipt_for('alpha')
        with self.assertRaises(ValueError):
            full('完整模式 / Full', 'Auto', alpha, '{"operation":"upload","track":"beta"}')
        released = receipt_for()
        for track in ('internal', 'beta'):
            value = full('完整模式 / Full', 'Auto', released, json.dumps({'operation': 'upload', 'track': track}))
            self.assertEqual(value['track'], track)
        with self.assertRaises(ValueError):
            full('完整模式 / Full', 'Auto', released, '{"operation":"upload","track":"production"}')
        release_draft = receipt_for('release', '41', '43', draft=True)
        submitted = full('完整模式 / Full', 'Release', release_draft, '{"operation":"submit","track":"production"}')
        self.assertEqual(submitted['destination'], 'play-production')
        with self.assertRaises(ValueError):
            full('完整模式 / Full', 'Auto', uploaded, '{"operation":"submit","track":"production"}')
        with self.assertRaisesRegex(ValueError, 'successful Play upload'):
            full('完整模式 / Full', 'Auto', released, '{"operation":"submit","track":"production"}')
        with self.assertRaisesRegex(ValueError, 'successful Play upload'):
            full('完整模式 / Full', 'Beta', pinned, '{"operation":"distribute","track":"beta","userFraction":"0.1"}')
        drafted = full('仅打包 / Package', 'Release', f'{VERSION}({BUILD})', '{}')
        self.assertEqual(drafted['destination'], 'artifacts')
        candidate = full('完整模式 / Full', 'Release', f'{VERSION}({BUILD})', '{"operation":"draft"}')
        self.assertEqual(candidate['tag'], f'candidate/android/{VERSION}-release.{BUILD}')
        with self.assertRaises(ValueError):
            full('完整模式 / Full', 'Auto', f'{VERSION}({BUILD})', '{"operation":"package"}')
        with self.assertRaises(ValueError):
            full('完整模式 / Full', 'Release', f'{VERSION}({BUILD})', '{"operation":"package-upload"}')
        with self.assertRaises(ValueError):
            full('仅打包 / Package', 'Release', f'{VERSION}({BUILD})', '{}', attempt='2')

    def test_receipt_forms_and_entrypoint_json(self):
        same = receipt.decode(receipt_for())
        self.assertEqual(same['upload_run_id'], '')
        drafted = receipt.decode(receipt_for(draft=True))
        self.assertEqual(drafted['upload_run_id'], '41')
        with self.assertRaises(ValueError):
            receipt.decode('aegis-android-v2:release:7.2.0.339:2007000339:41:40:1:' + 'ab' * 32 + ':draft')
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / 'github.output'
            output.write_text('')
            environment = {'ANDROID_DELIVERY_INPUTS': '{"operation":"Status","version":"7.2.0.339","build":"2007000339","product":"Release"}',
                           'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/main',
                           'GITHUB_SHA': SHA, 'GITHUB_OUTPUT': str(output), 'ANDROID_DELIVERY_MODE': 'simple',
                           'GITHUB_RUN_ATTEMPT': '1'}
            previous = os.environ.copy()
            os.environ.update(environment)
            try:
                plan.main()
            finally:
                os.environ.clear()
                os.environ.update(previous)
            self.assertIn('"operation":"status-query"', output.read_text())
            output.write_text('')
            environment['ANDROID_DELIVERY_INPUTS'] = '{"operation":"Status","operation":"Wait"}'
            previous = os.environ.copy()
            os.environ.update(environment)
            try:
                with self.assertRaises(ValueError):
                    plan.main()
            finally:
                os.environ.clear()
                os.environ.update(previous)
            self.assertEqual(output.read_text(), '')


class PlayMatrix(unittest.TestCase):
    def test_generated_apk_identity_and_rejections(self):
        empty = play.interpret_generated_apks({'generatedApks': []}, 2007000339)
        self.assertEqual(empty['processingState'], 'PROCESSING')
        processing = play.interpret_generated_apks({'generatedApks': [{'certificateSha256Hash': 'key-1', 'generatedSplitApks': [{}]}]}, 2007000339)
        self.assertEqual(processing['uploadState'], 'PROCESSING')
        valid = play.interpret_generated_apks({'generatedApks': [{
            'certificateSha256Hash': 'key-1',
            'generatedUniversalApk': {'downloadId': 'u'},
            'generatedAssetPackSlices': [{'downloadId': 'pack'}],
            'generatedStandaloneApks': [{'downloadId': 'u'}],
        }]}, 2007000339)
        identity = play.canonical({'downloadIds': ['pack', 'u'], 'packageName': play.APPLICATION_ID, 'versionCode': 2007000339})
        self.assertEqual(valid['buildIdentitySha256'], __import__('hashlib').sha256(identity.encode()).hexdigest())
        with self.assertRaises(ValueError):
            play.interpret_generated_apks({'generatedApks': [None]}, 2007000339)
        with self.assertRaises(ValueError):
            play.draft_intent(VERSION, BUILD, 'release', 'ab' * 32, 'production')

    def test_transport_guards_and_token(self):
        calls = []

        def transport(method, url, body, headers):
            calls.append((method, url, body))
            if url.endswith('/generatedApks/2007000339'):
                return 302, {}, b''
            return 200, {}, b'{"access_token":"tok"}'

        with self.assertRaises(ValueError):
            play.Play(transport, 'token').status(2007000339)
        self.assertEqual(calls[0][0], 'GET')
        signer_calls = []
        token = play.access_token({'client_email': 'bot@aegis.gserviceaccount.com', 'private_key': 'PRIVATE KEY\n'},
                                  lambda *args: (200, {}, b'{"access_token":"tok"}'), 1_700_000_000,
                                  lambda unsigned, key: signer_calls.append(unsigned) or 'c2ln')
        self.assertEqual(token, 'tok')
        self.assertEqual(len(signer_calls), 1)
        with self.assertRaises(ValueError):
            play.access_token({'client_email': 'bot@example.com', 'private_key': 'PRIVATE KEY'},
                              lambda *args: (_ for _ in ()).throw(AssertionError('network')), 1, lambda *_: 'x')

    def test_real_transport_returns_redirect_without_following_it(self):
        requests = []

        class Redirect(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                if self.path == '/source':
                    self.send_response(302)
                    self.send_header('Location', '/redirected')
                else:
                    self.send_response(200)
                self.end_headers()

            def log_message(self, *args):
                pass

        with HTTPServer(('127.0.0.1', 0), Redirect) as server:
            worker = Thread(target=server.serve_forever)
            worker.start()
            try:
                url = f'http://127.0.0.1:{server.server_port}/source'
                with mock.patch.dict('os.environ', {'no_proxy': '127.0.0.1'}):
                    status, headers, _ = play.urllib_transport('GET', url, None, {'Authorization': 'Bearer fixture'})
            finally:
                server.shutdown()
                worker.join()
        self.assertEqual((status, headers['Location']), (302, '/redirected'))
        self.assertEqual(requests, ['/source'])


class ArchiveAndRecordMatrix(unittest.TestCase):
    def test_unsafe_members_and_record_replay(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            aab = root / 'app.aab'
            with zipfile.ZipFile(aab, 'w') as zipped:
                zipped.writestr('base/manifest/AndroidManifest.xml', b'not a bundle')
            with self.assertRaises(ValueError):
                archive.assert_aab(aab)
            symbols = root / 'symbols.zip'
            with zipfile.ZipFile(symbols, 'w') as zipped:
                zipped.writestr('README', b'no native code')
            with self.assertRaises(ValueError):
                archive.assert_symbols(symbols)
            bad = root / 'bad.zip'
            with zipfile.ZipFile(bad, 'w') as zipped:
                zipped.writestr('../escape.so', b'ELF')
            with self.assertRaises(ValueError):
                archive.extract_flat(bad, root / 'out')

        class Memory:
            def __init__(self):
                self.refs, self.commits = {}, {}

            def request(self, path, payload=None, missing=False):
                if path == '':
                    return {'id': 1348409663}
                if path == records.LEGACY_REFS:
                    return []
                if path == 'git/commits' and payload is not None:
                    digest = __import__('hashlib').sha1(payload['message'].encode()).hexdigest()
                    self.commits[digest] = payload
                    return {'sha': digest}
                if path == 'git/refs' and payload is not None:
                    key = payload['ref'].removeprefix('refs/')
                    self.refs[key] = {'ref': payload['ref'], 'object': {'type': 'commit', 'sha': payload['sha']}}
                    return self.refs[key]
                if path.startswith('git/ref/') and payload is None:
                    found = self.refs.get(path.removeprefix('git/ref/'))
                    return None if found is None and missing else found
                if path.startswith('git/commits/'):
                    digest = path.rsplit('/', 1)[1]
                    body = self.commits[digest]
                    return {'sha': digest, 'parents': [], 'tree': {'sha': body['tree']}, 'message': body['message']}
                raise AssertionError(path)

        api = Memory()
        store = records.Records(api, 1348409663, archive.APPLICATION_ID)
        with self.assertRaises(ValueError):
            records.Records(api, 1, archive.APPLICATION_ID)
        key = records.allocation(archive.APPLICATION_ID, VERSION, BUILD)
        self.assertEqual(key, records.allocation(archive.APPLICATION_ID, '7.3.0.339', BUILD))
        self.assertNotEqual(key, records.allocation(archive.APPLICATION_ID, VERSION, '2008000339'))
        payload = {'version': VERSION, 'build': BUILD}
        store.create('package', key, payload)
        with self.assertRaises(ValueError):
            store.create('package', key, {'version': VERSION})
        commit = next(iter(api.commits.values()))
        commit['message'] = commit['message'].replace('{', '{ ', 1)
        with self.assertRaises(ValueError):
            store.read('package', key)


def sealed_package(root):
    aab = root / 'app.aab'
    symbols = root / 'symbols.zip'
    with zipfile.ZipFile(aab, 'w') as zipped:
        zipped.writestr('BundleConfig.pb', b'bundle')
    with zipfile.ZipFile(symbols, 'w') as zipped:
        zipped.writestr('libchrome.so', b'ELF')
    names = archive.asset_names(VERSION, BUILD)
    manifest = {'schema': 'aegis-android-manifest-v1', 'repository': archive.REPOSITORY, 'platform': 'android',
                'applicationId': archive.APPLICATION_ID, 'profile': 'release', 'version': VERSION, 'build': BUILD,
                'source': {'sha': SHA, 'tree': TREE, 'dirty': False}, 'details': {'certificateSha256': 'cd' * 32},
                'assets': [{'name': names[0], 'size': aab.stat().st_size, 'sha256': archive.sha256(aab)},
                           {'name': names[1], 'size': symbols.stat().st_size, 'sha256': archive.sha256(symbols)}]}
    digest, origin = archive.seal(root / 'sealed', manifest,
                                  {'repository': archive.REPOSITORY, 'runId': 41, 'attempt': 1, 'sourceSha': SHA,
                                   'sourceTree': TREE, 'runIdLocal': 'android-gh-41-1'},
                                  {'schema': 'aegis-android-signature-v1', 'certificateSha256': 'cd' * 32,
                                   'artifactSha256': archive.sha256(aab)},
                                  {names[0]: aab, names[1]: symbols})
    return root / 'sealed', digest, origin


class DeliveryCommandMatrix(unittest.TestCase):
    def test_query_record_and_play_stage_matrix(self):
        admitted = simple('发布核对 / Release Wait', 'Release')
        delivery.validate_query(admitted)
        admitted['track'] = 'production'
        with self.assertRaises(ValueError):
            delivery.validate_query(admitted)
        with (tempfile.TemporaryDirectory() as temp,
              mock.patch.dict('os.environ', {'GITHUB_SHA': SHA, 'GITHUB_RUN_ID': '43', 'GITHUB_RUN_ATTEMPT': '1',
                                            'GITHUB_STEP_SUMMARY': str(Path(temp) / 'summary.md')}),
              mock.patch.object(delivery.release, '_assert_current_release_source') as verify_main,
              mock.patch.object(delivery.release, 'load_upload_run', return_value=evidence()['upload_run']) as get_run):
            root = Path(temp)
            summary = root / 'summary.md'
            directory, digest, origin = sealed_package(root)
            pending = {'origin': origin, 'profile': 'release', 'version': VERSION, 'build': BUILD, 'manifestSha256': digest}
            artifact = {'id': 70, 'digest': 'sha256:' + '11' * 32, 'name': 'android-package-41-1'}
            store = self._store()
            verify_main.side_effect = ValueError('Producer source is no longer current')
            with self.assertRaisesRegex(ValueError, 'no longer current'):
                delivery.record_package(pending, artifact, 11, store)
            self.assertIsNone(store.read('package', records.allocation(archive.APPLICATION_ID, VERSION, BUILD)))
            verify_main.side_effect = None
            delivery.record_package(pending, artifact, 11, store)
            self.assertEqual(delivery.record_package(pending, artifact, 11, store)['artifact_id'], 70)
            with self.assertRaises(ValueError):
                delivery.record_package(pending, {**artifact, 'id': 71}, 11, store)
            calls = []

            class Client:
                def upload_draft(self, aab, code, track, *, authorize_write):
                    authorize_write()
                    calls.append(('upload', track, code))
                    return {'status': 'uploaded_draft', 'packageName': archive.APPLICATION_ID,
                            'track': track, 'releaseStatus': 'draft', 'versionCode': code}

                def update_track(self, code, track, state, fraction, *, authorize_write):
                    authorize_write()
                    calls.append(('track', track, state, fraction))
                    return {'status': state, 'track': track}

            staged = {'operation': 'upload', 'profile': 'release', 'version': VERSION, 'build': BUILD, 'track': 'internal',
                      'package_run_id': '41', 'source_attempt': '1', 'manifest_sha256': digest}
            for invalid in ({'manifest_sha256': 'e' * 64}, {'source_attempt': '2'}, {'package_run_id': '42'}):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    delivery.play_stage({**staged, **invalid}, directory, Client(), store)
                self.assertIsNone(store.read('upload-start', records.allocation(archive.APPLICATION_ID, VERSION, BUILD)))
            marker = directory / 'package-origin.json'
            original = marker.read_bytes()
            marker.write_text(json.dumps({**origin, 'sourceTree': 'e' * 40}))
            with self.assertRaisesRegex(ValueError, 'approved producer'):
                delivery.play_stage(staged, directory, Client(), store)
            marker.write_bytes(original)
            self.assertEqual(calls, [])
            submitted = {**staged, 'operation': 'submit', 'track': 'production', 'upload_run_id': '43'}
            with self.assertRaisesRegex(ValueError, 'recorded Play upload'):
                delivery.play_stage(submitted, directory, Client(), store)
            verify_main.side_effect = ValueError('source is no longer current')
            with self.assertRaisesRegex(ValueError, 'no longer current'):
                delivery.play_stage(staged, directory, Client(), store)
            self.assertEqual(calls, [])
            verify_main.side_effect = None
            delivery.play_stage(staged, directory, Client(), store)
            self.assertEqual(calls, [('upload', 'internal', 2007000339)])
            target = summary.read_text().split('`')[1]
            self.assertEqual(receipt.decode(target)['upload_run_id'], '43')
            with self.assertRaises(ValueError):
                delivery.play_stage(staged, directory, Client(), store)
            for bad_run in ('', '44'):
                with self.assertRaisesRegex(ValueError, 'recorded Play upload'):
                    delivery.play_stage({**submitted, 'upload_run_id': bad_run}, directory, Client(), store)
            run = evidence()['upload_run']
            run['jobs'][0]['conclusion'] = 'skipped'
            get_run.return_value = run
            with self.assertRaisesRegex(ValueError, 'store'):
                delivery.play_stage(submitted, directory, Client(), store)
            self.assertEqual(len(calls), 1)
            get_run.return_value = evidence()['upload_run']
            delivery.play_stage({**submitted, 'operation': 'distribute', 'track': 'beta', 'user_fraction': '0.1'},
                                directory, Client(), store)
            delivery.play_stage(submitted, directory, Client(), store)
            self.assertEqual(calls[-2], ('track', 'beta', 'inProgress', '0.1'))
            self.assertEqual(calls[-1], ('track', 'production', 'completed', ''))

    def test_import_checks_exact_producer_before_downloading(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sealed, manifest_digest, origin = sealed_package(root)
            bundle = root / 'fixture.zip'
            archive.zip_flat(sealed, bundle)
            value = evidence()
            record = {**value['package_record'], 'origin': origin}
            run = value['package_run']
            store = mock.Mock()
            store.read.return_value = record
            approved = {'operation': 'upload', 'profile': 'release', 'version': VERSION, 'build': BUILD,
                        'package_run_id': '41', 'source_attempt': '1', 'manifest_sha256': manifest_digest}

            def download(run_id, artifact_id, destination, *, expected_digest):
                self.assertEqual((run_id, artifact_id, expected_digest), (41, 70, record['artifact_digest']))
                destination.write_bytes(bundle.read_bytes())

            with (mock.patch.dict('os.environ', {'GITHUB_RUN_ID': '42', 'GITHUB_SHA': SHA}),
                  mock.patch.object(delivery.release, '_get_run', return_value=run),
                  mock.patch.object(delivery.release, '_get_jobs', return_value=run['jobs']),
                  mock.patch.object(delivery.release, '_api', return_value={'sha': SHA, 'tree': {'sha': 'f' * 40}}) as api,
                  mock.patch.object(delivery.release, 'download_package_artifact', side_effect=download) as fetch):
                with mock.patch.dict('os.environ', {'GITHUB_SHA': 'c' * 40}):
                    with self.assertRaisesRegex(ValueError, 'admitted workflow source'):
                        delivery.import_package(approved, store, root / 'stale')
                fetch.assert_not_called()
                with self.assertRaisesRegex(ValueError, 'producer tree'):
                    delivery.import_package(approved, store, root / 'rejected')
                fetch.assert_not_called()
                api.return_value = {'sha': SHA, 'tree': {'sha': TREE}}
                run['status'] = 'in_progress'
                with self.assertRaisesRegex(ValueError, 'producer run identity'):
                    delivery.import_package(approved, store, root / 'unfinished')
                run.update(status='completed', conclusion='failure')
                run['jobs'][0]['conclusion'] = 'failure'
                with self.assertRaisesRegex(ValueError, 'Required job did not succeed'):
                    delivery.import_package(approved, store, root / 'failed-producer')
                fetch.assert_not_called()
                run['jobs'][0]['conclusion'] = 'success'
                manifest = delivery.import_package(approved, store, root / 'admitted')
                self.assertEqual(manifest['source'], {'sha': SHA, 'tree': TREE, 'dirty': False})
                self.assertEqual(fetch.call_count, 1)

    def test_oversized_archive_stops_before_pending_package_record(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sealed, _, _ = sealed_package(root)
            member_bytes = sum(path.stat().st_size for path in sealed.iterdir())
            identity = {'sha': SHA, 'tree': TREE, 'version': VERSION, 'build': BUILD}
            package_plan = {'profile': 'release', 'version': VERSION, 'build': BUILD}
            for limit, error in ((member_bytes - 1, 'members exceed'), (member_bytes, 'archive size limit')):
                with self.subTest(limit=limit):
                    release_root = root / str(limit)
                    (release_root / '.artifacts/android-delivery').mkdir(parents=True)
                    with (mock.patch.object(delivery, 'ROOT', release_root),
                          mock.patch.object(delivery.archive, 'MAX_MEMBER', limit)):
                        with self.assertRaisesRegex(ValueError, error):
                            delivery.seal_package(package_plan, identity, root / 'app.aab',
                                                  root / 'symbols.zip', 'cd' * 32, 41)
                    self.assertFalse((release_root / '.artifacts/android-delivery/package-pending.json').exists())

    def test_packaging_requires_current_source_and_builds_original_run_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            chromium = root / 'chromium'
            chromium.mkdir()
            old_bundle = root / 'unrelated.aab'
            old_bundle.write_bytes(b'not produced by this run')
            key = root / 'fixture.p12'
            key.touch()
            identity = {'sha': SHA, 'tree': TREE, 'version': VERSION, 'build': BUILD}
            env = {'GITHUB_SHA': SHA, 'GITHUB_RUN_ID': '41', 'GITHUB_RUN_ATTEMPT': '1',
                   'CHROMIUM_ROOT': str(chromium), 'AEGIS_ANDROID_CERT_SHA256': 'cd' * 32,
                   'AEGIS_ANDROID_KEYSTORE': str(key), 'AEGIS_ANDROID_KEY_ALIAS': 'fixture',
                   'AEGIS_ANDROID_AAB': str(old_bundle)}
            expected_out = chromium.resolve() / 'src/out/AegisAndroidDelivery-41-1'
            commands = []
            store = mock.Mock()
            store.read.return_value = None

            def run(command, **kwargs):
                commands.append(command)
                if command[0] == 'bash':
                    self.assertEqual(command[-2:], ['--app-bundle', 'alpha'])
                    out = chromium.resolve() / 'src/out' / f"AegisAndroidDelivery-{kwargs['env']['GITHUB_RUN_ID']}-1"
                    self.assertEqual(kwargs['env']['OUT_DIR'], str(out))
                    self.assertFalse(out.exists())
                    apks = out / 'apks'
                    apks.mkdir(parents=True)
                    with zipfile.ZipFile(apks / 'ChromePublic.aab', 'w') as output:
                        output.writestr('BundleConfig.pb', b'fixture')
                elif command[0] == 'jarsigner':
                    signed, unsigned = (Path(item) for item in command[-3:-1])
                    self.assertEqual(unsigned, expected_out / 'apks/ChromePublic.aab')
                    signed.write_bytes(unsigned.read_bytes())
                else:
                    self.fail(command[0])
                return mock.Mock(returncode=0)

            with (mock.patch.dict('os.environ', env), mock.patch.object(delivery, 'ROOT', root),
                  mock.patch.object(delivery, 'source_identity', return_value=identity) as read_source,
                  mock.patch.object(delivery.release, '_store', return_value=store),
                  mock.patch.object(delivery.release, '_assert_current_release_source') as check_main,
                  mock.patch.object(delivery, 'verify_bundle_manifest') as verify_manifest,
                  mock.patch.object(delivery.subprocess, 'run', side_effect=run),
                  mock.patch.object(delivery.verifier, 'certificate_sha256', return_value='cd' * 32)):
                plan = {'profile': 'alpha', 'version': VERSION, 'build': BUILD}
                read_source.return_value = {**identity, 'sha': 'f' * 40}
                with self.assertRaisesRegex(ValueError, 'checkout differs'):
                    delivery.build_and_seal(plan)
                self.assertEqual(commands, [])
                read_source.return_value = identity
                store.read.return_value = {'occupied': True}
                with self.assertRaisesRegex(ValueError, 'versionCode is already recorded'):
                    delivery.build_and_seal(plan)
                self.assertEqual(commands, [])
                store.read.return_value = None
                separate_tree = root / 'separate-source'
                separate_tree.mkdir()
                link = chromium / 'src'
                link.symlink_to(separate_tree, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, 'physical Chromium source'):
                    delivery.build_and_seal(plan)
                self.assertEqual(commands, [])
                link.unlink()
                sealed = delivery.build_and_seal(plan)
                self.assertEqual(sealed['origin']['sourceSha'], SHA)
                self.assertEqual(sealed['origin']['sourceTree'], TREE)
                self.assertEqual(sealed['origin']['runId'], 41)
                self.assertEqual([command[0] for command in commands], ['bash', 'jarsigner'])
                verify_manifest.assert_called_once_with(chromium.resolve(), expected_out / 'apks/ChromePublic.aab', BUILD)
                check_main.assert_called_once_with({'source': {'sha': SHA, 'tree': TREE}})
                check_main.side_effect = ValueError('Producer source is no longer current')
                with mock.patch.dict('os.environ', {'GITHUB_RUN_ID': '42'}):
                    with self.assertRaisesRegex(ValueError, 'no longer current'):
                        delivery.build_and_seal(plan)
                self.assertEqual([command[0] for command in commands], ['bash', 'jarsigner', 'bash'])

    def test_only_recorded_producer_output_is_retired(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            _, digest, origin = sealed_package(root)
            pending = root / '.artifacts/android-delivery/package-pending.json'
            pending.parent.mkdir(parents=True)
            pending.write_text(json.dumps({'origin': origin, 'version': VERSION, 'build': BUILD,
                                          'profile': 'release', 'manifestSha256': digest}))
            output = root / 'src/out/AegisAndroidDelivery-41-1'
            other = output.with_name('AegisAndroidDelivery-40-1')
            output.mkdir(parents=True)
            other.mkdir()
            marker = output / '.aegis-producer'
            marker.write_text(f'40\n{SHA}\n')
            store = self._store()
            env = {'CHROMIUM_ROOT': temp, 'GITHUB_RUN_ID': '41', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': SHA}
            with (mock.patch.dict('os.environ', env), mock.patch.object(delivery, 'ROOT', root),
                  mock.patch.object(delivery.release, '_assert_current_release_source'),
                  mock.patch.object(delivery.release, '_store', return_value=store)):
                with self.assertRaisesRegex(ValueError, 'until the sealed artifact is recorded'):
                    delivery.retire_producer_output()
                artifact = {'id': 70, 'digest': 'sha256:' + '11' * 32, 'name': 'android-package-41-1'}
                delivery.record_package(json.loads(pending.read_bytes()), artifact, 11, store)
                with self.assertRaisesRegex(ValueError, 'prove ownership'):
                    delivery.retire_producer_output()
                self.assertTrue(output.exists())
                marker.write_text(f'41\n{SHA}\n')
                delivery.retire_producer_output()
                self.assertFalse(output.exists())
                self.assertTrue(other.exists())

    def test_candidate_draft_revalidates_tag_and_release_between_assets(self):
        for change in ('retargeted', 'public'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                directory, digest, origin = sealed_package(root)
                tag = f'candidate/android/{VERSION}-release.{BUILD}'
                plan = {'operation': 'draft', 'destination': 'github-draft', 'tag': tag,
                        'version': VERSION, 'build': BUILD, 'profile': 'release'}
                remote = {'id': 9, 'tag_name': tag, 'draft': True, 'prerelease': True, 'assets': []}
                tag_sha = SHA

                def api(path):
                    if path.startswith('commits/refs%2Ftags%2Fcandidate%2Fandroid%2F'):
                        return {'sha': tag_sha}
                    self.assertEqual(path, 'releases/9')
                    return remote

                def upload(release_id, row):
                    nonlocal tag_sha
                    self.assertEqual(release_id, 9)
                    remote['assets'].append({'name': row['name'], 'state': 'uploaded', 'digest': 'sha256:' + row['sha256']})
                    if change == 'retargeted':
                        tag_sha = '3' * 40
                    else:
                        remote['draft'] = False

                store = self._store()
                pending = {'origin': origin, 'profile': 'release', 'version': VERSION, 'build': BUILD, 'manifestSha256': digest}
                artifact = {'id': 70, 'digest': 'sha256:' + '11' * 32, 'name': 'android-package-41-1'}
                env = {'GITHUB_RUN_ID': '41', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': SHA}
                with (mock.patch.dict('os.environ', env), mock.patch.object(delivery, 'ROOT', root),
                      mock.patch.object(delivery, 'git_output', return_value=SHA),
                      mock.patch.object(delivery.release, '_assert_current_release_source'),
                      mock.patch.object(delivery.release, '_store', return_value=store),
                      mock.patch.object(delivery.release, '_release_by_tag', return_value=remote),
                      mock.patch.object(delivery.release, '_api', side_effect=api),
                      mock.patch.object(delivery.release, '_upload_asset_once', side_effect=upload) as write):
                    delivery.record_package(pending, artifact, 11, store)
                    with self.assertRaisesRegex(ValueError, 'no longer'):
                        delivery.stage_draft(plan, directory)
                    write.assert_called_once()
                    self.assertFalse((root / '.artifacts/release/android' / BUILD / 'github-draft.json').exists())

    def test_bundle_manifest_checks_package_version_and_debuggable(self):
        with tempfile.TemporaryDirectory() as temp:
            chromium = Path(temp)
            jar = chromium / 'src/third_party/android_build_tools/bundletool/cipd/bundletool.jar'
            jar.parent.mkdir(parents=True)
            jar.touch()
            aab = chromium / 'app.aab'

            def manifest(package=archive.APPLICATION_ID, code=BUILD, debug='false'):
                return (f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                        f'package="{package}" android:versionCode="{code}">'
                        f'<application android:debuggable="{debug}"/></manifest>').encode()

            with mock.patch.object(delivery.subprocess, 'run', return_value=mock.Mock(stdout=manifest())) as run:
                delivery.verify_bundle_manifest(chromium, aab, BUILD)
                self.assertEqual(run.call_args.args[0][-2:], ['--bundle=' + str(aab), '--module=base'])
                for candidate, error in ((manifest(debug='true'), 'debuggable'),
                                         (manifest(code='2007000340'), 'versionCode'),
                                         (manifest(package='app.gcsa.fixture'), 'versionCode')):
                    run.return_value.stdout = candidate
                    with self.assertRaisesRegex(ValueError, error):
                        delivery.verify_bundle_manifest(chromium, aab, BUILD)

    def _store(self):
        parent = ArchiveAndRecordMatrix()
        api = parent.test_unsafe_members_and_record_replay.__func__ if False else None
        del api, parent

        class Memory:
            def __init__(self):
                self.refs, self.commits = {}, {}

            def request(self, path, payload=None, missing=False):
                if path == '':
                    return {'id': 1348409663}
                if path == records.LEGACY_REFS:
                    return []
                if path == 'git/commits' and payload is not None:
                    digest = __import__('hashlib').sha1(payload['message'].encode()).hexdigest()
                    self.commits[digest] = payload
                    return {'sha': digest}
                if path == 'git/refs' and payload is not None:
                    key = payload['ref'].removeprefix('refs/')
                    self.refs[key] = {'ref': payload['ref'], 'object': {'type': 'commit', 'sha': payload['sha']}}
                    return self.refs[key]
                if path.startswith('git/ref/') and payload is None:
                    found = self.refs.get(path.removeprefix('git/ref/'))
                    return None if found is None and missing else found
                if path.startswith('git/commits/'):
                    digest = path.rsplit('/', 1)[1]
                    body = self.commits[digest]
                    return {'sha': digest, 'parents': [], 'tree': {'sha': body['tree']}, 'message': body['message']}
                raise AssertionError(path)

        return records.Records(Memory(), 1348409663, archive.APPLICATION_ID)

    def test_status_document_and_draft_proof(self):
        remote = {'packageName': play.APPLICATION_ID, 'versionCode': 2007000339, 'processingState': 'NOT_FOUND',
                  'uploadState': 'NOT_FOUND', 'expired': False}
        document = status.status_document({'version': VERSION, 'build': BUILD}, remote,
                                          {'sha': SHA, 'tree': TREE}, 'status', '2026-11-19T00:00:00+00:00')
        self.assertEqual(document['queryMode'], 'status')
        self.assertFalse(document['packageProvenanceVerified'])
        with self.assertRaises(ValueError):
            status.status_document({'version': VERSION, 'build': BUILD}, remote, {'sha': SHA, 'tree': TREE},
                                   'rollout', '2026-11-19T00:00:00+00:00')
        name = archive.asset_names(VERSION, BUILD)[0]
        digest = 'ab' * 32
        proof = {'draft': True, 'tag': f'candidate/android/{VERSION}-release.{BUILD}', 'releaseId': 9, 'sha': SHA,
                 'assets': {name: digest}}
        asset = {'id': 10, 'name': name, 'size': 4, 'state': 'uploaded', 'digest': f'sha256:{digest}'}
        remote = {'id': 9, 'tag_name': proof['tag'], 'draft': True, 'prerelease': True, 'assets': [asset]}
        read = mock.Mock(return_value=(4, digest))
        self.assertTrue(drafts.verify(proof, remote, read)['draft'])
        read.assert_called_once_with(asset)
        for bad in ({**remote, 'draft': False}, {**remote, 'assets': []},
                    {**remote, 'assets': [asset, asset]},
                    {**remote, 'assets': [{**asset, 'digest': 'sha256:' + 'cd' * 32}]}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                drafts.verify(proof, bad, read)
        with self.assertRaisesRegex(ValueError, 'Downloaded'):
            drafts.verify(proof, remote, lambda asset: (4, 'cd' * 32))


def evidence():
    version, build = VERSION, BUILD
    aab, symbols_name = archive.asset_names(version, build)
    manifest = {'repository': release.REPOSITORY, 'platform': 'android', 'applicationId': release.APPLICATION_ID,
                'profile': 'release', 'version': version, 'build': build,
                'source': {'sha': SHA, 'tree': TREE, 'dirty': False},
                'details': {'certificateSha256': 'cd' * 32},
                'assets': [{'name': aab, 'size': 4, 'sha256': 'ab' * 32},
                           {'name': symbols_name, 'size': 4, 'sha256': 'ef' * 32}]}
    origin = {'repository': release.REPOSITORY, 'runId': 41, 'attempt': 1, 'sourceSha': SHA, 'sourceTree': TREE,
              'runIdLocal': 'android-gh-41-1', 'manifestSha256': 'cd' * 32}
    intent = play.draft_intent(version, build, 'release', 'cd' * 32, 'internal')

    def job(job_id, name, run_id):
        return {'id': job_id, 'name': name, 'run_id': run_id, 'run_attempt': 1, 'head_sha': SHA,
                'status': 'completed', 'conclusion': 'success'}

    def workflow(run_id, path, jobs):
        return {'id': run_id, 'run_attempt': 1, 'head_sha': SHA, 'head_branch': 'main', 'status': 'completed',
                'conclusion': 'success', 'event': 'workflow_dispatch', 'path': path,
                'repository': {'id': release.REPOSITORY_ID, 'full_name': release.REPOSITORY},
                'head_repository': {'id': release.REPOSITORY_ID, 'full_name': release.REPOSITORY}, 'jobs': jobs}

    return {'version': version, 'build': build,
            'repository': {'id': release.REPOSITORY_ID, 'full_name': release.REPOSITORY, 'default_branch': 'main'},
            'current_sha': SHA, 'current_tree': TREE,
            'package_run': workflow(41, '.github/workflows/android-delivery-full.yml', [job(11, 'delivery / package', 41)]),
            'upload_run': workflow(43, '.github/workflows/android-delivery-full.yml', [job(12, 'delivery / store', 43)]),
            'package_record': {'origin': origin, 'profile': 'release', 'version': version, 'build': build,
                               'package_job_id': 11, 'artifact_id': 70, 'artifact_name': 'android-package-41-1',
                               'artifact_digest': 'sha256:' + '11' * 32},
            'package_artifact': {'id': 70, 'name': 'android-package-41-1', 'expired': False, 'digest': 'sha256:' + '11' * 32},
            'manifest': manifest, 'manifest_sha256': 'cd' * 32, 'upload_start': intent,
            'upload_result': {'intent': intent, 'uploadRunId': 43, 'uploadRunAttempt': 1,
                              'result': {'status': 'uploaded_draft', 'packageName': release.APPLICATION_ID,
                                         'track': 'internal', 'releaseStatus': 'draft', 'versionCode': int(build)}},
            'status_run': workflow(42, '.github/workflows/android-delivery-full.yml', [job(21, 'delivery / query', 42)]),
            'status_artifact': {'id': 80, 'name': 'android-release-status-42-1', 'expired': False,
                                'digest': 'sha256:' + '22' * 32, 'run_id': 42},
            'status': {'platform': 'android', 'applicationId': release.APPLICATION_ID, 'version': version, 'build': build,
                       'queryMode': 'release-wait', 'readOnly': True, 'packageProvenanceVerified': False,
                       'querySource': {'sha': SHA, 'tree': TREE, 'dirty': False},
                       'remote': {'packageName': release.APPLICATION_ID, 'versionCode': int(build),
                                  'processingState': 'VALID', 'expired': False, 'uploadState': 'COMPLETE',
                                  'buildIdentitySha256': '33' * 32,
                                  'observedAt': datetime.now(timezone.utc).isoformat()}}}


class EvidenceMatrix(unittest.TestCase):
    def test_release_evidence_matrix(self):
        candidate = release.validate_delivery_evidence(evidence(), 'stable', 'prerelease')
        promoted = release.validate_delivery_evidence(evidence(), 'stable', 'stable')
        self.assertEqual(release.build_release_plan(candidate)['releaseIdentitySha256'],
                         release.build_release_plan(promoted, stable_release_id=500)['releaseIdentitySha256'])
        moved = evidence()
        moved['current_sha'] = '9' * 40
        with self.assertRaisesRegex(ValueError, 'current main'):
            release.validate_delivery_evidence(moved, 'stable', 'prerelease')
        self.assertEqual((candidate['packageRunId'], candidate['uploadRunId']), (41, 43))
        recovered = evidence()
        recovered['package_run']['conclusion'] = 'failure'
        self.assertEqual(release.validate_delivery_evidence(recovered, 'stable', 'prerelease')['packageRunId'], 41)
        mutations = [
            ('attempt', lambda value: value['package_run'].__setitem__('run_attempt', 2), 'identity'),
            ('skipped store', lambda value: value['upload_run']['jobs'][0].__setitem__('conclusion', 'skipped'), 'store'),
            ('wrong upload run', lambda value: value['upload_result'].__setitem__('uploadRunId', 44), 'upload run'),
            ('wrong version result', lambda value: value['upload_result']['result'].__setitem__('versionCode', 339), 'upload'),
            ('processing', lambda value: value['status']['remote'].__setitem__('processingState', 'PROCESSING'), 'VALID'),
            ('expired status', lambda value: value['status_artifact'].__setitem__('expired', True), 'artifact'),
            ('alpha profile', lambda value: value['package_record'].__setitem__('profile', 'alpha'), 'producer'),
            ('missing symbols', lambda value: value['manifest']['assets'].pop(), 'symbols|assets|manifest'),
            ('wrong track result', lambda value: value['upload_result']['result'].__setitem__('track', 'production'), 'upload'),
        ]
        for name, mutate, message in mutations:
            value = evidence()
            mutate(value)
            with self.subTest(name=name):
                with self.assertRaisesRegex(ValueError, message):
                    release.validate_delivery_evidence(value, 'stable', 'prerelease')

    def test_observation_window_and_archive_digests(self):
        now = datetime.now(timezone.utc)
        for observed in (now - timedelta(seconds=119), now - timedelta(seconds=1790), now + timedelta(seconds=119)):
            value = evidence()
            value['status']['remote']['observedAt'] = observed.isoformat()
            release.validate_delivery_evidence(value, 'stable', 'prerelease')
        for observed in (now + timedelta(seconds=121), now - timedelta(minutes=31)):
            value = evidence()
            value['status']['remote']['observedAt'] = observed.isoformat()
            with self.subTest(observed=observed.isoformat()):
                with self.assertRaisesRegex(ValueError, 'stale'):
                    release.validate_delivery_evidence(value, 'stable', 'prerelease')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            raw = io.BytesIO()
            with zipfile.ZipFile(raw, 'w') as zipped:
                zipped.writestr('package.zip', b'sealed')
                zipped.writestr('extra.json', b'{}')
            bundle = root / 'outer.zip'
            bundle.write_bytes(raw.getvalue())
            with self.assertRaises(ValueError):
                release.extract_verified_package_archive(bundle, root / 'package.zip', __import__('hashlib').sha256(bundle.read_bytes()).hexdigest())


class Publisher:
    def __init__(self, plan):
        self.plan = plan
        self.tag = None
        self.release = None
        self.mutations = []
        desired = json.loads((Path(__file__).resolve().parents[2] / release.TAG_RULESET).read_text())
        self.ruleset = {key: value for key, value in desired.items() if key != 'bypass_actors'}
        self.ruleset['id'] = 7
        self.ruleset['name'] = desired['name']
        self.environment = {'id': 901, 'can_admins_bypass': False,
                            'deployment_branch_policy': {'protected_branches': True},
                            'protection_rules': [{'type': 'required_reviewers', 'reviewers': [
                                {'type': 'User', 'reviewer': {'id': 2, 'login': 'Controller'}}]}]}
        self.approval = {'state': 'approved', 'comment': 'publish ' + plan['planSha256'],
                         'environments': [{'id': 901, 'name': release.PRODUCTION_ENVIRONMENT}],
                         'user': {'id': 2, 'login': 'Controller'}}

    def api(self, path, payload=None, method=None):
        if path.startswith('rulesets?') and payload is None:
            return [{'id': 7, 'name': self.ruleset['name']}]
        if path == 'rulesets/7':
            return self.ruleset
        if path.startswith('releases/tags/'):
            if self.release is None or self.release.get('draft') is True:
                raise release.NotFoundError(path)
            return self.release
        if path.startswith('releases?'):
            return [self.release] if self.release and self.release.get('draft') is True else []
        if path == 'releases' and payload is not None:
            self.mutations.append((path, payload))
            self.release = {'id': 500, 'assets': [], **payload}
            return self.release
        if path == 'releases/500' and method == 'PATCH':
            self.mutations.append((path, payload))
            self.release.update(payload)
            return self.release
        if path == 'releases/500':
            return self.release
        if path == 'releases/latest':
            return {'id': 700, 'tag_name': 'v7.2.0.339'}
        if path.startswith('git/ref/tags/'):
            if self.tag is None:
                raise release.NotFoundError(path)
            return {'object': {'type': 'tag', 'sha': self.tag['tag_sha']}}
        if path.startswith('git/tags/'):
            return {'message': self.tag['message'], 'object': {'sha': self.tag['target_sha'], 'type': 'commit'}}
        if path.startswith('environments/'):
            return self.environment
        if path.startswith('collaborators?'):
            return [{'id': 2, 'login': 'Controller', 'permissions': {'admin': True}}]
        if path == 'actions/runs/444/approvals':
            return [self.approval]
        raise AssertionError(path)

    def github(self, path, payload=None, missing=False):
        if path == 'git/tags':
            self.mutations.append((path, payload))
            self.tag = {'tag_sha': 'd' * 40, 'target_sha': payload['object'], 'message': payload['message']}
            return {'sha': 'd' * 40}
        if path == 'git/refs':
            self.mutations.append((path, payload))
            return {'ref': payload['ref'], 'object': {'sha': payload['sha']}}
        raise AssertionError(path)


class PublicationMatrix(unittest.TestCase):
    def setUp(self):
        self.original_api = release._api
        self.original_github = release.records.GitHub
        self.original_source = release._assert_current_release_source

    def tearDown(self):
        release._api = self.original_api
        release.records.GitHub = self.original_github
        release._assert_current_release_source = self.original_source

    def plans(self):
        candidate = release.validate_delivery_evidence(evidence(), 'stable', 'prerelease')
        stable = release.validate_delivery_evidence(evidence(), 'stable', 'stable')
        return release.build_release_plan(candidate), release.build_release_plan(stable, stable_release_id=500)

    def bind(self, state):
        release._api = state.api
        release._assert_current_release_source = lambda plan: None

        class GitHub:
            def __init__(self, repository):
                if repository != release.REPOSITORY:
                    raise AssertionError(repository)

            def request(self, path, payload=None, missing=False):
                return state.github(path, payload, missing)

        release.records.GitHub = GitHub

    def test_prerelease_then_promote_and_reject_early_stable(self):
        prerelease, stable = self.plans()
        self.assertEqual(prerelease['tag'], stable['tag'])
        self.assertNotEqual(prerelease['planSha256'], stable['planSha256'])
        self.assertTrue(prerelease['prerelease'])
        self.assertFalse(prerelease['makeLatest'])
        self.assertFalse(stable['makeLatest'])
        state = Publisher(stable)
        self.bind(state)
        assets = [{'name': name, 'size': 4, 'sha256': digest, 'path': '/tmp/' + name} for name, digest in prerelease['assets'].items()]

        def upload(release_id, asset):
            self.assertEqual(release_id, 500)
            self.assertTrue(state.release['draft'])
            state.release['assets'].append({'name': asset['name'], 'state': 'uploaded', 'digest': 'sha256:' + asset['sha256']})

        with mock.patch.object(release, '_upload_asset_once', side_effect=upload):
            with mock.patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': stable['planSha256'], 'GITHUB_RUN_ID': '444',
                                                'AEGIS_ANDROID_GITHUB_RELEASE_ADMIN_IDS': '2'}):
                with self.assertRaisesRegex(ValueError, 'prerelease'):
                    release.publish_release(stable, assets)
            self.assertIsNone(state.release)
            with mock.patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': prerelease['planSha256'], 'GITHUB_RUN_ID': '444'}):
                release.publish_release(prerelease, assets)
                release.publish_release(prerelease, assets)
            self.assertFalse(state.release['draft'])
            self.assertTrue(state.release['prerelease'])
            self.assertEqual({item['name'] for item in state.release['assets']}, set(prerelease['assets']))
            with mock.patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': stable['planSha256'], 'GITHUB_RUN_ID': '444',
                                                'AEGIS_ANDROID_GITHUB_RELEASE_ADMIN_IDS': '2'}):
                preview = release.preview_release(stable)
                self.assertTrue(preview['existingRelease'])
                release.publish_release(stable, assets)
                release.publish_release(stable, assets)
        self.assertFalse(state.release['prerelease'])
        self.assertEqual(state.release['name'], stable['name'])
        self.assertEqual(sum(path == 'git/tags' for path, _payload in state.mutations), 1)
        promotions = [payload for path, payload in state.mutations
                      if path == 'releases/500' and payload.get('prerelease') is False]
        self.assertEqual(promotions, [{'name': stable['name'], 'body': stable['body'], 'draft': False,
                                       'prerelease': False, 'make_latest': 'false'}])

    def test_same_tag_and_assets_replacement_requires_new_stable_approval(self):
        prerelease, stable = self.plans()
        state = Publisher(stable)
        self.bind(state)
        state.tag = {'tag_sha': 'd' * 40, 'target_sha': SHA, 'message': release._expected_tag_message(prerelease)}
        assets = [{'name': name, 'size': 4, 'sha256': digest} for name, digest in stable['assets'].items()]
        state.release = {'id': 500, 'tag_name': prerelease['tag'], 'draft': False, 'prerelease': True,
                         'name': prerelease['name'], 'body': prerelease['body'],
                         'assets': [{'name': asset['name'], 'state': 'uploaded', 'digest': 'sha256:' + asset['sha256']}
                                    for asset in assets]}
        candidate = release.validate_delivery_evidence(evidence(), 'stable', 'stable')
        with (tempfile.TemporaryDirectory() as temp,
              mock.patch.dict('os.environ', {'GITHUB_OUTPUT': '', 'GITHUB_STEP_SUMMARY': str(Path(temp) / 'summary'),
                                             'GITHUB_RUN_ID': '444', 'AEGIS_ANDROID_GITHUB_RELEASE_ADMIN_IDS': '2'})):
            approved = release._write_plan(candidate, assets, Path(temp) / 'plan.json')
            self.assertEqual(approved['releaseId'], 500)
            self.assertIn('GitHub Release ID: `500`', (Path(temp) / 'summary').read_text())
            self.assertTrue(release.preview_release(approved)['existingRelease'])
            state.approval['comment'] = 'publish ' + approved['planSha256']
            state.release = {**state.release, 'id': 501}
            replacement = release._write_plan(candidate, assets, None)
            self.assertEqual(replacement['releaseId'], 501)
            with self.assertRaisesRegex(ValueError, 'Release ID changed'):
                release.preview_release(approved)
            with mock.patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': approved['planSha256']}):
                with self.assertRaisesRegex(ValueError, 'Post-approval evidence differs'):
                    release.publish_release(replacement, assets)
                with self.assertRaisesRegex(ValueError, 'Release ID differs'):
                    release.publish_release(approved, assets)
        self.assertTrue(state.release['prerelease'])
        self.assertEqual(state.mutations, [])

    def test_stale_observation_does_not_create_a_release(self):
        prerelease, _stable = self.plans()
        prerelease['playObservedAt'] = '2020-01-01T00:00:00+00:00'
        state = Publisher(prerelease)
        state.tag = {'tag_sha': 'd' * 40, 'target_sha': SHA, 'message': release._expected_tag_message(prerelease)}
        self.bind(state)
        with mock.patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': prerelease['planSha256']}):
            with self.assertRaisesRegex(ValueError, 'stale'):
                release.publish_release(prerelease, [])
        self.assertNotIn('releases', [path for path, _payload in state.mutations])

    def test_prerelease_revalidates_draft_and_tag_before_each_asset_write(self):
        for change, error in (('published', 'draft moved'), ('retargeted', 'tag conflicts')):
            with self.subTest(change=change):
                prerelease, _stable = self.plans()
                state = Publisher(prerelease)
                self.bind(state)
                assets = [{'name': name, 'sha256': digest} for name, digest in prerelease['assets'].items()]

                def upload(release_id, asset):
                    self.assertEqual(release_id, 500)
                    state.release['assets'].append({'name': asset['name'], 'state': 'uploaded',
                                                    'digest': 'sha256:' + asset['sha256']})
                    if change == 'published':
                        state.release['draft'] = False
                    else:
                        state.tag['target_sha'] = '3' * 40

                with (mock.patch.object(release, '_upload_asset_once', side_effect=upload) as write,
                      mock.patch.dict('os.environ', {'EXPECTED_PLAN_SHA256': prerelease['planSha256']})):
                    with self.assertRaisesRegex(ValueError, error):
                        release.publish_release(prerelease, assets)
                write.assert_called_once()
                self.assertNotIn('releases/500', [path for path, _payload in state.mutations])

    def test_approval_and_ruleset_matrix(self):
        _prerelease, stable = self.plans()
        state = Publisher(stable)
        self.bind(state)
        with mock.patch.dict('os.environ', {'AEGIS_ANDROID_GITHUB_RELEASE_ADMIN_IDS': '2', 'GITHUB_RUN_ID': '444'}):
            release._check_approval(stable, 444)
            state.approval['comment'] = 'approved'
            with self.assertRaisesRegex(ValueError, 'exact plan digest'):
                release._check_approval(stable, 444)
            state.approval['comment'] = 'publish ' + stable['planSha256']
            state.environment['can_admins_bypass'] = True
            with self.assertRaisesRegex(ValueError, 'admin bypass'):
                release._production_environment_config()
            state.environment['can_admins_bypass'] = False
            state.environment['protection_rules'][0]['reviewers'].append({'type': 'Team', 'reviewer': {'id': 9}})
            with self.assertRaisesRegex(ValueError, 'User reviewers'):
                release._production_environment_config()
        state.ruleset['rules'] = [{'type': 'creation'}, {'type': 'update'}, {'type': 'deletion'}]
        with self.assertRaisesRegex(ValueError, 'creation|update/deletion'):
            release._verify_tag_ruleset()
        state.ruleset.pop('rules')
        with self.assertRaises(ValueError):
            release._verify_tag_ruleset()


if __name__ == '__main__':
    unittest.main()
