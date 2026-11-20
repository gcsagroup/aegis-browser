"""用真实的嵌套 Git 仓库验证 Windows 启动器的同步、重试及构建失败边界。"""

import os
from pathlib import Path
import shutil
# 夹具进程通过共用参数校验器执行，测试不接受外部命令文本。
import subprocess  # nosec B404
import sys
import tempfile
import unittest
from unittest.mock import patch

import windows_browser as launcher
from chromium_access_gtests import command_argv, run_process, tool
from windows_browser_sync import checked_path, git


class WindowsBrowserTests(unittest.TestCase):
    """模拟一个打过旧补丁的 Chromium checkout 和一份独立的产品工作区。"""

    def setUp(self):
        # 将临时项目放在本地工作区。Windows PowerShell 的 RemoteSigned 可能将沙箱重定向的
        # TEMP 识别为网络位置；真实入口测试应沿用脚本执行策略。
        artifacts = launcher.PROJECT / ".artifacts"
        artifacts.mkdir(exist_ok=True)
        temp = tempfile.TemporaryDirectory(dir=artifacts, prefix="windows-start-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.project = self.root / "product"
        # 空格和 shell 元字符必须作为本地路径原样传递，不能被当成额外命令。
        self.checkout = self.root / "build space & literal"
        self.src = self.checkout / "src"
        self.browser = self.project / "apps/browser"
        self.overlay = self.browser / "overlay"
        self.cache = self.src / "out/.aegis-dev-sync"
        self.state = self.cache / "state.json"
        self.v8 = self.src / "v8"
        for repo in (self.project, self.src, self.v8):
            repo.mkdir(parents=True, exist_ok=True)
            git(repo, "init", "-q")
            git(repo, "config", "user.name", "Fixture")
            git(repo, "config", "user.email", "test@example.invalid")
        self.v8_oid = self.make_patch(self.v8, "engine", self.browser / "patches/v8")
        git(self.src, "update-index", "--add", "--cacheinfo", "160000," + self.v8_oid + ",v8")
        base = self.make_patch(self.src, "native", self.browser / "patches")
        (self.browser / "CHROMIUM_COMMIT").write_text(base)
        args = self.project / launcher.GN_ARGS
        args.parent.mkdir()
        args.write_bytes(b"is_debug=false\n")
        self.overlay.mkdir()
        (self.overlay / "old").write_bytes(b"once\n")
        (self.overlay / "native").write_bytes(b"tracked\n")
        git(self.project, "add", ".")
        git(self.project, "commit", "-qm", "product")

    def make_patch(self, repo, name, directory):
        """生成能实际应用的补丁，V8 的基线由 Chromium gitlink 固定。"""
        file = repo / name
        file.write_bytes(b"base\n")
        git(repo, "add", "--", name)
        git(repo, "commit", "-qm", "base")
        file.write_bytes(b"patched\n")
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "one.patch").write_bytes(git(repo, "diff", "--full-index", "--", name))
        (directory / "series").write_text("one.patch\n")
        git(repo, "restore", "--", name)
        return git(repo, "rev-parse", "HEAD").decode().strip()

    def sync(self, check=False):
        return launcher.synchronize(self.project, self.src, self.cache, self.state, check)

    def test_worktree_new_file_deletion_patch_change_and_incremental_rerun(self):
        # 本地 overlay 优先于补丁，新增二进制、删除和 V8 补丁均进入同一编译树。
        (self.overlay / "native").write_bytes(b"dev\r\n")
        (self.overlay / "space name").write_bytes(b"\x00\r\n")
        self.sync(check=True)
        self.assertFalse(self.state.exists())
        self.assertEqual((self.src / "native").read_bytes(), b"base\n")
        self.sync()
        self.assertEqual((self.src / "native").read_bytes(), b"dev\r\n")
        self.assertEqual((self.v8 / "engine").read_bytes(), b"patched\n")
        self.assertEqual((self.src / "space name").read_bytes(), b"\x00\r\n")
        timestamp = (self.src / "native").stat().st_mtime_ns
        (self.overlay / "old").unlink()
        (self.overlay / "space name").unlink()
        p = self.browser / "patches/v8/one.patch"
        p.write_bytes(p.read_bytes().replace(b"+patched", b"+updated"))
        self.sync()
        self.assertFalse((self.src / "old").exists())
        self.assertFalse((self.src / "space name").exists())
        self.assertEqual((self.v8 / "engine").read_bytes(), b"updated\n")
        self.assertEqual((self.src / "native").stat().st_mtime_ns, timestamp)
        self.assertFalse(git(self.src, "diff", "--cached", "--name-only"))

    def test_conflict_in_v8_preserves_both_worktrees(self):
        # 第二棵树的冲突必须阻止第一棵树写入，之后可正常重试。
        (self.v8 / "engine").write_bytes(b"local-only")
        with self.assertRaisesRegex(ValueError, "engine"):
            self.sync()
        self.assertEqual((self.src / "native").read_bytes(), b"base\n")
        self.assertEqual((self.v8 / "engine").read_bytes(), b"local-only")
        self.assertFalse(self.state.exists())

    def test_initial_known_patch_version_and_later_user_rollback(self):
        # 接管时可升级已归档的补丁文件；以后开发者主动改回同一旧内容仍然属于本地修改。
        (self.src / "native").write_bytes(b"patched\n")
        self.sync()
        self.assertEqual((self.src / "native").read_bytes(), b"tracked\n")
        (self.src / "native").write_bytes(b"patched\n")
        with self.assertRaisesRegex(ValueError, "native"):
            self.sync()

    def test_file_added_then_removed_in_series_is_retired_on_first_run(self):
        # 已安装中间补丁的工作树会残留旧文件，即使最终补丁树和上游基线都没有它。
        file = self.src / "obsolete"
        file.write_bytes(b"old feature\n")
        git(self.src, "add", "obsolete")
        patches = self.browser / "patches"
        diff = git(self.src, "diff", "--cached", "--full-index", "--", "obsolete")
        (patches / "add.patch").write_bytes(diff)
        (patches / "drop.patch").write_bytes(git(self.src, "diff", "--cached", "-R", "--full-index", "--", "obsolete"))
        (patches / "series").write_text("one.patch\nadd.patch\ndrop.patch\n")
        git(self.src, "restore", "--staged", "--", "obsolete")
        self.sync()
        self.assertFalse(file.exists())

    def test_resume_after_partial_sync_and_new_product_edit(self):
        # Chromium 已写入、V8 尚未写入时中断，重试可继续同步新的产品输入。
        original = launcher.apply_changes
        def fail_second(tree, changes):
            if tree.src == self.v8:
                raise OSError("interrupted")
            original(tree, changes)
        with patch.object(launcher, "apply_changes", side_effect=fail_second):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.sync()
        (self.overlay / "native").write_bytes(b"newest\n")
        self.sync()
        self.assertEqual((self.src / "native").read_bytes(), b"newest\n")
        self.assertEqual((self.v8 / "engine").read_bytes(), b"patched\n")

    def test_build_before_launch_and_unlock_on_failure(self):
        # 固定输出执行 GN/Ninja，仅成功后启动独立 profile；编译失败释放共享锁。
        for name in ("third_party/ninja/ninja.exe", "buildtools/win/gn.exe"):
            tool = self.src / name
            tool.parent.mkdir(parents=True, exist_ok=True)
            tool.touch()
        with patch.object(launcher, "synchronize", return_value=True), patch.dict(os.environ, LOCALAPPDATA=str(self.root)):
            with patch.object(launcher, "run_process") as command, patch("windows_browser.subprocess.Popen") as start:
                # GN 发现非法依赖时应立即退出，不能使用旧构建图继续编译或启动。
                command.side_effect = subprocess.CalledProcessError(1, "gn")
                with self.assertRaises(subprocess.CalledProcessError):
                    launcher.run(self.project, self.checkout, 2, False)
                command.assert_called_once_with(
                    [str(self.src / "buildtools/win/gn.exe"), "gen", "out/AegisRelease", "--check"],
                    cwd=self.src, output=None)
                start.assert_not_called()
                command.side_effect = [None, subprocess.CalledProcessError(1, "ninja")]
                with self.assertRaises(subprocess.CalledProcessError):
                    launcher.run(self.project, self.checkout, 2, False)
                start.assert_not_called()
                self.assertFalse((self.checkout / ".aegis-ci-lock").exists())
                command.side_effect = None
                # 工具返回成功也不能启动不存在的浏览器；先报告失败并释放源码锁。
                with self.assertRaises(FileNotFoundError):
                    launcher.run(self.project, self.checkout, 2, False)
                start.assert_not_called()
                self.assertFalse((self.checkout / ".aegis-ci-lock").exists())
                binary = self.src / "out/AegisRelease/chrome.exe"
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.touch()
                launcher.run(self.project, self.checkout, 2, False)
                self.assertEqual(command.call_args.args[0][-3:], ["-j", "2", "chrome"])
                self.assertIn("--user-data-dir=" + str(self.root / "Aegis-Dev"), start.call_args.args[0])

    def test_unsafe_source_paths_rejected(self):
        # 不允许清单、补丁或 overlay 通过特殊 Windows 路径写到源码边界外。
        for path in ("../escape", ".git/config", "C:/outside", "out/AegisRelease/chrome.exe", "foo:N", "aux/file"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                checked_path(self.src, path)

    @unittest.skipUnless(os.name == "nt", "Windows 入口集成测试")
    def test_root_powershell_entry(self):
        # 从真实根脚本运行控制流程；三个 Windows 进程替代昂贵的 Chromium 编译和图形窗口。
        runner = self.project / "scripts/dev"
        runner.mkdir(parents=True)
        for name in ("windows_browser.py", "windows_browser_sync.py", "chromium_access_gtests.py"):
            shutil.copyfile(Path(__file__).with_name(name), runner / name)
        entry = self.project / "Start-Aegis.ps1"
        shutil.copyfile(launcher.PROJECT / entry.name, entry)
        (self.browser / ".chromium-root").write_text(str(self.checkout), encoding="utf-8")
        source = self.root / "Tool.cs"
        source.write_text("""
using System;
using System.IO;
using System.Diagnostics;
class Tool {
    static int Main(string[] args) {
        var name = Process.GetCurrentProcess().ProcessName;
        File.AppendAllText(Environment.GetEnvironmentVariable("AEGIS_TEST_TRACE"), name + " " + string.Join("|", args) + "\\n");
        return name == "ninja" && Environment.GetEnvironmentVariable("AEGIS_TEST_FAIL") == "1" ? 9 : 0;
    }
}""", encoding="utf-8")
        executable = self.root / "tool.exe"
        csc = Path(os.environ["SystemRoot"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
        run_process([str(csc), "/nologo", "/out:" + str(executable), str(source)], output=None)
        for name in ("buildtools/win/gn.exe", "third_party/ninja/ninja.exe", "out/AegisRelease/chrome.exe"):
            target = self.src / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(executable, target)
        trace = self.root / "trace"
        env = dict(os.environ, AEGIS_TEST_TRACE=str(trace), LOCALAPPDATA=str(self.root),
                   CHROMIUM_ROOT="", PATH=str(Path(sys.executable).parent) + os.pathsep + os.environ["PATH"])
        command = command_argv([
            tool("powershell.exe", env), "-NoProfile", "-ExecutionPolicy", "RemoteSigned", "-File", str(entry),
        ])
        # 只执行本测试生成的入口，绝对路径及参数已经校验；保持超时以防夹具意外挂起。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        started = subprocess.run(command, cwd=self.project, env=env, capture_output=True,  # nosec B603
                                 timeout=90, shell=False)
        self.assertEqual(started.returncode, 0, (started.stdout + started.stderr).decode(errors="replace"))
        self.assertEqual(trace.read_text().splitlines(), [
            "gn gen|out/AegisRelease|--check", "ninja -C|out/AegisRelease|-j|4|chrome",
            "chrome --user-data-dir=" + str(self.root / "Aegis-Dev")])
        self.assertEqual((self.src / "native").read_bytes(), b"tracked\n")
        trace.unlink()
        # 沿用相同受控入口，仅切换夹具失败标记，确认构建失败不会启动浏览器。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        failed = subprocess.run(command, cwd=self.project, env=dict(env, AEGIS_TEST_FAIL="1"),  # nosec B603
                                capture_output=True, timeout=90, shell=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertNotIn("chrome --user-data-dir", trace.read_text())


if __name__ == "__main__":
    unittest.main()
