"""验证版本、补丁、平台隔离和产物验收约束。"""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('candidate', Path(__file__).with_name('candidate.py'))
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class CandidateTests(unittest.TestCase):
    def test_build_number_monotonically_increases(self):
        text = 'kProductVersion[] = "1.1.0.22"; // Ver 1.1 (022)'
        changed, version, number = ci.bump_header(text, 30)
        self.assertEqual((version, number), ('1.1.0.31', 31))
        self.assertIn('(031)', changed)
        self.assertNotIn('1.1.0.22', changed)

    def test_receipt_rejects_other_artifact_or_run(self):
        value = {'artifactSha256': 'aaa', 'runId': '1',
                 'checks': dict.fromkeys(ci.REQUIRED_CHECKS, 'passed'), 'evidenceFiles': ['ui.log']}
        ci.validate_receipt(value, 'aaa', '1')
        for artifact, run in [('bbb', '1'), ('aaa', '2')]:
            with self.assertRaises(ValueError):
                ci.validate_receipt(value, artifact, run)

    def test_receipt_rejects_missing_runtime_or_cve_checks(self):
        for key in ci.REQUIRED_CHECKS:
            value = {'artifactSha256': 'aaa', 'runId': '1',
                     'checks': dict.fromkeys(ci.REQUIRED_CHECKS, 'passed'), 'evidenceFiles': ['ui.log']}
            value['checks'][key] = 'skipped'
            with self.assertRaises(ValueError):
                ci.validate_receipt(value, 'aaa', '1')

    def test_platform_pin_does_not_borrow_desktop_version(self):
        with tempfile.TemporaryDirectory() as directory:
            browser = Path(directory)
            (browser / 'CHROMIUM_VERSION').write_text('153.0.8010.37')
            (browser / 'CHROMIUM_COMMIT').write_text('a' * 40)
            report = {'status': 'checked', 'errors': [], 'candidates': {
                'Mac': {'version': '153.0.8010.37', 'commit': 'a' * 40},
                'Android': {'version': '153.0.8010.36', 'commit': 'b' * 40}}}
            ci.candidate_pin('mac', report, browser)
            with self.assertRaises(ValueError):
                ci.candidate_pin('android', report, browser)
            (browser / 'ci-pins').mkdir()
            (browser / 'ci-pins/android.json').write_text(json.dumps({
                'version': '153.0.8010.36', 'commit': 'b' * 40, 'patchDirectory': 'patches/android'}))
            self.assertEqual(ci.candidate_pin('android', report, browser)[0]['commit'], 'b' * 40)
            report['errors'] = ['network failed']
            with self.assertRaises(ValueError):
                ci.candidate_pin('mac', report, browser)

    def test_real_git_replay_detects_wrong_tree_and_preserves_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src, patches = root / 'src', root / 'patches'
            src.mkdir(); patches.mkdir()
            def git(*args):
                return subprocess.check_output(['git', '-C', str(src), *args], text=True).strip()
            git('init', '-q'); git('config', 'user.name', 'CI test'); git('config', 'user.email', 'ci@example.invalid')
            (src / 'code.txt').write_text('base\n')
            git('add', 'code.txt'); git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (src / 'code.txt').write_text('fixed\n')
            git('commit', '-qam', 'fix')
            (patches / 'fix.patch').write_text(git('format-patch', '-1', '--stdout') + '\n')
            (patches / 'series').write_text('fix.patch\n')
            fresh = root / 'fresh'
            subprocess.run(['git', 'clone', '-q', str(src), str(fresh)], check=True)
            subprocess.run(['git', '-C', str(fresh), 'checkout', '-q', '--detach', base], check=True)
            ci.apply_if_base(fresh, base, patches, root / 'apply.log')
            ci.verify_tree(fresh, base, patches)
            self.assertEqual((fresh / 'code.txt').read_text(), 'fixed\n')
            before = git('rev-parse', 'HEAD')
            ci.verify_tree(src, base, patches)
            self.assertEqual(git('rev-parse', 'HEAD'), before)
            self.assertEqual((src / 'code.txt').read_text(), 'fixed\n')
            (src / 'code.txt').write_text('unrelated\n')
            with self.assertRaises(ValueError):
                ci.verify_tree(src, base, patches)
            git('commit', '-qam', 'unrelated')
            with self.assertRaises(ValueError):
                ci.verify_tree(src, base, patches)
            self.assertEqual((src / 'code.txt').read_text(), 'unrelated\n')

    def test_series_rejects_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'series').write_text('../external.patch\n')
            with self.assertRaises(ValueError):
                ci.series(path)

    def test_missing_machine_config_emits_failed_evidence(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(ci.os.environ, {}, clear=True):
            evidence = Path(directory)
            with self.assertRaisesRegex(ValueError, 'AEGIS_CI_CONFIG'):
                ci.build('windows', evidence)
            result = json.loads((evidence / 'result.json').read_text())
            self.assertEqual(result['status'], 'failed')
            self.assertFalse(result['releaseReady'])
            self.assertEqual(result['runtimeAcceptance'], 'pending')

    def test_summary_keeps_missing_installation_explicit(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(ci.os.environ, {}, clear=True):
            path = Path(directory)
            ci.write_json(path / 'result.json', {'platform': 'android', 'status': 'failed', 'runtimeAcceptance': 'pending', 'error': 'device missing'})
            ci.summary(path)
            self.assertIn('device missing', (path / 'summary.md').read_text())
            self.assertIn('未执行', (path / 'summary.md').read_text())

    def test_upstream_monitor_avoids_stale_branch_and_evidence_cache_growth(self):
        workflow = (ci.ROOT / '.github/workflows/chromium-upstream.yml').read_text()
        self.assertIn('branches: [main]', workflow)
        self.assertNotIn('codex/ci/chromium-three-platform', workflow)
        self.assertIn('cancel-in-progress: true', workflow)
        self.assertIn("github.event_name != 'schedule' || github.repository == 'gcsagroup/aegis-browser'", workflow)
        self.assertIn('ci-evidence/upstream/latest.json', workflow)
        self.assertIn('ci-evidence/upstream/last-success.json', workflow)
        self.assertIn('ci-evidence/upstream/state.json', workflow)
        self.assertNotIn('path: ci-evidence/upstream\n', workflow)
        self.assertIn('chromium-upstream-state-', workflow)
        self.assertIn('chromium-upstream-', workflow)
        self.assertIn('rm -rf ci-evidence/upstream/runs ci-evidence/upstream/sources', workflow)

    def test_candidate_workflow_is_manual_until_dedicated_runners_are_ready(self):
        workflow = (ci.ROOT / '.github/workflows/chromium-candidate.yml').read_text()
        trigger = workflow.split('permissions:', 1)[0]
        self.assertIn('workflow_dispatch:', trigger)
        self.assertNotIn('\n  push:', trigger)


if __name__ == '__main__':
    unittest.main()
