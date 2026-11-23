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


def authorize_fixture():
    pass


class PlayTests(unittest.TestCase):
    def test_generated_apk_states(self):
        missing = play.Play(lambda *args: (404, {}, b'{}'), 'token').status(CODE)
        self.assertEqual(missing['processingState'], 'NOT_FOUND')
        self.assertEqual(play.interpret_generated_apks({}, CODE)['processingState'], 'PROCESSING')
        processing = play.interpret_generated_apks({'generatedApks': [{'certificateSha256Hash': 'key-1', 'generatedSplitApks': []}]}, CODE)
        self.assertEqual(processing['processingState'], 'PROCESSING')
        valid = play.interpret_generated_apks({'generatedApks': [{
            'certificateSha256Hash': 'key-1',
            'generatedUniversalApk': {'downloadId': 'universal'},
        }, {
            'certificateSha256Hash': 'key-2',
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
                return 404, {}, b'{}'
            if url.endswith('/edits'):
                return 200, {}, b'{"id":"edit-1"}'
            if '/bundles?' in url:
                return 200, {}, json.dumps({'versionCode': CODE}).encode()
            return 200, {}, b'{}'

        client = play.Play(transport, 'token')
        with self.assertRaises(ValueError):
            client.upload_draft('bundle.aab', CODE, 'production', authorize_write=authorize_fixture)
        self.assertEqual(calls, [])
        calls.clear()
        result = client.upload_draft(Path(__file__), CODE, 'internal', authorize_write=authorize_fixture)
        self.assertEqual(result['status'], 'uploaded_draft')
        self.assertEqual([item[0] for item in calls], ['GET', 'POST', 'POST', 'PUT', 'POST'])
        self.assertTrue(calls[0][1].endswith(f'/applications/{play.APPLICATION_ID}/generatedApks/{CODE}'))
        self.assertIn(b'"track":"internal"', calls[3][2])
        self.assertIn(b'"status":"draft"', calls[3][2])
        occupied = play.Play(lambda *args: (200, {}, json.dumps({'generatedApks': [{'certificateSha256Hash': 'key-1'}]}).encode()), 'token')
        with self.assertRaises(ValueError):
            occupied.upload_draft(Path(__file__), CODE, 'internal', authorize_write=authorize_fixture)

    def test_user_fraction_is_a_json_number(self):
        calls = []

        def transport(method, url, body, headers):
            calls.append(body)
            if url.endswith(f'/generatedApks/{CODE}'):
                return 200, {}, json.dumps({'generatedApks': [{'certificateSha256Hash': 'key-1', 'generatedUniversalApk': {'downloadId': 'u'}}]}).encode()
            if url.endswith('/edits'):
                return 200, {}, b'{"id":"edit-2"}'
            return 200, {}, b'{}'

        play.Play(transport, 'token').update_track(CODE, 'internal', 'inProgress', '0.1',
                                                  authorize_write=authorize_fixture)
        self.assertIn(b'"userFraction":0.1', calls[2])
        self.assertNotIn(b'"userFraction":"0.1"', calls[2])
        with self.assertRaises(ValueError):
            play.Play(transport, 'token').update_track(CODE, 'internal', 'inProgress', '0.10',
                                                      authorize_write=authorize_fixture)

    def test_main_change_during_play_edit_blocks_remaining_writes(self):
        for action in ('upload', 'production'):
            with self.subTest(action=action):
                requests = []
                current = True

                def authorize():
                    if not current:
                        raise ValueError('Source is no longer current')

                def transport(method, url, body, headers):
                    nonlocal current
                    requests.append((method, url))
                    if method == 'GET':
                        if action == 'upload':
                            return 404, {}, b'{}'
                        return 200, {}, json.dumps({'generatedApks': [{
                            'certificateSha256Hash': 'key',
                            'generatedUniversalApk': {'downloadId': 'u'},
                        }]}).encode()
                    if url.endswith('/edits'):
                        return 200, {}, b'{"id":"fixture"}'
                    if '/bundles?' in url or method == 'PUT':
                        current = False
                        return 200, {}, json.dumps({'versionCode': CODE}).encode()
                    self.fail('Stale Play edit attempted another mutation')

                client = play.Play(transport, 'token')
                with self.assertRaisesRegex(ValueError, 'no longer current'):
                    if action == 'upload':
                        client.upload_draft(Path(__file__), CODE, 'internal', authorize_write=authorize)
                    else:
                        client.update_track(CODE, 'production', 'completed', authorize_write=authorize)
                self.assertEqual([method for method, _ in requests],
                                 ['GET', 'POST', 'POST' if action == 'upload' else 'PUT'])


if __name__ == '__main__':
    unittest.main()
