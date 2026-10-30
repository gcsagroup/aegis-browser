import importlib.util
import pathlib
import tempfile
import unittest

FILE = pathlib.Path(__file__).with_name('ios-runner.py')


class IosRunnerTests(unittest.TestCase):
    def module(self):
        self.assertTrue(FILE.exists(), 'owned runner helper is missing')
        spec = importlib.util.spec_from_file_location('ios_runner', FILE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_incomplete_payload_fails_before_registration(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            for name in ['config.sh', 'run.sh', 'bin/Runner.Listener']:
                path = pathlib.Path(tmp)/name
                path.parent.mkdir(exist_ok=True)
                path.write_text('fixture')
            with self.assertRaises(ValueError):
                m.validate_payload(pathlib.Path(tmp))

    def test_foreign_or_wrong_job_is_not_admitted(self):
        m = self.module()
        job = dict(id=1, run_id=12, run_attempt=2, head_sha='a'*40, name='ios-package', status='queued', labels=['aegis-ios-fork'])
        m.validate_job(job, 1, 'aegis-ios-fork', run_id=12, sha='a'*40, attempt=2)
        for changes in [dict(id=2), dict(status='in_progress'), dict(labels=['aegis-macos']), dict(name='foreign-job')]:
            with self.assertRaises(ValueError):
                m.validate_job(dict(job, **changes), 1, 'aegis-ios-fork', run_id=12, sha='a'*40, attempt=2)

    def test_unknown_registration_and_insufficient_real_disk_block_new_runner(self):
        m = self.module()
        with self.assertRaises(ValueError):
            m.validate_start({'outcome': 'unknown'}, 100*1024**3, 100*1024**3)
        with self.assertRaises(ValueError):
            m.validate_start(None, 7*1024**3, 100*1024**3)
        with self.assertRaises(ValueError):
            m.validate_start(None, 100*1024**3, 14*1024**3)
        m.validate_start(None, 9*1024**3, 16*1024**3)

    def test_dedicated_runner_does_not_match_default_only_foreign_jobs(self):
        m = self.module()
        self.assertTrue(hasattr(m, 'compatible_job'), 'runner routing function missing')
        self.assertFalse(m.compatible_job({'labels': ['self-hosted']}, {'unique-ios'}))
        self.assertFalse(m.compatible_job({'labels': ['self-hosted', 'macOS', 'ARM64']}, {'unique-ios'}))
        self.assertTrue(m.compatible_job({'labels': ['unique-ios']}, {'unique-ios'}))

    def test_job_identity_must_match_run_sha_and_current_attempt(self):
        m = self.module()
        job = dict(id=1, run_id=12, run_attempt=2, head_sha='a'*40, name='ios-package', status='queued', labels=['unique-ios'])
        for changes in [dict(run_id=99), dict(head_sha='b'*40), dict(run_attempt=1)]:
            with self.assertRaises(ValueError):
                m.validate_job(dict(job, **changes), 1, 'unique-ios', run_id=12, sha='a'*40, attempt=2)
        m.validate_job(job, 1, 'unique-ios', run_id=12, sha='a'*40, attempt=2)

    def test_non_executable_and_missing_env_runtime_fail_before_privileged_work(self):
        m = self.module()
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            for name in ['config.sh', 'run.sh', 'run-helper.sh.template', 'safe_sleep.sh', 'bin/Runner.Listener', 'bin/Runner.Worker']:
                path = root/name
                path.parent.mkdir(exist_ok=True)
                path.write_text('nonempty')
            (root/'externals').mkdir()
            with self.assertRaises(ValueError):
                m.validate_payload(root)


if __name__ == '__main__':
    unittest.main()
