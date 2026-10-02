"""真实运行嵌套会话，验证停止、强制停止以及不误伤其他进程。"""
from pathlib import Path
import json
import signal
import subprocess  # nosec B404 - 使用参数数组且不启用 shell。
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from build_processes import processes, signal_group, stop_process_tree


class BuildProcessesTest(unittest.TestCase):
    def test_nested_session_and_unrelated_process(self):
        with tempfile.TemporaryDirectory() as path:
            ready = Path(path) / 'ready.json'
            child_code = ('import signal,time,sys,os,json; from pathlib import Path; '
                          'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
                          'Path(sys.argv[1]).write_text(json.dumps({"child":os.getpid()})); time.sleep(60)')
            parent_code = ('import subprocess,sys,json,time; from pathlib import Path; '
                           'p=subprocess.Popen([sys.executable,"-c",sys.argv[2],sys.argv[1]],start_new_session=True); '
                           'p.wait()')
            # 已审计：固定工具或测试解释器的 argv；无 shell，无外部命令文本。
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python_exec_rule-subprocess-call-array
            other = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)  # nosec B603
            # 已审计：固定工具或测试解释器的 argv；无 shell，无外部命令文本。
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python_exec_rule-subprocess-call-array
            root = subprocess.Popen([sys.executable, '-c', parent_code, str(ready), child_code], start_new_session=True)  # nosec B603
            child = None
            try:
                deadline = time.monotonic() + 5
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                child = json.loads(ready.read_text())['child']
                result = stop_process_tree(root.pid, timeout=0.3)
                self.assertEqual(set(result['groups']), {root.pid, child})
                self.assertIn(child, result['forcedGroups'])
                self.assertNotEqual(root.wait(timeout=3), 0)
                deadline = time.monotonic() + 3
                while any(p == child and not state.startswith('Z') for p, _, _, state in processes()) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertFalse(any(p == child and not state.startswith('Z') for p, _, _, state in processes()))
                self.assertIsNone(other.poll())
            finally:
                for pid in [root.pid, child, other.pid]:
                    if pid:
                        signal_group(pid, signal.SIGKILL)
                root.wait()
                other.wait()

    def test_nonisolated_child_is_refused_and_kept_alive(self):
        # 已审计：固定工具或测试解释器的 argv；无 shell，无外部命令文本。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python_exec_rule-subprocess-call-array
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])  # nosec B603
        try:
            with self.assertRaises(ValueError):
                stop_process_tree(child.pid)
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait()

    def test_finished_child_is_a_noop(self):
        # 已审计：固定工具或测试解释器的 argv；无 shell，无外部命令文本。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python_exec_rule-subprocess-call-array
        child = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)  # nosec B603
        child.wait()
        self.assertEqual(stop_process_tree(child.pid), {'groups': [], 'forcedGroups': []})

    def test_permission_error_with_live_process_is_not_hidden(self):
        with patch('build_processes.os.killpg', side_effect=PermissionError), \
                patch('build_processes.processes', return_value=[(23, 1, 23, 'S')]):
            with self.assertRaises(PermissionError):
                signal_group(23, signal.SIGCONT)

    def test_permission_error_after_group_exit_is_a_noop(self):
        for rows in [[], [(23, 1, 23, 'Z')]]:
            with self.subTest(rows=rows), \
                    patch('build_processes.os.killpg', side_effect=PermissionError), \
                    patch('build_processes.processes', return_value=rows):
                signal_group(23, signal.SIGCONT)

    def test_permission_error_recheck_failure_is_not_hidden(self):
        with patch('build_processes.os.killpg', side_effect=PermissionError), \
                patch('build_processes.processes', side_effect=OSError):
            with self.assertRaises(OSError):
                signal_group(23, signal.SIGCONT)


if __name__ == '__main__':
    unittest.main()
