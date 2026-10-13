"""付费编排的失败边界；用真实子进程和临时 Git 仓库验证。"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import windows_hosted as hosted


class HostedTrialTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.logs = self.root / 'evidence'
        self.logs.mkdir()
        self.runner = hosted.Runner(self.logs, self.root, minutes=1, minimum_gib=0)

    def test_real_process_output_is_retained(self):
        self.runner.run('success', [sys.executable, '-c', 'print("representative input")'], self.root)
        self.assertIn('representative input', (self.logs / 'success.log').read_text())

    def test_nonzero_exit_preserves_log_and_fails(self):
        with self.assertRaisesRegex(RuntimeError, '退出码 3'):
            self.runner.run('failure', [sys.executable, '-c', 'print("failed");exit(3)'], self.root)
        self.assertIn('failed', (self.logs / 'failure.log').read_text())

    def test_elapsed_budget_never_launches(self):
        self.runner.deadline = 0
        with self.assertRaises(TimeoutError):
            self.runner.run('expired', [sys.executable, '-c', 'exit(0)'], self.root)
        self.assertFalse((self.logs / 'expired.log').exists())

    def test_running_process_is_stopped_at_deadline(self):
        self.runner.deadline = hosted.time.monotonic() + 0.5
        with self.assertRaises(TimeoutError):
            self.runner.run('timeout', [sys.executable, '-c', 'import time;time.sleep(30)'], self.root)

    def test_low_space_never_launches(self):
        self.runner.minimum = 10**30
        with self.assertRaisesRegex(RuntimeError, '空间不足'):
            self.runner.run('space', [sys.executable, '-c', 'exit(0)'], self.root)
        self.assertFalse((self.logs / 'space.log').exists())

    def test_test_receipt_rejects_empty_failed_and_wrong_count(self):
        receipt = self.root / 'tests.json'
        for data in [{}, {'per_iteration_data': [{}]},
                     {'per_iteration_data': [{'A': [{'status': 'FAILURE'}]}]},
                     {'per_iteration_data': [{'A': [{'status': 'SKIPPED'}]}]}]:
            receipt.write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                hosted.check_test_summary(receipt)
        receipt.write_text(json.dumps({'per_iteration_data': [{'A': [{'status': 'SUCCESS'}]}]}))
        self.assertEqual(hosted.check_test_summary(receipt, 1), 1)
        with self.assertRaisesRegex(ValueError, '数量'):
            hosted.check_test_summary(receipt, 4)

    def test_patch_replay_and_dirty_source_boundary(self):
        source = self.root / 'src'
        source.mkdir()
        def git(*args):
            return subprocess.check_output(['git', '-C', str(source), *args], text=True).strip()
        git('init')
        git('config', 'user.name', '测试')
        git('config', 'user.email', 'test@example.invalid')
        git('config', 'core.autocrlf', 'false')
        (source / 'sample.txt').write_text('before\n')
        git('add', 'sample.txt')
        git('commit', '-m', 'base')
        base = git('rev-parse', 'HEAD')
        (source / 'sample.txt').write_text('after\n')
        diff = git('diff') + '\n'
        git('restore', 'sample.txt')
        patches = self.root / 'patches'
        patches.mkdir()
        (patches / 'series').write_text('sample.patch\n')
        (patches / 'sample.patch').write_text(diff)
        (source / 'unrelated.txt').write_text('保留')
        with self.assertRaisesRegex(ValueError, '有改动'):
            hosted.patch_checkout(self.runner, source, base, patches, 'dirty')
        self.assertEqual((source / 'unrelated.txt').read_text(), '保留')
        (source / 'unrelated.txt').unlink()
        tree = hosted.patch_checkout(self.runner, source, base, patches, 'patch')
        self.assertEqual(tree, git('rev-parse', 'HEAD^{tree}'))
        self.assertEqual((source / 'sample.txt').read_text(), 'after\n')

    def test_non_windows_produces_failed_receipt_without_work_directory(self):
        evidence = self.root / 'guard-evidence'
        work = self.root / 'work'
        with patch.object(hosted.sys, 'platform', 'darwin'), patch.dict(hosted.os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, '托管 Windows'):
                hosted.build(work, evidence)
        self.assertFalse(work.exists())
        result = json.loads((evidence / 'result.json').read_text())
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['uiAcceptance'], 'pending')

    def test_missing_git_wrapper_stops_before_dependency_sync(self):
        depot = self.root / 'depot'
        depot.mkdir()
        for name in ['python3.bat', 'vpython3.bat', 'gclient.bat']:
            (depot / name).write_text('@echo off')
        with self.assertRaisesRegex(ValueError, 'git.bat'):
            hosted.require_depot_wrappers(depot)
        (depot / 'git.bat').write_text('@echo off')
        hosted.require_depot_wrappers(depot)

    def test_preflight_rejects_non_windows_with_failure_receipt(self):
        evidence = self.root / 'toolchain-evidence'
        work = self.root / 'toolchain-work'
        with patch.object(hosted.sys, 'platform', 'darwin'):
            with self.assertRaisesRegex(ValueError, '托管 Windows'):
                hosted.preflight(work, evidence)
        self.assertFalse(work.exists())
        self.assertEqual(json.loads((evidence / 'toolchain-result.json').read_text())['status'], 'failed')


if __name__ == '__main__':
    unittest.main()
