import hashlib
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor

from product_delivery import EMPTY_TREE, Records, allocation, canonical


class FakeGitHub:
    def __init__(self):
        self.refs, self.commits = {}, {}
        self.lock = threading.Lock()
        self.lose_ack = False

    def request(self, path, payload=None, missing=False):
        if path == '':
            return {'id': 123}
        if path.startswith('git/ref/'):
            return self.refs.get(path[len('git/ref/'):])
        if path.startswith('git/commits/'):
            return self.commits[path.rsplit('/', 1)[1]]
        if path == 'git/commits':
            sha = hashlib.sha1(canonical(payload).encode()).hexdigest()
            self.commits[sha] = dict(sha=sha, message=payload['message'],
                                     parents=[], tree={'sha': payload['tree']})
            return {'sha': sha}
        if path == 'git/refs':
            key = payload['ref'][len('refs/'):]
            with self.lock:
                if key in self.refs:
                    raise ValueError('conflict')
                self.refs[key] = dict(ref=payload['ref'], object={'type': 'commit', 'sha': payload['sha']})
            if self.lose_ack:
                raise ValueError('lost acknowledgement')
            return self.refs[key]
        raise AssertionError(path)


class ProductDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeGitHub()
        self.store = Records(self.api, 123, '456')
        self.key = allocation('456', '1.0', '20')

    def test_version_aliases_and_channel_changes_cannot_allocate_again(self):
        self.assertEqual(self.key, allocation('456', '1.0.0', '20'))
        self.store.create('upload-start', self.key, {'profile': 'alpha'})
        with self.assertRaises(ValueError):
            self.store.create('upload-start', allocation('456', '1.0.0', '20'), {'profile': 'beta'})
        self.assertEqual(self.store.read('upload-start', self.key), {'profile': 'alpha'})
        for bad in ['1x0', '1.0x0', '1.0;echo', '1.0.0.0']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                allocation('456', bad, '20')

    def test_readback_binds_product_kind_and_original_bytes(self):
        payload = {'source': 'a' * 40, 'manifest_sha256': 'b' * 64}
        self.store.create('package', self.key, payload)
        self.assertEqual(self.store.read('package', self.key), payload)
        with self.assertRaises(ValueError):
            Records(self.api, 124, '456')
        with self.assertRaises(ValueError):
            Records(self.api, 123, 'different-app').read('package', self.key)
        commit = next(iter(self.api.commits.values()))
        commit['tree']['sha'] = 'c' * 40
        with self.assertRaises(ValueError):
            self.store.read('package', self.key)

    def test_lost_write_acknowledgement_never_grants_transport_or_a_fresh_intent(self):
        self.api.lose_ack = True
        with self.assertRaises(ValueError):
            self.store.create('upload-start', self.key, {'ipa': 'a' * 64})
        self.api.lose_ack = False
        restarted = Records(self.api, 123, '456')
        self.assertEqual(restarted.read('upload-start', self.key), {'ipa': 'a' * 64})
        with self.assertRaises(ValueError):
            restarted.create('upload-start', self.key, {'ipa': 'a' * 64})

    def test_concurrent_uploads_have_one_create_only_winner(self):
        def start(_):
            try:
                self.store.create('upload-start', self.key, {'ipa': 'a' * 64})
                return 'transport-permitted'
            except ValueError:
                return 'blocked'
        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(start, [1, 2]))
        self.assertEqual(sorted(results), ['blocked', 'transport-permitted'])
        self.assertEqual(len(self.api.refs), 1)

    def test_orphan_commit_message_must_be_canonical(self):
        self.store.create('export-start', self.key, {'build': '20'})
        commit = next(iter(self.api.commits.values()))
        self.assertEqual(commit['tree']['sha'], EMPTY_TREE)
        commit['message'] += '\n'
        with self.assertRaises(ValueError):
            self.store.read('export-start', self.key)


if __name__ == '__main__':
    unittest.main()
