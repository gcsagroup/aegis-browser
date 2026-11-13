import hashlib
from pathlib import Path
import tempfile
import unittest

from product_artifacts import publish


class ArtifactCatalogueTests(unittest.TestCase):
    def test_requested_layout_keeps_builds_and_draft_outputs_distinct(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / 'Aegis.ipa'
            source.write_bytes(b'verified IPA')
            sha = hashlib.sha256(source.read_bytes()).hexdigest()
            for channel, folder in [('alpha', 'alpha'), ('beta', 'Beta'), ('release', 'Release'), ('draft', 'Draft')]:
                outputs = []
                for build in ['20', '21']:
                    result = publish([(source, sha)], 'aegis', '1.0.1', build, channel, root / 'Downloads/artifacts')
                    destination = Path(result[0])
                    self.assertEqual(destination.parent, root / 'Downloads/artifacts/aegis/1.0.1' / folder)
                    self.assertIn('build-' + build, destination.name)
                    self.assertEqual(destination.read_bytes(), source.read_bytes())
                    self.assertEqual(result, publish([(source, sha)], 'aegis', '1.0.1', build, channel, root / 'Downloads/artifacts'))
                    outputs.extend(result)
                self.assertEqual(len(set(outputs)), 2)

    def test_copy_requires_the_verified_original_and_refuses_existing_corruption(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'symbols.dSYM.zip'
            source.write_bytes(b'symbols')
            sha = hashlib.sha256(source.read_bytes()).hexdigest()
            with self.assertRaises(ValueError):
                publish([(source, '0' * 64)], 'watermark', '1.0.0', '1', 'beta', root / 'out')
            result = publish([(source, sha)], 'watermark', '1.0.0', '1', 'beta', root / 'out')
            Path(result[0]).write_bytes(b'corrupted previous copy')
            with self.assertRaises(ValueError):
                publish([(source, sha)], 'watermark', '1.0.0', '1', 'beta', root / 'out')
            self.assertEqual(Path(result[0]).read_bytes(), b'corrupted previous copy')

    def test_catalogue_identity_and_symlinked_project_cannot_escape_the_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'app.ipa'
            source.write_bytes(b'ipa')
            sha = hashlib.sha256(source.read_bytes()).hexdigest()
            for product in ['../outside', '/absolute']:
                with self.assertRaises(ValueError):
                    publish([(source, sha)], product, '1.0.0', '1', 'alpha', root / 'out')
            (root / 'out').mkdir()
            (root / 'out/watermark').symlink_to(root)
            with self.assertRaises(ValueError):
                publish([(source, sha)], 'watermark', '1.0.0', '1', 'alpha', root / 'out')


if __name__ == '__main__':
    unittest.main()
