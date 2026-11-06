import hashlib
import importlib.util
import json
import os
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile

spec = importlib.util.spec_from_file_location('ios_action_restore_test', Path(__file__).with_name('ios-action.py'))
action = importlib.util.module_from_spec(spec)
spec.loader.exec_module(action)


class SameRunRestoreTests(unittest.TestCase):
    def restore(self, *, origin_attempt=1, producer_attempt=1, conclusion='success', kind='new-upload'):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = dict(sha='a'*40, tree='b'*40, dirty=False)
            manifest = dict(source=source, repository='gcsagroup/aegis-browser', platform='ios', profile='alpha', version='1.0.0', build='36',
                            assets=[dict(name='Aegis.ipa', size=3, sha256=hashlib.sha256(b'ipa').hexdigest())])
            raw = json.dumps(manifest).encode()
            digest = hashlib.sha256(raw).hexdigest()
            origin = dict(runId=10, attempt=origin_attempt, repository='gcsagroup/aegis-browser', sourceSha='a'*40, sourceTree='b'*40,
                          manifestSha256=digest, runIdLocal='ios-gh-10-1')
            package = root/'.artifacts/download/package.zip'
            package.parent.mkdir(parents=True)
            with zipfile.ZipFile(package, 'w') as z:
                for name, value in {'Aegis.ipa': b'ipa', 'ios-manifest.json': raw, 'ios-manifest.json.sha256': f'{digest}  ios-manifest.json\n'.encode(),
                                    'package-origin.json': json.dumps(origin).encode()}.items():
                    z.writestr(name, value)
            target = root/'.artifacts/release/ios/ios-gh-10-1'
            run = dict(head_sha='a'*40, run_attempt=1, repository={'full_name': 'gcsagroup/aegis-browser'}, path='.github/workflows/ios-delivery-full.yml')
            job = dict(name='delivery / ios-package', status='completed', conclusion=conclusion, head_sha='a'*40, run_id=10, run_attempt=producer_attempt)
            def api(path):
                return dict(total_count=1, jobs=[job]) if '/jobs?' in path else run
            fake = SimpleNamespace(ROOT=root, source=lambda: ('a'*40, 'b'*40), transport=action.transport, api=api,
                                   validate_mutation_attempt=action.validate_mutation_attempt, directory=lambda: target)
            env = dict(GITHUB_RUN_ID='10', GITHUB_RUN_ATTEMPT='1', GITHUB_REPOSITORY='gcsagroup/aegis-browser', IMPORT_KIND=kind,
                       RELEASE_PROFILE='alpha', RELEASE_VERSION='1.0.0', RELEASE_BUILD='36', RELEASE_MANIFEST_SHA256=digest,
                       PACKAGE_RUN_ID='10', RELEASE_RUN_ID='ios-gh-10-1', RELEASE_STAGE='upload')
            with patch.dict(os.environ, env), patch('importlib.util.spec_from_file_location', return_value=SimpleNamespace(loader=Mock())), \
                    patch('importlib.util.module_from_spec', return_value=fake):
                runpy.run_path(str(Path(__file__).with_name('ios-restore.py')))
            self.assertEqual((target/'Aegis.ipa').read_bytes(), b'ipa')
            self.assertEqual(json.loads((target/'package-origin.json').read_text())['runId'], 10)

    def test_new_upload_restores_only_the_successful_exact_same_run_producer(self):
        self.restore()
        for changes in [dict(origin_attempt=2), dict(producer_attempt=2), dict(conclusion='failure'), dict(kind='unknown')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.restore(**changes)


if __name__ == '__main__':
    unittest.main()
