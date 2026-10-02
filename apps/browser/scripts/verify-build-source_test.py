"""真实小型 Git 仓库验证源码门禁，不启动 Chromium 编译。"""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('verify_source', Path(__file__).with_name('verify-build-source.py'))
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.src = root / 'src'
        self.browser = root / 'browser'
        self.src.mkdir()
        (self.browser / 'patches/v8').mkdir(parents=True)
        (self.browser / 'overlay').mkdir()
        self.init(self.src)
        v8 = self.src / 'v8'
        v8.mkdir()
        self.init(v8)
        (v8 / 'value').write_text('original\n')
        self.commit(v8, 'base')
        self.git(self.src, 'add', 'v8')
        (self.src / 'value').write_text('original\n')
        self.commit(self.src, 'base')
        (self.browser / 'CHROMIUM_COMMIT').write_text(self.git(self.src, 'rev-parse', 'HEAD'))
        for src, directory in [(self.src, self.browser / 'patches'), (v8, self.browser / 'patches/v8')]:
            (src / 'value').write_text('current\n')
            self.commit(src, 'patch')
            (directory / 'one.patch').write_text(self.git(src, 'format-patch', '-1', '--stdout') + '\n')
            (directory / 'series').write_text('one.patch\n')
        (self.browser / 'overlay/value').write_text('current\n')

    def git(self, src, *args):
        return subprocess.check_output(['git', '-C', str(src), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def init(self, src):
        self.git(src, 'init', '-q')
        self.git(src, 'config', 'user.name', 'Fixture')
        self.git(src, 'config', 'user.email', 'fixture@example.invalid')

    def commit(self, src, message):
        self.git(src, 'add', 'value')
        self.git(src, 'commit', '-qm', message)

    def test_current_source_and_overlay_pass_without_build_claim(self):
        result = check.verify_source(self.src, self.browser)
        self.assertTrue(result['sourceVerified'])
        self.assertFalse(result['built'])
        self.assertFalse(result['runtimeTested'])

    def test_unsaved_work_is_preserved(self):
        (self.src / 'value').write_text('do not overwrite\n')
        with self.assertRaisesRegex(ValueError, '未保存'):
            check.verify_source(self.src, self.browser)
        self.assertEqual((self.src / 'value').read_text(), 'do not overwrite\n')

    def test_stale_committed_tree_is_rejected(self):
        (self.src / 'value').write_text('old source\n')
        self.commit(self.src, 'unrelated')
        with self.assertRaisesRegex(ValueError, '源码与本次候选补丁不一致'):
            check.verify_source(self.src, self.browser)

    def test_wrong_v8_is_rejected(self):
        (self.src / 'v8/value').write_text('old v8\n')
        self.commit(self.src / 'v8', 'unrelated')
        with self.assertRaises(ValueError):
            check.verify_source(self.src, self.browser)

    def test_copied_v8_without_git_cannot_borrow_parent_identity(self):
        (self.src / 'v8/.git').rename(Path(self.temp.name) / 'saved-v8-git')
        with self.assertRaisesRegex(ValueError, '独立 Git 来源'):
            check.verify_source(self.src, self.browser)

    def test_overlay_mismatch_and_missing_file_are_rejected(self):
        (self.browser / 'overlay/value').write_text('unpublished\n')
        with self.assertRaisesRegex(ValueError, 'overlay'):
            check.verify_source(self.src, self.browser)
        (self.browser / 'overlay/value').unlink()
        (self.browser / 'overlay/missing').write_text('missing\n')
        with self.assertRaisesRegex(ValueError, 'overlay'):
            check.verify_source(self.src, self.browser)


if __name__ == '__main__':
    unittest.main()
