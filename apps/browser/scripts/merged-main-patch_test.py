"""校验主分支历史补丁来源及 Chromium 153 活动合并补丁的覆盖文件。"""
import hashlib
import json
from pathlib import Path
import re
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
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


class MergedMainPatchTests(unittest.TestCase):
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
