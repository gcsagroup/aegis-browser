import importlib.util
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
import zipfile

FILE = pathlib.Path(__file__).with_name('artifact-transport.py')


class ArtifactTransportTests(unittest.TestCase):
    def test_public_export_rejects_private_resources_even_without_manifest_flags(self):
        for resource in (None, 'AegisPrivateTestNode.vless', 'AegisPrivateTestSubscription.json',
                         'AegisAlphaTestNodes.json', 'PlugIns/Share.appex/aegisalphatestnodes.json'):
            with self.subTest(resource=resource), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                package = root/'package'
                package.mkdir()
                ipa = package/'app.ipa'
                with zipfile.ZipFile(ipa, 'w') as binary:
                    binary.writestr('Payload/Aegis.app/Info.plist', 'fixture')
                    if resource:
                        binary.writestr('Payload/Aegis.app/'+resource, 'private fixture')
                manifest = package/'ios-manifest.json'
                manifest.write_text(json.dumps(dict(source=dict(sha='a'*40, tree='b'*40, dirty=False),
                    repository='gcsagroup/aegis-browser', platform='ios', assets=[dict(name=ipa.name,
                    size=ipa.stat().st_size, sha256=hashlib.sha256(ipa.read_bytes()).hexdigest())])))
                digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
                (package/'ios-manifest.json.sha256').write_text(f'{digest}  ios-manifest.json\n')
                target = root/'package.zip'
                result = subprocess.run([sys.executable, str(FILE), 'export', '--directory', str(package),
                    '--zip', str(target), '--sha', 'a'*40, '--tree', 'b'*40, '--manifest-sha256', digest], capture_output=True)
                self.assertEqual(result.returncode == 0, resource is None)
                self.assertEqual(target.exists(), resource is None)
                self.assertNotIn(b'private fixture', result.stderr)

    def test_import_rejects_private_alpha_even_from_an_admitted_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            ipa = root / 'app.ipa'
            with zipfile.ZipFile(ipa, 'w') as binary:
                binary.writestr('Payload/Aegis.app/AegisAlphaTestNodes.json', 'private fixture')
            repository = 'gcsagroup/aegis-browser'
            sha, tree = 'a' * 40, 'b' * 40
            manifest = json.dumps(dict(source=dict(sha=sha, tree=tree, dirty=False), repository=repository,
                platform='ios', assets=[dict(name=ipa.name, size=ipa.stat().st_size,
                    sha256=hashlib.sha256(ipa.read_bytes()).hexdigest())])).encode()
            digest = hashlib.sha256(manifest).hexdigest()
            transport = root / 'package.zip'
            with zipfile.ZipFile(transport, 'w') as archive:
                archive.write(ipa, ipa.name)
                archive.writestr('ios-manifest.json', manifest)
                archive.writestr('ios-manifest.json.sha256', f'{digest}  ios-manifest.json\n')
            run = root / 'run.json'
            run.write_text(json.dumps(dict(id=12, run_attempt=1, head_sha=sha,
                head_repository=dict(full_name=repository), repository=dict(full_name=repository),
                status='completed', conclusion='success', path='.github/workflows/ios-delivery.yml',
                event='workflow_dispatch')))
            target = root / 'imported'
            result = subprocess.run([sys.executable, '-B', str(FILE), 'import', '--directory', str(target),
                '--zip', str(transport), '--sha', sha, '--tree', tree, '--manifest-sha256', digest,
                '--run-json', str(run), '--repository', repository, '--run-id', '12', '--attempt', '1'],
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Private iOS test resources', result.stderr)
            self.assertNotIn('private fixture', result.stderr)
            self.assertFalse(target.exists())

    def test_cloud_evidence_is_complete_and_cannot_enter_a_manual_manifest(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            assets = []
            for name in ['app.ipa', 'app.dSYM.zip', *sorted(m.CLOUD_EVIDENCE)]:
                (root / name).write_bytes(b'fixture')
                assets.append({'name': name, 'size': 7, 'sha256': hashlib.sha256(b'fixture').hexdigest()})
            manifest = {'source': dict(sha='a'*40, tree='b'*40, dirty=False), 'repository': 'gcsagroup/aegis-browser',
                        'platform': 'ios', 'assets': assets, 'details': {'signingMode': 'cloud'}}
            def save():
                path = root / 'ios-manifest.json'
                path.write_text(json.dumps(manifest))
                digest = m.digest(path)
                (root/'ios-manifest.json.sha256').write_text(f'{digest}  ios-manifest.json\n')
                return digest
            m.verify_package(root, 'a'*40, 'b'*40, save())
            manifest['details']['signingMode'] = 'manual'
            with self.assertRaisesRegex(ValueError, 'Cloud package evidence'):
                m.verify_package(root, 'a'*40, 'b'*40, save())
            manifest['details']['signingMode'] = 'cloud'
            manifest['assets'] = assets[:-1]
            with self.assertRaisesRegex(ValueError, 'Cloud package evidence'):
                m.verify_package(root, 'a'*40, 'b'*40, save())

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
