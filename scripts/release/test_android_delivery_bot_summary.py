"""Exercise the Android controller shell boundary with a controlled child process."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ci/run-android-delivery-bot.sh'
RECEIPT = 'Known producer: https://github.com/gcsagroup/aegis-browser/actions/runs/200'


class BotSummaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='aegis-android-bot-summary-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.commands = self.root / '_runner_file_commands'
        self.commands.mkdir()
        self.summary = self.commands / 'step_summary_fixture'
        self.summary.write_text('')
        binary = self.root / 'bin'
        binary.mkdir()
        node = binary / 'node'
        node.write_text('#!/bin/sh\nprintf "%s\\n" "' + RECEIPT + '"\nexit "${BOT_TEST_EXIT:-0}"\n')
        node.chmod(0o700)
        self.environment = dict(os.environ, RUNNER_TEMP=str(self.root), GITHUB_STEP_SUMMARY=str(self.summary),
                                PATH=str(binary) + os.pathsep + os.environ['PATH'])

    def run_controller(self, **changes):
        return subprocess.run(['bash', str(SCRIPT)], cwd=ROOT, env=dict(self.environment, **changes),
                              text=True, capture_output=True, timeout=10)

    def test_success_and_failed_child_both_retain_the_known_receipt(self):
        for status in (0, 7):
            with self.subTest(status=status):
                self.summary.write_text('')
                result = self.run_controller(BOT_TEST_EXIT=str(status))
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertIn(RECEIPT, result.stdout)
                self.assertIn(RECEIPT, self.summary.read_text())

    def test_outside_path_symlink_and_traversal_never_start_the_child(self):
        outside = self.root / 'outside'
        outside.write_text('untouched')
        result = self.run_controller(GITHUB_STEP_SUMMARY=str(outside))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(RECEIPT, result.stdout)
        self.assertEqual(outside.read_text(), 'untouched')
        self.summary.unlink()
        self.summary.symlink_to(outside)
        result = self.run_controller()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(outside.read_text(), 'untouched')
        self.summary.unlink()
        self.commands.rmdir()
        other = self.root / 'other'
        other.mkdir()
        (other / 'step_summary_fixture').write_text('untouched')
        self.commands.symlink_to(other, target_is_directory=True)
        result = self.run_controller()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((other / 'step_summary_fixture').read_text(), 'untouched')


if __name__ == '__main__':
    unittest.main()
