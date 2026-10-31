import importlib.util
import pathlib
import tempfile
import unittest
import zipfile

FILE = pathlib.Path(__file__).with_name('artifact-transport.py')


class ArtifactTransportTests(unittest.TestCase):
    def module(self):
        self.assertTrue(FILE.exists(), 'portable artifact importer is missing')
        spec = importlib.util.spec_from_file_location('artifact_transport', FILE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def run_record(self):
        return dict(id=12, run_attempt=2, head_sha='a'*40, head_repository={'full_name': 'owner/repo'},
                    repository={'full_name': 'owner/repo'}, status='completed', conclusion='success',
                    path='.github/workflows/ios-release.yml', event='workflow_dispatch')

    def test_wrong_repository_source_attempt_and_uncompleted_run_are_rejected(self):
        m = self.module()
        m.verify_run(self.run_record(), 'owner/repo', 'a'*40, 12, 2)
        for changes in [dict(head_sha='b'*40), dict(run_attempt=1), dict(conclusion='failure'),
                        dict(path='.github/workflows/quality.yml'), dict(head_repository={'full_name': 'other/repo'})]:
            with self.assertRaises(ValueError):
                m.verify_run(dict(self.run_record(), **changes), 'owner/repo', 'a'*40, 12, 2)

    def test_unified_delivery_keeps_exact_successful_producer_contract(self):
        m = self.module()
        row = dict(self.run_record(), path='.github/workflows/ios-delivery.yml')
        m.verify_run(row, 'owner/repo', 'a'*40, 12, 2)
        with self.assertRaises(ValueError):
            m.verify_run(dict(row, run_attempt=3), 'owner/repo', 'a'*40, 12, 2)

    def test_hostile_zip_is_rejected_before_any_destination_file_exists(self):
        m = self.module()
        for name in ['../escape', '/absolute', 'work/secret.p8', 'app.ipa/child']:
            with tempfile.TemporaryDirectory() as tmp:
                path = pathlib.Path(tmp)/'input.zip'
                with zipfile.ZipFile(path, 'w') as archive:
                    archive.writestr(name, 'payload')
                destination = pathlib.Path(tmp)/'out'
                with self.assertRaises(ValueError):
                    m.extract_flat(path, destination)
                self.assertFalse(destination.exists())

    def test_signing_material_cannot_be_imported_as_stage_record(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp)/'input.zip'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('AuthKey.p8', 'forbidden')
            with self.assertRaises(ValueError):
                m.extract_flat(path, pathlib.Path(tmp)/'out')


if __name__ == '__main__':
    unittest.main()
