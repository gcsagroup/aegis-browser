"""发行资产真实临时文件与远端异常响应回归；不冒充发行产物验收。"""
import copy
import contextlib
import io
from unittest import mock
import importlib.util
import json
from pathlib import Path
import subprocess  # nosec B404 - 固定测试解释器与仓库脚本，不启用 shell。
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('release-assets.py')
spec = importlib.util.spec_from_file_location('release_assets', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseAssetsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.manifest = {'schemaVersion': 1, 'repository': module.REPOSITORY,
                         'productVersion': '2.0.0.106', 'previousProductVersion': '2.0.0.105',
                         'productCommit': 'a' * 40, 'assets': []}
        for platform in module.PLATFORMS:
            name = module.expected_name('2.0.0.106', platform, '154.0.8037.126')
            path = self.root / name
            path.write_bytes(b'fixture-only-' + platform.encode())
            self.manifest['assets'].append({'platform': platform, 'name': name,
                'chromiumVersion': '154.0.8037.126', 'size': path.stat().st_size, 'sha256': module.sha256(path)})

    def local(self):
        return module.check_local(self.manifest, self.root)

    def remote(self):
        local = self.local()
        base = f'https://github.com/{module.REPOSITORY}/releases'
        return {'tag_name': local['tag'], 'draft': True, 'prerelease': False,
                'html_url': base + '/untagged/fixture', 'assets': [
                    {**asset, 'state': 'uploaded', 'digest': 'sha256:' + asset['sha256'],
                     'browser_download_url': f"{base}/download/{local['tag']}/{asset['name']}"}
                    for asset in local['assets']]}

    def test_three_platform_consistency_is_not_release_qualification(self):
        checked = module.check_remote(self.local(), self.remote())
        self.assertTrue(checked['remoteAssetsVerified'])
        self.assertFalse(checked['releaseReady'])

    def test_cli_representative_input(self):
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps(self.manifest))
        # 当前解释器、固定仓库脚本和临时夹具独立传参，不接收外部命令文本。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python_exec_rule-subprocess-call-array
        result = subprocess.run([str(Path(sys.executable).resolve(strict=True)), str(SCRIPT.resolve()),  # nosec B603 - 可执行文件已解析，参数数组不经 shell。
                                 '--manifest', str(manifest), '--asset-dir', str(self.root)],
                                capture_output=True, text=True, timeout=30, shell=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)['assets']), 3)

    def test_cli_remote_readback_and_rejection(self):
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps(self.manifest))
        remote = self.root / 'remote.json'
        remote.write_text(json.dumps(self.remote()))
        base = [str(SCRIPT), '--manifest', str(manifest), '--asset-dir', str(self.root)]
        for extra, expected in [(['--release-json', str(remote)], 0),
                                (['--published'], 1),
                                (['--release-json', str(remote), '--published'], 1),
                                (['--release-json', str(self.root / 'missing.json')], 1)]:
            with self.subTest(extra=extra), mock.patch.object(sys, 'argv', base + extra), contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(module.main(), expected)
                self.assertFalse(json.loads(output.getvalue())['releaseReady'])
        manifest.write_text('{bad json')
        with mock.patch.object(sys, 'argv', base), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(module.main(), 1)

    def test_empty_and_oversized_package(self):
        path = self.root / self.manifest['assets'][0]['name']
        for size in (0, module.MAX_SIZE + 1):
            with self.subTest(size=size):
                # 稀疏夹具不分配2GiB真实空间；检查必须在读取摘要前拒绝。
                with path.open('wb') as stream:
                    stream.truncate(size)
                self.manifest['assets'][0]['size'] = size
                with self.assertRaisesRegex(ValueError, '大小不受'):
                    self.local()

    def test_missing_platform(self):
        self.manifest['assets'].pop()
        with self.assertRaisesRegex(ValueError, '三个平台'):
            self.local()

    def test_duplicate_platform(self):
        self.manifest['assets'][2] = self.manifest['assets'][0]
        with self.assertRaisesRegex(ValueError, '重复或缺失'):
            self.local()

    def test_corrupted_package(self):
        (self.root / self.manifest['assets'][0]['name']).write_bytes(b'corruption')
        with self.assertRaises(ValueError):
            self.local()

    def test_digest_mismatch(self):
        self.manifest['assets'][0]['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, '摘要'):
            self.local()

    def test_symlink_rejected(self):
        path = self.root / self.manifest['assets'][0]['name']
        target = self.root / 'target'
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaisesRegex(ValueError, '真实安装包'):
            self.local()

    def test_version_downgrade_and_noncanonical(self):
        for version in ('2.0.0.105', '2.0.0.104', '02.0.0.106', '154.0.8037', '2.0.0.2147483648'):
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.manifest['productVersion'] = version
                self.local()

    def test_wrong_asset_name(self):
        self.manifest['assets'][0]['name'] = '../../fake.dmg'
        with self.assertRaisesRegex(ValueError, '名称'):
            self.local()

    def test_remote_missing_duplicate_or_incomplete(self):
        good = self.remote()
        mutations = [lambda r: r['assets'].pop(), lambda r: r['assets'].append(r['assets'][0]),
                     lambda r: r['assets'][0].update(state='new'), lambda r: r['assets'][0].pop('digest'),
                     lambda r: r['assets'][0].update(size=True), lambda r: r['assets'][0].update(digest='sha256:' + '0' * 64),
                     lambda r: r['assets'][0].update(browser_download_url='https://example.com/file')]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                remote = copy.deepcopy(good)
                mutate(remote)
                with self.assertRaises(ValueError):
                    module.check_remote(self.local(), remote)

    def test_remote_wrong_repository_tag_or_state(self):
        for change in ({'tag_name': 'v2.0.0.1'}, {'draft': False}, {'prerelease': True},
                       {'html_url': 'https://github.com/other/repo/releases/untagged/test'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                module.check_remote(self.local(), {**self.remote(), **change})

    def test_published_readback(self):
        remote = self.remote()
        remote.update(draft=False, html_url=f"https://github.com/{module.REPOSITORY}/releases/tag/v2.0.0.106")
        self.assertFalse(module.check_remote(self.local(), remote, require_draft=False)['remoteDraft'])


if __name__ == '__main__':
    unittest.main()
