"""验证版本、补丁、平台隔离和产物验收约束。"""
import importlib.util
import inspect
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
    def test_workflow_output_is_not_mistaken_for_dirty_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return ci.git(root, *args)
            git('init', '-q'); git('config', 'user.name', 'test')
            git('config', 'user.email', 'test@example.invalid')
            (root / 'source.txt').write_text('产品输入')
            git('add', 'source.txt'); git('commit', '-qm', '初始输入')
            (root / 'ci-evidence').mkdir()
            (root / 'ci-evidence/result.json').write_text('{}')
            self.assertEqual(ci.product_status(root), '')
            (root / 'new-feature.txt').write_text('新增功能')
            self.assertIn('new-feature.txt', ci.product_status(root))
            git('add', 'ci-evidence/result.json')
            with self.assertRaisesRegex(ValueError, '已跟踪'):
                ci.product_status(root)

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

    def test_acceptance_command_requires_absolute_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'acceptance'
            executable.write_text('#!/bin/sh\nexit 0\n')
            executable.chmod(0o755)
            self.assertEqual(ci.command_argv([str(executable), '--fixture'], allow_path_lookup=False),
                             [str(executable.resolve()), '--fixture'])
            with self.assertRaisesRegex(ValueError, '绝对可执行文件路径'):
                ci.command_argv(['python3', 'acceptance.py'], allow_path_lookup=False)

    def test_system_tool_resolution_is_absolute(self):
        resolved = Path(ci.system_tool('git'))
        self.assertTrue(resolved.is_absolute())
        self.assertTrue(resolved.is_file())

    def test_git_keeps_literal_arguments_and_isolated_environment_without_shell(self):
        # argv 和隔离环境原样传入；命令中的元字符不能被包装成 shell 文本。
        executable = ci.git_executable()
        environment = {'GIT_NO_LAZY_FETCH': '1'}
        with patch.object(ci.subprocess, 'check_output', return_value='value\n') as output:
            self.assertEqual(ci.git('repo & data', 'rev-parse', 'HEAD^{tree}', env=environment), 'value')
        output.assert_called_once_with(
            [executable, '-C', 'repo & data', 'rev-parse', 'HEAD^{tree}'],
            env=environment, text=True, shell=False)

    @unittest.skipUnless(ci.os.name == 'nt', 'Windows 原生 Git 入口契约')
    def test_windows_git_rejects_resolved_batch_entry(self):
        # 即使名为 git.exe 的入口解析到了批处理，也必须拒绝进入命令解释器。
        with patch.object(ci, 'system_tool', return_value='C:/tools/git.cmd'):
            with self.assertRaisesRegex(ValueError, '原生 EXE'):
                ci.git_executable()

    @unittest.skipUnless(ci.os.name == 'nt', 'Windows 原生 Git 入口契约')
    def test_windows_git_preserves_tree_expression_with_batch_shadowing(self):
        # depot_tools 可将 git.bat 放在 PATH 前端；对象表达式必须按原样交给原生 Git。
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, wrapper = root / 'source & literal', root / 'wrapper'
            wrapper.mkdir()
            (wrapper / 'git.bat').write_text('@echo off\nexit /b 87\n', encoding='ascii')
            native_git = ci.system_tool('git.exe')
            # 以下三个进程只建立本测试的临时仓库；原生绝对入口与固定子命令均不经 shell。
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
            subprocess.run([native_git, 'init', '-q', str(source)], check=True, shell=False)  # nosec B603
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
            subprocess.run([native_git, '-C', str(source), '-c', 'user.name=CI test',  # nosec B603
                            '-c', 'user.email=ci@example.invalid', 'commit',
                            '--allow-empty', '-qm', 'base'], check=True, shell=False)
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
            expected = subprocess.check_output(  # nosec B603
                [native_git, '-C', str(source), 'rev-parse', 'HEAD^{tree}'], text=True, shell=False).strip()
            with patch.dict(ci.os.environ, {'PATH': str(wrapper) + ci.os.pathsep + ci.os.environ['PATH']}):
                self.assertEqual(Path(ci.system_tool('git')).suffix.lower(), '.bat')
                self.assertEqual(ci.git(source, 'rev-parse', 'HEAD^{tree}'), expected)
                literal = 'literal & caret ^ value'
                ci.git(source, 'config', 'fixture.literal', literal)
                self.assertEqual(ci.git(source, 'config', '--get', 'fixture.literal'), literal)

    def test_windows_system_tool_uses_system_root(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(
                ci.os.environ, {'SystemRoot': directory}, clear=False):
            system32 = Path(directory) / 'System32'
            system32.mkdir()
            taskkill = system32 / 'taskkill.exe'
            taskkill.write_text('fixture')
            self.assertEqual(ci.windows_system_executable('taskkill.exe'),
                             str(taskkill.resolve()))

    def test_real_git_replay_detects_wrong_tree_and_preserves_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src, patches = root / 'src', root / 'patches'
            src.mkdir(); patches.mkdir()
            def git(*args):
                return subprocess.check_output(['git', '-C', str(src), *args], text=True).strip()
            git('init', '-q'); git('config', 'user.name', 'CI test'); git('config', 'user.email', 'ci@example.invalid')
            git('config', 'core.autocrlf', 'false')
            (src / 'code.txt').write_text('base\n', newline='\n')
            git('add', 'code.txt'); git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (src / 'code.txt').write_text('fixed\n', newline='\n')
            git('commit', '-qam', 'fix')
            # 补丁是 Git 输出的字节流，不能经平台换行转换后再重放。
            (patches / 'fix.patch').write_bytes(subprocess.check_output(
                ['git', '-C', str(src), 'format-patch', '-1', '--stdout']))
            (patches / 'series').write_text('fix.patch\n')
            fresh = root / 'fresh'
            # 克隆首次检出就必须固定 LF；之后再关闭 autocrlf 会把已检出的 CRLF 视为脏文件。
            # 模拟宿主启用自动换行，验证夹具不借用用户的 Git 配置才能通过。
            with patch.dict(ci.os.environ, {'GIT_CONFIG_COUNT': '1',
                    'GIT_CONFIG_KEY_0': 'core.autocrlf', 'GIT_CONFIG_VALUE_0': 'true'}):
                # 克隆源与目的地均为本测试创建的临时目录；使用已解析的原生 Git，禁用 shell。
                # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
                subprocess.run([ci.git_executable(), '-c', 'core.autocrlf=false', 'clone', '-q',  # nosec B603
                                str(src), str(fresh)], check=True, shell=False)
            subprocess.run(['git', '-C', str(fresh), 'config', 'core.autocrlf', 'false'], check=True)
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

    def test_replay_keeps_intermediate_objects_out_of_shared_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            src, patches = root / 'source with spaces', root / 'patches'
            src.mkdir(); patches.mkdir()
            def git(*args):
                return ci.git(src, *args)
            git('init', '-q'); git('config', 'user.name', 'CI test')
            git('config', 'user.email', 'ci@example.invalid')
            git('config', 'core.autocrlf', 'false')
            (src / 'value').write_text('base\n', newline='\n')
            git('add', 'value'); git('commit', '-qm', '基线')
            base = git('rev-parse', 'HEAD')
            for name in ('intermediate', 'final'):
                (src / 'value').write_text(name + '\n', newline='\n')
                git('commit', '-qam', name)
                (patches / (name + '.patch')).write_bytes(subprocess.check_output(
                    [ci.system_tool('git'), '-C', str(src), 'format-patch', '-1', '--stdout']))
            (patches / 'series').write_text('intermediate.patch\nfinal.patch\n')
            linked = root / 'linked worktree'
            git('worktree', 'add', '-q', '--detach', str(linked), 'HEAD')
            objects = src / '.git/objects'
            intermediate = git('rev-parse', 'HEAD^:value')
            missing_object = objects / intermediate[:2] / intermediate[2:]
            # 最终树与基线仍完整，只有重放过程需要的中间对象不存在。
            # Windows 的 Git 松散对象带只读属性；仅解除本测试创建的目标对象再模拟缺失。
            missing_object.chmod(0o600)
            missing_object.unlink()
            before = {p.relative_to(objects): p.read_bytes() for p in objects.rglob('*') if p.is_file()}
            expected_tree = git('rev-parse', 'HEAD^{tree}')
            real_git = ci.git

            def offline_git(source, *args, env=None):
                # 缺失对象不能让校验阶段自动联网；临时共享路径必须使用 LF，兼容 Windows Git。
                self.assertIsNotNone(env)
                self.assertEqual(env.get('GIT_NO_LAZY_FETCH'), '1')
                if 'GIT_OBJECT_DIRECTORY' in env:
                    alternate = Path(env['GIT_OBJECT_DIRECTORY']) / 'info/alternates'
                    self.assertEqual(alternate.read_bytes(), (objects.resolve().as_posix() + '\n').encode())
                return real_git(source, *args, env=env)

            for checkout in (src, linked):
                with self.subTest(checkout=checkout.name):
                    with patch.dict(ci.os.environ, {'GIT_NO_LAZY_FETCH': '0'}), patch.object(ci, 'git', offline_git):
                        self.assertEqual(ci.verify_tree(checkout, base, patches), expected_tree)
                    self.assertFalse(missing_object.exists())
                    self.assertEqual(
                        {p.relative_to(objects): p.read_bytes() for p in objects.rglob('*') if p.is_file()}, before)

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

    def test_patch_conflict_is_preserved_for_manual_review(self):
        source = inspect.getsource(ci.apply_if_base)
        self.assertIn("raise RuntimeError('补丁冲突已保留：' + name)", source)
        self.assertNotIn("'am', '--abort'", source)

    def test_candidate_workflow_is_manual_until_dedicated_runners_are_ready(self):
        workflow = (ci.ROOT / '.github/workflows/chromium-candidate.yml').read_text()
        trigger = workflow.split('permissions:', 1)[0]
        self.assertIn('workflow_dispatch:', trigger)
        self.assertNotIn('\n  push:', trigger)


if __name__ == '__main__':
    unittest.main()
