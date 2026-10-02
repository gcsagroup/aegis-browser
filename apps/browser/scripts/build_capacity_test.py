"""容量门禁的边界、系统查询失败与恢复测试。"""
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch
import build_capacity as m


class CapacityTest(unittest.TestCase):
    def test_temporary_file_disappears_and_recovers(self):
        missing = subprocess.CompletedProcess([], 1, '10\t/tmp/work\n', 'du: /tmp/work/temp: No such file or directory\n')
        good = subprocess.CompletedProcess([], 0, '12\t/tmp/work\n', '')
        with tempfile.TemporaryDirectory() as path, patch.object(m.subprocess, 'run', side_effect=[missing, good]) as run:
            self.assertEqual(m.allocated_bytes(path), 12 * 1024)
            self.assertEqual(run.call_count, 2)

    def test_directory_errors_are_not_accepted_as_partial_totals(self):
        for error, calls in [('Permission denied', 1), ('No such file or directory', 3)]:
            result = subprocess.CompletedProcess([], 1, '1\t/tmp/work\n', 'du: /tmp/work/temp: ' + error + '\n')
            with tempfile.TemporaryDirectory() as path, patch.object(m.subprocess, 'run', return_value=result) as run:
                with self.assertRaises(OSError):
                    m.allocated_bytes(path)
                self.assertEqual(run.call_count, calls)

    def test_real_allocated_directory(self):
        with tempfile.TemporaryDirectory() as path:
            (Path(path) / 'input').write_bytes('输入'.encode() * 4096)
            self.assertGreaterEqual(m.allocated_bytes(path), (Path(path) / 'input').stat().st_blocks * 512)

    def test_purgeable_does_not_count_twice(self):
        result = m.evaluate(200 * m.GIB, 20 * m.GIB, 115 * m.GIB)
        self.assertTrue(result['allowed'])
        self.assertEqual(result['availableBytes'], 115 * m.GIB)

    def test_raw_reserve_wins_over_purgeable(self):
        self.assertFalse(m.evaluate(200 * m.GIB, 8 * m.GIB - 1, 115 * m.GIB)['allowed'])

    def test_important_capacity_boundary(self):
        self.assertFalse(m.evaluate(200 * m.GIB, 20 * m.GIB, 30 * m.GIB - 1)['allowed'])
        self.assertTrue(m.evaluate(200 * m.GIB, 8 * m.GIB, 30 * m.GIB)['allowed'])

    def test_no_api_keeps_old_limit(self):
        self.assertFalse(m.evaluate(200 * m.GIB, 20 * m.GIB)['allowed'])
        self.assertTrue(m.evaluate(200 * m.GIB, 30 * m.GIB)['allowed'])

    def test_invalid_capacity(self):
        for free, important in [(-1, None), (201, None), (20, -1), (20, 201)]:
            with self.subTest(free=free, important=important), self.assertRaises(ValueError):
                m.evaluate(200, free, important)

    def test_query_failure_and_recovery(self):
        usage = type('Usage', (), {'total': 200 * m.GIB, 'free': 20 * m.GIB})()
        with tempfile.TemporaryDirectory() as path, patch.object(m.sys, 'platform', 'darwin'), patch.object(m.shutil, 'disk_usage', return_value=usage):
            with patch.object(m, 'important_capacity', side_effect=OSError('合成查询失败')):
                failed = m.snapshot(path)
                self.assertFalse(failed['allowed'])
                self.assertEqual(failed['capacitySource'], 'free_only')
                self.assertIn('合成查询失败', failed['queryError'])
            with patch.object(m, 'important_capacity', return_value=115 * m.GIB):
                self.assertTrue(m.snapshot(path)['allowed'])

    def test_invalid_path(self):
        with tempfile.TemporaryDirectory() as path, self.assertRaises(FileNotFoundError):
            m.snapshot(Path(path) / '不存在')


if __name__ == '__main__':
    unittest.main()
