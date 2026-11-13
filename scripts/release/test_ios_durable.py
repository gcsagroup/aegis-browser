import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import zipfile
import io

from product_delivery import Records
from test_product_delivery import FakeGitHub


def load(filename, name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


durable = load('ios-durable.py', 'tested_durable')
action = load('ios-action.py', 'tested_action')


class ProductAPI(FakeGitHub):
    def __init__(self):
        super().__init__()
        self.run = dict(id=10, run_attempt=1, head_sha='a' * 40, status='completed', conclusion='failure',
                        repository={'id': durable.REPOSITORY_ID}, head_repository={'id': durable.REPOSITORY_ID},
                        path='.github/workflows/ios-delivery.yml', event='workflow_dispatch')
        self.job = dict(id=20, name='delivery / ios-package', run_id=10, run_attempt=1,
                        head_sha='a' * 40, status='completed', conclusion='success')
        self.artifact = dict(id=30, name='ios-package-10-1', digest='sha256:' + 'd' * 64, expired=False)

    def request(self, path, payload=None, missing=False):
        if path == '':
            return {'id': durable.REPOSITORY_ID}
        if path in {'actions/runs/10', 'actions/runs/10/attempts/1'}:
            return self.run
        if '/jobs?' in path:
            return {'total_count': 1, 'jobs': [self.job]}
        if path.endswith('/artifacts?per_page=100'):
            return {'total_count': 1, 'artifacts': [self.artifact]}
        return super().request(path, payload, missing)


class IosDurableTests(unittest.TestCase):
    def setUp(self):
        self.api = ProductAPI()
        self.store = Records(self.api, durable.REPOSITORY_ID, durable.APPLICATION)

    def package(self, root):
        ipa = root / 'app.ipa'
        ipa.write_bytes(b'verified fixture')
        manifest = dict(platform='ios', repository=durable.REPOSITORY, applicationId='com.gcsa.aegis',
                        version='1.0.0', build='20', profile='alpha', format='ipa',
                        source=dict(sha='a' * 40, tree='b' * 40, dirty=False),
                        assets=[dict(name=ipa.name, size=ipa.stat().st_size, sha256=hashlib.sha256(ipa.read_bytes()).hexdigest())])
        raw = json.dumps(manifest).encode()
        digest = hashlib.sha256(raw).hexdigest()
        (root / 'ios-manifest.json').write_bytes(raw)
        (root / 'ios-manifest.json.sha256').write_text(digest + '  ios-manifest.json\n')
        origin = dict(repository=durable.REPOSITORY, runId=10, attempt=1, sourceSha='a' * 40,
                      sourceTree='b' * 40, manifestSha256=digest, runIdLocal='ios-gh-10-1')
        (root / 'package-origin.json').write_text(json.dumps(origin))
        self.store.create('export-start', durable.key('1.0.0', '20'),
                          dict(source=dict(sha='a' * 40, tree='b' * 40), profile='alpha', run_id='10', attempt='1'))
        return origin

    def test_successful_package_is_sealed_despite_later_upload_failure(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(durable, 'records', return_value=self.store), \
                patch.object(durable, 'source', return_value=dict(sha='a' * 40, tree='b' * 40)):
            origin = self.package(Path(temporary))
            durable.seal(Path(temporary), {})
            sealed = self.store.read('package', durable.key('1.0.0', '20'))
            self.assertEqual((sealed['package_job_id'], sealed['artifact_id']), (20, 30))
            environment = dict(RELEASE_VERSION='1.0.0', RELEASE_BUILD='20', RELEASE_PROFILE='alpha',
                               RELEASE_MANIFEST_SHA256=origin['manifestSha256'])
            with patch.dict(os.environ, environment), patch.object(action.durable, 'records', return_value=self.store):
                self.assertEqual(action.verify_package_run(self.api.run, durable.REPOSITORY, 'a' * 40, 10, 1), sealed)
                self.api.job['conclusion'] = 'failure'
                with self.assertRaises(ValueError):
                    action.verify_package_run(self.api.run, durable.REPOSITORY, 'a' * 40, 10, 1)

    def test_seal_rejects_substituted_attempt_job_and_expired_original(self):
        for kind in ['attempt', 'job', 'artifact']:
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                self.setUp()
                self.package(Path(temporary))
                if kind == 'attempt':
                    self.api.run['run_attempt'] = 2
                elif kind == 'job':
                    self.api.job['run_id'] = 99
                else:
                    self.api.artifact['expired'] = True
                with patch.object(durable, 'records', return_value=self.store), \
                        patch.object(durable, 'source', return_value=dict(sha='a' * 40, tree='b' * 40)), \
                        self.assertRaises(ValueError):
                    durable.seal(Path(temporary), {})
                self.assertIsNone(self.store.read('package', durable.key('1.0.0', '20')))

    def test_failed_combined_run_imports_the_original_sealed_artifact_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / 'original'
            original.mkdir()
            origin = self.package(original)
            package_bytes = io.BytesIO()
            with zipfile.ZipFile(package_bytes, 'w') as package:
                for item in original.iterdir():
                    package.writestr(item.name, item.read_bytes())
            envelope = io.BytesIO()
            with zipfile.ZipFile(envelope, 'w') as zipped:
                zipped.writestr('package.zip', package_bytes.getvalue())
            outer = envelope.getvalue()
            self.api.artifact['digest'] = 'sha256:' + hashlib.sha256(outer).hexdigest()
            with patch.object(durable, 'records', return_value=self.store), \
                    patch.object(durable, 'source', return_value=dict(sha='a' * 40, tree='b' * 40)):
                durable.seal(original, {})
            environment = dict(GITHUB_REPOSITORY=durable.REPOSITORY, PACKAGE_RUN_ID='10',
                               SOURCE_ATTEMPT='1', GITHUB_RUN_ID='11', GITHUB_RUN_ATTEMPT='1',
                               RELEASE_PROFILE='alpha', RELEASE_VERSION='1.0.0', RELEASE_BUILD='20',
                               RELEASE_MANIFEST_SHA256=origin['manifestSha256'], RELEASE_STAGE='status',
                               UPLOAD_RUN_ID='')
            def download(_args, stdout, **_kwargs):
                stdout.write(outer)
                return SimpleNamespace(returncode=0)
            with patch.dict(os.environ, environment), patch.object(action, 'ROOT', root), \
                    patch.object(action, 'source', return_value=('a' * 40, 'b' * 40)), \
                    patch.object(action, 'api', side_effect=self.api.request), \
                    patch.object(action.durable, 'records', return_value=self.store), \
                    patch.object(action, 'output'), patch.object(action.subprocess, 'run', side_effect=download):
                action.import_package()
            imported = root / '.artifacts/release/ios/ios-gh-10-1'
            self.assertEqual((imported / 'app.ipa').read_bytes(), b'verified fixture')
            self.assertEqual((imported / 'package-origin.json').read_bytes(),
                             (original / 'package-origin.json').read_bytes())


if __name__ == '__main__':
    unittest.main()
