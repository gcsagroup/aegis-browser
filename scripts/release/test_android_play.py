import importlib.util
import json
from pathlib import Path
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


play = load('android_play', 'android-play.py')
CODE = 2007000339


class PlayTests(unittest.TestCase):
    def test_generated_apk_states(self):
        missing = play.interpret_generated_apks({'generatedApks': []}, CODE)
        self.assertEqual(missing['processingState'], 'NOT_FOUND')
        processing = play.interpret_generated_apks({'generatedApks': [{'versionCode': CODE, 'generatedSplitApks': []}]}, CODE)
        self.assertEqual(processing['processingState'], 'PROCESSING')
        valid = play.interpret_generated_apks({'generatedApks': [{
            'versionCode': CODE,
            'generatedUniversalApk': {'downloadId': 'universal'},
            'generatedSplitApks': [{'downloadId': 'base'}, {'downloadId': 'base'}],
        }]}, CODE)
        self.assertEqual(valid['uploadState'], 'COMPLETE')
        identity = play.canonical({'downloadIds': ['base', 'universal'], 'packageName': play.APPLICATION_ID, 'versionCode': CODE})
        self.assertEqual(valid['buildIdentitySha256'], __import__('hashlib').sha256(identity.encode()).hexdigest())

    def test_draft_upload_sequence(self):
        calls = []

        def transport(method, url, body, headers):
            calls.append((method, url, body))
            if url.endswith(f'/generatedApks/{CODE}'):
                return 200, {}, b'{"generatedApks":[]}'
            if url.endswith('/edits'):
                return 200, {}, b'{"id":"edit-1"}'
            if '/bundles?' in url:
                return 200, {}, json.dumps({'versionCode': CODE}).encode()
            return 200, {}, b'{}'

        client = play.Play(transport, 'token')
        with self.assertRaises(ValueError):
            client.upload_draft('bundle.aab', CODE, 'production')
        self.assertEqual(calls, [])
        calls.clear()
        result = client.upload_draft(Path(__file__), CODE, 'internal')
        self.assertEqual(result['status'], 'uploaded_draft')
        self.assertEqual([item[0] for item in calls], ['GET', 'POST', 'POST', 'PUT', 'POST'])
        self.assertTrue(calls[0][1].endswith(f'/generatedApks/{CODE}'))
        self.assertIn(b'"track":"internal"', calls[3][2])
        self.assertIn(b'"status":"draft"', calls[3][2])
        occupied = play.Play(lambda *args: (200, {}, json.dumps({'generatedApks': [{'versionCode': CODE}]}).encode()), 'token')
        with self.assertRaises(ValueError):
            occupied.upload_draft(Path(__file__), CODE, 'internal')

    def test_user_fraction_is_a_json_number(self):
        calls = []

        def transport(method, url, body, headers):
            calls.append(body)
            if url.endswith(f'/generatedApks/{CODE}'):
                return 200, {}, json.dumps({'generatedApks': [{'versionCode': CODE, 'generatedUniversalApk': {'downloadId': 'u'}}]}).encode()
            if url.endswith('/edits'):
                return 200, {}, b'{"id":"edit-2"}'
            return 200, {}, b'{}'

        play.Play(transport, 'token').update_track(CODE, 'internal', 'inProgress', '0.1')
        self.assertIn(b'"userFraction":0.1', calls[2])
        self.assertNotIn(b'"userFraction":"0.1"', calls[2])
        with self.assertRaises(ValueError):
            play.Play(transport, 'token').update_track(CODE, 'internal', 'inProgress', '0.10')

    def test_status_maps_missing_version_code_to_not_found(self):
        calls = []

        def transport(method, url, body, headers):
            calls.append((method, url))
            if url.endswith(f'/generatedApks/{CODE}'):
                return 404, {}, b'{"error":{"code":404,"message":"missing"}}'
            raise AssertionError(url)

        remote = play.Play(transport, 'token').status(CODE)
        self.assertEqual(remote['processingState'], 'NOT_FOUND')
        self.assertEqual(remote['versionCode'], CODE)
        self.assertTrue(calls[0][1].endswith(f'/generatedApks/{CODE}'))

    def test_signing_key_rows_without_version_code_are_aggregated(self):
        document = {'generatedApks': [
            {'generatedUniversalApk': {'downloadId': 'u1'}},
            {'generatedSplitApks': [{'downloadId': 's1'}]},
        ]}
        valid = play.interpret_generated_apks(document, CODE)
        self.assertEqual(valid['processingState'], 'VALID')
        identity = play.canonical({'downloadIds': ['s1', 'u1'], 'packageName': play.APPLICATION_ID, 'versionCode': CODE})
        self.assertEqual(valid['buildIdentitySha256'], __import__('hashlib').sha256(identity.encode()).hexdigest())

    def test_asset_pack_slices_are_part_of_the_build_identity(self):
        document = {'generatedApks': [
            {'generatedSplitApks': [{'downloadId': 's1'}],
             'generatedAssetPackSlices': [{'moduleName': 'pack', 'downloadId': 'p1'}]},
        ]}
        valid = play.interpret_generated_apks(document, CODE)
        self.assertEqual(valid['processingState'], 'VALID')
        identity = play.canonical({'downloadIds': ['p1', 's1'], 'packageName': play.APPLICATION_ID, 'versionCode': CODE})
        self.assertEqual(valid['buildIdentitySha256'], __import__('hashlib').sha256(identity.encode()).hexdigest())
        only_slices = play.interpret_generated_apks({'generatedApks': [{'generatedAssetPackSlices': [{'downloadId': 'p1'}]}]}, CODE)
        self.assertEqual(only_slices['processingState'], 'VALID')

    def test_automatic_protection_apks_are_part_of_the_build_identity(self):
        document = {'generatedApks': [
            {'generatedSplitApks': [{'downloadId': 's1'}],
             'unprotectedGeneratedSplitApks': [{'downloadId': 'us1'}],
             'unprotectedGeneratedStandaloneApks': [{'downloadId': 'ua1'}]},
        ]}
        valid = play.interpret_generated_apks(document, CODE)
        self.assertEqual(valid['processingState'], 'VALID')
        identity = play.canonical({'downloadIds': ['s1', 'ua1', 'us1'], 'packageName': play.APPLICATION_ID, 'versionCode': CODE})
        self.assertEqual(valid['buildIdentitySha256'], __import__('hashlib').sha256(identity.encode()).hexdigest())
        only_unprotected = play.interpret_generated_apks({'generatedApks': [{'unprotectedGeneratedSplitApks': [{'downloadId': 'us1'}]}]}, CODE)
        self.assertEqual(only_unprotected['processingState'], 'VALID')


if __name__ == '__main__':
    unittest.main()
