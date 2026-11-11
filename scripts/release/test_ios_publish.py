import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ios_publish', Path(__file__).with_name('ios-publish.py'))
catalogue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalogue)


class IosCatalogueTests(unittest.TestCase):
    def package(self, root):
        payload = root / 'app.ipa'
        payload.write_bytes(b'IPA fixture')
        value = dict(repository='gcsagroup/aegis-browser', platform='ios', version='1.0.0',
                     build='20', profile='alpha', source=dict(sha='a' * 40, tree='b' * 40, dirty=False),
                     assets=[dict(name='app.ipa', size=payload.stat().st_size,
                                  sha256=hashlib.sha256(payload.read_bytes()).hexdigest())])
        raw = json.dumps(value).encode()
        (root / 'ios-manifest.json').write_bytes(raw)
        digest = hashlib.sha256(raw).hexdigest()
        (root / 'ios-manifest.json.sha256').write_text(digest + '  ios-manifest.json\n')
        (root / 'AuthKey_fixture.p8').write_text('synthetic forbidden extra')
        (root / 'work').mkdir()
        return digest

    def test_catalogue_requires_the_retained_manifest_and_copies_only_delivery_members(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'package'
            source.mkdir()
            digest = self.package(source)
            with self.assertRaises(ValueError):
                catalogue.collect(source, '0' * 64, root / 'out')
            result = catalogue.collect(source, digest, root / 'out', draft=True)
            self.assertEqual(len(result), 3)
            self.assertTrue(all(Path(path).parent.name == 'Draft' for path in result))
            self.assertFalse(any('AuthKey' in path for path in result))

    def test_post_verification_modification_cannot_be_copied_with_a_newly_computed_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'package'
            source.mkdir()
            digest = self.package(source)
            original_publish = catalogue.publish
            def changed(*args, **kwargs):
                (source / 'app.ipa').write_bytes(b'modified after verification')
                return original_publish(*args, **kwargs)
            with patch.object(catalogue, 'publish', side_effect=changed), self.assertRaises(ValueError):
                catalogue.collect(source, digest, root / 'out')


if __name__ == '__main__':
    unittest.main()
