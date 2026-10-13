"""付费编排的失败边界；用真实子进程和临时 Git 仓库验证。"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

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

    def test_fixed_source_has_origin_before_gclient_takeover(self):
        upstream = self.root / 'upstream'
        upstream.mkdir()
        def git(path, *args):
            return subprocess.check_output(['git', '-C', str(path), *args], text=True).strip()
        git(upstream, 'init', '-q')
        git(upstream, 'config', 'user.name', '测试')
        git(upstream, 'config', 'user.email', 'test@example.invalid')
        (upstream / 'DEPS').write_text('deps = {}\n', newline='\n')
        git(upstream, 'add', 'DEPS')
        git(upstream, 'commit', '-qm', '固定输入')
        git(upstream, 'tag', 'test-pin')
        base = git(upstream, 'rev-parse', 'HEAD')
        work = self.root / 'checkout'
        work.mkdir()
        source = hosted.checkout_source(self.runner, work, None, upstream.as_uri(),
                                        'refs/tags/test-pin', base)
        self.assertEqual(git(source, 'remote', 'get-url', 'origin'), upstream.as_uri())
        # 重放上次 gclient 真正失败的命令，确认无需凭空创建或猜测远端。
        git(source, 'remote', 'set-url', 'origin', upstream.as_uri())
        hosted.verify_source_identity(source, upstream.as_uri(), base)
        git(source, 'remote', 'set-url', 'origin', 'https://example.invalid/wrong.git')
        with self.assertRaisesRegex(ValueError, 'origin'):
            hosted.verify_source_identity(source, upstream.as_uri(), base)

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

    def test_windows_cleanup_error_preserves_original_timeout(self):
        # 重现远端 taskkill 返回 255，以及清理命令本身无法启动两种情形。
        for cleanup_error in [subprocess.CalledProcessError(255, ['taskkill']),
                              FileNotFoundError('taskkill missing')]:
            with self.subTest(cleanup_error=cleanup_error):
                process = Mock(pid=123, returncode=None)
                process.poll.return_value = None
                self.runner.deadline = 1
                with patch.object(hosted.os, 'name', 'nt'), \
                     patch.object(hosted.subprocess, 'CREATE_NEW_PROCESS_GROUP', 512, create=True), \
                     patch.object(hosted.subprocess, 'Popen', return_value=process), \
                     patch.object(hosted.time, 'monotonic', side_effect=[0, 0, 2]), \
                     patch.object(hosted.candidate, 'windows_system_executable', return_value='taskkill'), \
                     patch.object(hosted.subprocess, 'run', side_effect=cleanup_error):
                    with self.assertRaisesRegex(TimeoutError, '本次构建时限已到') as caught:
                        self.runner.run('timeout', ['compiler'], self.root)
                self.assertIn(str(cleanup_error), caught.exception.__notes__[0])
                process.kill.assert_called_once()
                process.wait.assert_called_once_with(timeout=10)

    def test_real_process_is_reaped_when_tree_cleanup_fails(self):
        self.runner.deadline = hosted.time.monotonic() + 0.5
        real_popen = subprocess.Popen
        processes = []
        def start(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append(process)
            self.addCleanup(lambda: process.kill() if process.poll() is None else None)
            return process
        cleanup = (patch.object(hosted.subprocess, 'run',
                                side_effect=subprocess.CalledProcessError(255, ['taskkill']))
                   if hosted.os.name == 'nt' else
                   patch.object(hosted.os, 'killpg', side_effect=ProcessLookupError('清理竞争')))
        with patch.object(hosted.subprocess, 'Popen', side_effect=start), cleanup:
            with self.assertRaisesRegex(TimeoutError, '本次构建时限已到') as caught:
                self.runner.run('timeout-cleanup',
                                [sys.executable, '-c', 'import time;time.sleep(30)'], self.root)
        self.assertIn('清理异常', caught.exception.__notes__[0])
        self.assertIsNotNone(processes[0].poll())

    def test_failure_receipts_keep_original_error_and_cleanup_note(self):
        error = TimeoutError('本次构建时限已到')
        error.add_note('build 清理异常：taskkill exit 255')
        def environment(key, default=None):
            if key == 'RUNNER_ENVIRONMENT':
                raise error
            return default
        # 两个入口的结果文件均须保留主错误及附注。
        for entry, filename in [(hosted.preflight, 'toolchain-result.json'),
                                (hosted.build, 'result.json')]:
            with self.subTest(entry=entry.__name__):
                evidence = self.root / entry.__name__
                with patch.object(hosted.sys, 'platform', 'win32'), \
                     patch.object(hosted.os.environ, 'get', side_effect=environment):
                    with self.assertRaises(TimeoutError):
                        entry(self.root / 'unused', evidence)
                result = json.loads((evidence / filename).read_text())
                self.assertEqual(result['error'], '本次构建时限已到')
                self.assertEqual(result['errorNotes'], ['build 清理异常：taskkill exit 255'])

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

    def test_older_sdk_does_not_satisfy_chromium_requirement(self):
        old = self.root / 'Include/10.0.26100.0/um'
        old.mkdir(parents=True)
        (old / 'windows.h').write_text('old SDK')
        with self.assertRaisesRegex(ValueError, '10.0.28000.0'):
            hosted.require_sdk(self.root)

    def test_sdk_without_x86_link_library_is_rejected(self):
        for name in hosted.sdk_files():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
        hosted.require_sdk(self.root)
        (self.root / f'Lib/{hosted.SDK_VERSION}/um/x86/kernel32.lib').unlink()
        with self.assertRaisesRegex(ValueError, 'um/x86/kernel32.lib'):
            hosted.require_sdk(self.root)

    def test_chromium_sdk_version_drift_is_rejected(self):
        source = self.root / 'src'
        script = source / 'build/toolchain/win/setup_toolchain.py'
        script.parent.mkdir(parents=True)
        script.write_text("SDK_VERSION = '10.0.99999.0'\n")
        with self.assertRaisesRegex(ValueError, '源码要求不一致'):
            hosted.check_chromium_toolchain(self.runner, source, self.root, {})

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
