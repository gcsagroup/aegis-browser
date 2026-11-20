"""校验主分支历史补丁来源及 Chromium 153 活动合并补丁的覆盖文件。"""
import hashlib
import json
from pathlib import Path
import re
# Local tooling uses argument arrays with the shell disabled.
import subprocess  # nosec B404
import tempfile
import unittest

BROWSER = Path(__file__).resolve().parents[1]
PATCHES = BROWSER / 'patches'
ARCHIVE = PATCHES / 'archive/main-151'


def entries(text):
    return [line.strip() for line in text.splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def validate_series(active, archived, replacement):
    if active.count(replacement) != 1:
        raise ValueError('活动系列必须包含且只包含一个主分支合并补丁')
    if set(active) & set(archived):
        raise ValueError('不能把已归档的 Chromium 151 补丁再次应用到 153')


def git_blob_hash(data):
    # Git 对象地址兼容校验；不将 SHA1 用于安全签名或抗篡改。
    # nosemgrep: python.lang.security.insecure-hash-algorithms.insecure-hash-algorithm-sha1
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data,
                        usedforsecurity=False).hexdigest()


class MergedMainPatchTests(unittest.TestCase):
    def test_active_access_patches_replay_to_overlay(self):
        targets = [
            'chrome/browser/aegis/access/access_site_proxy_bubble_controller.cc',
            'chrome/browser/aegis/access/access_site_proxy_bubble_controller.h',
            'chrome/browser/aegis/access/access_account_mac.h',
            'chrome/browser/aegis/access/access_account_mac.mm',
            'chrome/browser/aegis/aegis_service_access_account_mac.mm',
            # Windows 启动及网络环境修复必须随补丁交付，不能只在本机 overlay 生效。
            'chrome/browser/aegis/access/BUILD.gn',
            'chrome/browser/aegis/access/access_local_core_win.cc',
            'chrome/browser/aegis/access/access_local_core_win.h',
            'chrome/browser/aegis/access/access_local_core_win_test_child.cc',
            'chrome/browser/aegis/access/access_local_core_win_unittest.cc',
        ]
        with tempfile.TemporaryDirectory(prefix='aegis-controller-patches-') as root:
            # Fixed local test program and fixture arguments; shell execution is disabled.
            subprocess.run(['git', 'init', '--quiet', root], check=True,  # nosec B607, B603
                           capture_output=True, timeout=30)
            for name in entries((PATCHES / 'series').read_text()):
                patch = PATCHES / name
                text = patch.read_text()
                if not any(f'diff --git a/{target} b/{target}\n' in text
                           for target in targets):
                    continue
                # Fixed local test program and fixture arguments; shell execution is disabled.
                result = subprocess.run(  # nosec B607, B603
                    ['git', '-C', root, 'apply',
                     *[f'--include={target}' for target in targets], str(patch)],
                    capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(result.returncode, 0, f'{name}: {result.stderr}')
            for target in targets:
                self.assertEqual(
                    git_blob_hash((Path(root) / target).read_bytes()),
                    git_blob_hash((BROWSER / 'overlay' / target).read_bytes()),
                    target,
                )

    def test_access_core_uses_same_sources_in_desktop_and_android(self):
        prefix = 'components/aegis_access'
        overlay = BROWSER / 'overlay' / prefix
        manifest = json.loads((overlay / 'access_sources.json').read_text())
        files = [file for module in manifest['core'].values() for file in module]
        files += list(manifest['test_support'].values())
        for key in ['route_planner_vectors', 'policy_matcher_vectors']:
            files += [manifest[key]['input'], manifest[key]['script']]
        self.assertEqual(len(files), len(set(files)))
        files.append('access_sources.json')
        targets = [f'{prefix}/{file}' for file in files]

        for patchdir in [PATCHES, BROWSER / 'patches-android']:
            with self.subTest(series=patchdir.name), tempfile.TemporaryDirectory(
                    prefix='aegis-core-patches-') as repo:
                subprocess.run(['git', 'init', '--quiet', repo], check=True,  # nosec B607, B603
                               capture_output=True, timeout=30)
                for name in entries((patchdir / 'series').read_text()):
                    patch = patchdir / name
                    text = patch.read_text()
                    if f'diff --git a/{prefix}/' not in text:
                        continue
                    result = subprocess.run(  # nosec B607, B603
                        ['git', '-C', repo, 'apply',
                         f'--include={prefix}/*', str(patch)],
                        capture_output=True, text=True, timeout=30,
                    )
                    self.assertEqual(result.returncode, 0, f'{name}: {result.stderr}')
                # Check the platform's native target after replay. Android builds
                # use their own patch series and never copy the desktop overlay.
                component = Path(repo) / prefix
                build = (component / 'BUILD.gn').read_text()
                target = re.search(r'^source_set\("aegis_access"\) \{(.*?)^\}', build, re.M | re.S)
                self.assertIsNotNone(target)
                sources = re.search(r'sources = \[(.*?)\]', target[1], re.S)
                self.assertIsNotNone(sources)
                for file in re.findall(r'"([^"]+)"', sources[1]):
                    self.assertTrue((component / file).is_file(), f'{patchdir.name}: {file}')
                for file, path in zip(files, targets):
                    self.assertEqual(git_blob_hash((Path(repo) / path).read_bytes()),
                                     git_blob_hash((overlay / file).read_bytes()), path)

    def test_active_patches_exclude_generated_bytecode(self):
        for name in entries((PATCHES / 'series').read_text()):
            patch = (PATCHES / name).read_text()
            paths = re.findall(r'^diff --git a/[^\n]+ b/([^\n]+)', patch, re.M)
            for path in paths:
                self.assertNotIn('__pycache__', Path(path).parts, name)
                self.assertNotIn(Path(path).suffix, {'.pyc', '.pyo'}, name)

    def test_archive_identity_and_active_overlay(self):
        manifest = json.loads((ARCHIVE / 'manifest.json').read_text())
        archived = entries((ARCHIVE / 'series').read_text())
        self.assertEqual(archived, list(manifest['patches']))
        self.assertEqual(len(archived), len(set(archived)))
        for name, expected in manifest['patches'].items():
            self.assertEqual(hashlib.sha256((ARCHIVE / name).read_bytes()).hexdigest(),
                             expected, name)
        active = entries((PATCHES / 'series').read_text())
        validate_series(active, archived, manifest['replacement'])
        changed = set()
        final_blobs = {}
        # 后续修复补丁可以继续修改合并覆盖文件，最终内容仍须逐文件吻合。
        for patch_name in active[active.index(manifest['replacement']):]:
            patch = (PATCHES / patch_name).read_text()
            blocks = re.split(r'^diff --git a/[^\n]+ b/', patch, flags=re.M)[1:]
            for block in blocks:
                name = block.splitlines()[0]
                if patch_name == manifest['replacement']:
                    changed.add(name)
                match = re.search(r'^index [0-9a-f]+\.\.([0-9a-f]{40})', block, re.M)
                self.assertIsNotNone(match, name)
                final_blobs[name] = match[1]
        checked = 0
        for name, expected in final_blobs.items():
            overlay = BROWSER / 'overlay' / name
            if not overlay.is_file():
                continue
            self.assertEqual(git_blob_hash(overlay.read_bytes()), expected, name)
            checked += 1
        self.assertGreater(checked, 100)
        for name in [
            'components/aegis_access/access_route_planner.cc',
            'chrome/browser/aegis/access/access_proxying_url_loader_factory.cc',
            'chrome/browser/aegis/agent/agent_model_router.cc',
            'chrome/browser/aegis/agent/agent_task_store.cc',
            'content/browser/loader/prefetch_url_loader_service_context.cc',
        ]:
            self.assertIn(name, changed)

    def test_rejects_missing_or_duplicate_integration_patch(self):
        for active in [[], ['merged.patch', 'merged.patch']]:
            with self.assertRaises(ValueError):
                validate_series(active, ['old.patch'], 'merged.patch')

    def test_rejects_reapplying_archived_patch(self):
        with self.assertRaises(ValueError):
            validate_series(['old.patch', 'merged.patch'], ['old.patch'], 'merged.patch')


if __name__ == '__main__':
    unittest.main()
