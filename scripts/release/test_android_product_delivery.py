import hashlib
import importlib.util
from pathlib import Path
import unittest


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


records = load('android_product_delivery', 'android_product_delivery.py')


class MemoryApi:
    def __init__(self):
        self.refs = {}
        self.commits = {}

    def request(self, path, payload=None, missing=False):
        if path == '':
            return {'id': 1348409663}
        if path == records.LEGACY_REFS:
            return [value for name, value in self.refs.items() if name.startswith('heads/android-delivery/')]
        if path == 'git/commits' and payload is not None:
            sha = hashlib.sha1(payload['message'].encode()).hexdigest()
            self.commits[sha] = payload
            return {'sha': sha}
        if path == 'git/refs' and payload is not None:
            key = payload['ref'].removeprefix('refs/')
            self.refs[key] = {'ref': payload['ref'], 'object': {'type': 'commit', 'sha': payload['sha']}}
            return self.refs[key]
        if path.startswith('git/ref/') and payload is None:
            found = self.refs.get(path.removeprefix('git/ref/'))
            if found is None and missing:
                return None
            return found
        if path.startswith('git/commits/'):
            sha = path.rsplit('/', 1)[1]
            body = self.commits[sha]
            return {'sha': sha, 'parents': [], 'tree': {'sha': body['tree']}, 'message': body['message']}
        raise AssertionError(path)


class RecordTests(unittest.TestCase):
    def test_allocation_is_stable_and_application_bound(self):
        first = records.allocation('com.gcsa.aegis', '7.2.0.339', '2007000339')
        self.assertEqual(first, records.allocation('com.gcsa.aegis', '7.2.0.339', '2007000339'))
        self.assertEqual(len(first), 64)
        with self.assertRaises(ValueError):
            records.allocation('app.other', '7.2.0.339', '2007000339')

    def test_create_is_once_and_readback_matches(self):
        api = MemoryApi()
        store = records.Records(api, 1348409663, 'com.gcsa.aegis')
        key = records.allocation('com.gcsa.aegis', '7.2.0.339', '2007000339')
        payload = {'version': '7.2.0.339', 'build': '2007000339'}
        self.assertIsNone(store.read('package', key))
        self.assertEqual(store.create('package', key, payload), payload)
        self.assertEqual(store.read('package', key), payload)
        with self.assertRaises(ValueError):
            store.create('package', key, payload)
        self.assertEqual(len(api.refs), 1)
        self.assertTrue(next(iter(api.refs)).startswith('heads/android-delivery-v2/package/'))

    def test_existing_or_late_legacy_reservation_blocks_new_allocation(self):
        api = MemoryApi()
        store = records.Records(api, 1348409663, records.APPLICATION_ID)
        legacy_ref = 'heads/android-delivery/upload-start/' + 'a' * 64
        api.refs[legacy_ref] = {'ref': 'refs/' + legacy_ref}
        key = records.allocation(records.APPLICATION_ID, '7.2.0.339', '2007000339')
        with self.assertRaisesRegex(ValueError, 'require reconciliation'):
            records.Records(api, 1348409663, records.APPLICATION_ID)
        with self.assertRaisesRegex(ValueError, 'require reconciliation'):
            store.create('package', key, {'build': '2007000339'})
        self.assertEqual(list(api.refs), [legacy_ref])
        self.assertEqual(api.commits, {})


if __name__ == '__main__':
    unittest.main()
