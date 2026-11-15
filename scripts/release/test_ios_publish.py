import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('ios_publish', Path(__file__).with_name('ios-publish.py'))
catalogue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalogue)


class IosCatalogueTests(unittest.TestCase):
    def package(self, root, resource=None, private=False):
        payload = root / 'app.ipa'
        with zipfile.ZipFile(payload, 'w') as archive:
            archive.writestr('Payload/Aegis.app/Info.plist', 'fixture')
            if resource:
                archive.writestr('Payload/Aegis.app/' + resource, 'private fixture')
        value = dict(repository='gcsagroup/aegis-browser', platform='ios', version='1.0.0',
                     build='20', profile='alpha', source=dict(sha='a' * 40, tree='b' * 40, dirty=False),
                     details={'privateBetaTestNode': private},
                     assets=[dict(name='app.ipa', size=payload.stat().st_size,
                                  sha256=hashlib.sha256(payload.read_bytes()).hexdigest())])
        raw = json.dumps(value).encode()
        (root / 'ios-manifest.json').write_bytes(raw)
        digest = hashlib.sha256(raw).hexdigest()
        (root / 'ios-manifest.json.sha256').write_text(digest + '  ios-manifest.json\n')
        (root / 'AuthKey_fixture.p8').write_text('synthetic forbidden extra')
        (root / 'work').mkdir()
        return digest

    def test_private_resources_and_manifest_markers_cannot_reach_the_catalogue(self):
        for resource, private in ((None, True), ('AegisPrivateTestNode.vless', False),
                                  ('AegisPrivateTestSubscription.json', False)):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / 'package'
                source.mkdir()
                digest = self.package(source, resource=resource, private=private)
                with self.assertRaisesRegex(ValueError, 'Private iOS'):
                    catalogue.collect(source, digest, root / 'out')
                self.assertFalse((root / 'out').exists())

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
