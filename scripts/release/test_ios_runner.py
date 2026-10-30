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
        job = dict(id=1, name='ios-package', status='queued', labels=['self-hosted', 'aegis-ios-fork'])
        m.validate_job(job, 1, 'aegis-ios-fork')
        for changes in [dict(id=2), dict(status='in_progress'), dict(labels=['aegis-macos']), dict(name='foreign-job')]:
            with self.assertRaises(ValueError):
                m.validate_job(dict(job, **changes), 1, 'aegis-ios-fork')

    def test_unknown_registration_and_insufficient_real_disk_block_new_runner(self):
        m = self.module()
        with self.assertRaises(ValueError):
            m.validate_start({'outcome': 'unknown'}, 100*1024**3, 100*1024**3)
        with self.assertRaises(ValueError):
            m.validate_start(None, 7*1024**3, 100*1024**3)
        with self.assertRaises(ValueError):
            m.validate_start(None, 100*1024**3, 14*1024**3)
        m.validate_start(None, 9*1024**3, 16*1024**3)


if __name__ == '__main__':
    unittest.main()
