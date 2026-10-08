"""发行编排状态机回归；全部上传/公开操作使用本地替身，不是线上验收。"""
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess  # nosec B404 - 固定解释器的本地 CLI 回归，不调用远端发布。
import sys
from types import SimpleNamespace
import unittest
from unittest import mock


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


module = load('release_github', 'release-github.py')
fixtures = load('release_fixture', 'release-assets_test.py')


class FakeGitHub:
    def __init__(self, test):
        self.test = test
        self.rows = []
        self.calls = []
        self.push = True
        self.private = False
        self.sha = 'a' * 40
        self.compare = 'identical'
        self.failure = None

    def api(self, endpoint):
        if endpoint == module.PREFIX:
            return {'permissions': {'push': self.push}, 'default_branch': 'main', 'private': self.private}
        if '/commits/' in endpoint:
            return {'sha': self.sha}
        if '/compare/' in endpoint:
            return {'status': self.compare}
        if endpoint.endswith('/releases/latest'):
            return copy.deepcopy(self.rows[0])
        raise AssertionError(endpoint)

    def releases(self):
        return copy.deepcopy(self.rows)

    def mutate(self, args):
        self.calls.append(args)
        if args[0] == self.failure:
            raise ValueError('模拟网络中断')
        if args[0] == 'create':
            self.rows = [self.test.remote()]
            self.rows[0].update(id=17, body='安全修复、兼容验证、限制与恢复办法。', assets=[])
        elif args[0] == 'upload':
            name = Path(args[2]).name
            self.rows[0]['assets'].extend(a for a in self.test.remote()['assets'] if a['name'] == name)
        elif args[0] == 'edit':
            self.rows[0].update(draft=False, html_url=f'https://github.com/{module.REPO}/releases/tag/v2.0.0.106')
        else:
            raise AssertionError(args)


class ReleaseGitHubTests(unittest.TestCase):
    setUp = fixtures.ReleaseAssetsTests.setUp
    local = fixtures.ReleaseAssetsTests.local
    remote = fixtures.ReleaseAssetsTests.remote

    def setup_receipts(self):
        self.notes = self.root / 'notes.md'
        self.notes.write_text('安全修复、兼容验证、限制与恢复办法。')
        log = self.root / 'fixture.log'
        log.write_text('仅测试夹具，不是真实签名或设备验收。')
        evidence = {'status': 'passed', 'file': log.name, 'sha256': module.assets.sha256(log)}
        checks = module.CHECKS + ('notarization', 'package_identity', 'signer_continuity', 'version_code_increase', 'install_confirmation')
        self.receipt = {'schemaVersion': 1, 'productCommit': 'a' * 40, 'productVersion': '2.0.0.106',
                        'platforms': {a['platform']: {'artifactSha256': a['sha256'], 'checks': {c: dict(evidence) for c in checks}}
                                      for a in self.local()['assets']}}
        features, feature_hash = module.contract.load(module.BROWSER)
        self.receipt['featureContractSha256'] = feature_hash
        for platform, row in self.receipt['platforms'].items():
            row['featureContractSha256'] = feature_hash
            row['featureChecks'] = {f['id']: {**evidence, 'executed': 1}
                                    for f in features['features'] if platform in f['platforms']}
        self.receipt_path = self.root / 'qualification.json'
        self.save_receipt()
        self.gh = FakeGitHub(self)

    def save_receipt(self):
        self.receipt_path.write_text(json.dumps(self.receipt))

    def run_stage(self, stage):
        return module.execute(self.manifest, self.root, self.receipt_path, self.notes, stage, self.gh)

    def test_new_function_missing_or_stale_receipt_blocks_publication(self):
        self.setup_receipts()
        for platform in module.assets.PLATFORMS:
            self.setup_receipts()
            self.receipt['platforms'][platform]['featureChecks'].pop('kAegisAgent')
            self.save_receipt()
            with self.assertRaisesRegex(ValueError, 'kAegisAgent'):
                self.run_stage('prepare')
            self.assertEqual(self.gh.calls, [])
        self.setup_receipts()
        self.receipt['featureContractSha256'] = '0' * 64
        self.save_receipt()
        with self.assertRaisesRegex(ValueError, '功能清单已变化'):
            self.run_stage('publish')
        self.assertEqual(self.gh.calls, [])

    def test_preflight_does_not_mutate(self):
        self.setup_receipts()
        self.assertEqual(self.run_stage('preflight')['status'], 'preflight_passed')
        self.assertEqual(self.gh.calls, [])

    def test_prepare_publish_and_idempotent_resume(self):
        self.setup_receipts()
        self.assertEqual(self.run_stage('prepare')['status'], 'draft_assets_verified')
        self.assertEqual([c[0] for c in self.gh.calls], ['create', 'upload', 'upload', 'upload'])
        count = len(self.gh.calls)
        self.run_stage('prepare')
        self.assertEqual(len(self.gh.calls), count)
        result = self.run_stage('publish')
        self.assertEqual(result['status'], 'published_verified')
        self.assertFalse(result['releaseReady'])
        self.assertEqual(result['oldClientUpdateAcceptance'], 'pending')
        count = len(self.gh.calls)
        self.assertEqual(self.run_stage('publish')['status'], 'published_existing_verified')
        self.assertEqual(len(self.gh.calls), count)
        self.assertNotIn('--clobber', str(self.gh.calls))

    def test_upload_interruption_resumes_same_draft(self):
        self.setup_receipts()
        self.gh.failure = 'upload'
        with self.assertRaisesRegex(ValueError, '网络中断'):
            self.run_stage('prepare')
        self.gh.failure = None
        self.run_stage('prepare')
        self.assertEqual(sum(c[0] == 'create' for c in self.gh.calls), 1)

    def test_missing_package_cannot_create_draft(self):
        self.setup_receipts()
        (self.root / self.manifest['assets'][1]['name']).unlink()
        with self.assertRaises(ValueError):
            self.run_stage('prepare')
        self.assertEqual(self.gh.calls, [])

    def test_permission_tag_and_default_branch_gates(self):
        self.setup_receipts()
        for field, bad in [('push', False), ('private', True), ('sha', 'b' * 40), ('compare', 'diverged'), ('compare', 'ahead')]:
            with self.subTest(field=field):
                self.gh = FakeGitHub(self)
                setattr(self.gh, field, bad)
                with self.assertRaises(ValueError):
                    self.run_stage('prepare')
                self.assertEqual(self.gh.calls, [])

    def test_qualification_requires_every_platform_check(self):
        self.setup_receipts()
        good = copy.deepcopy(self.receipt)
        for platform, row in good['platforms'].items():
            for check in row['checks']:
                if check not in module.CHECKS and platform == 'win-x64':
                    continue
                if check == 'notarization' and platform != 'mac-arm64':
                    continue
                if check in ('package_identity', 'signer_continuity', 'version_code_increase', 'install_confirmation') and platform != 'android-arm64':
                    continue
                with self.subTest(platform=platform, check=check):
                    self.receipt = copy.deepcopy(good)
                    self.receipt['platforms'][platform]['checks'][check]['status'] = 'pending'
                    self.save_receipt()
                    with self.assertRaisesRegex(ValueError, '尚未通过'):
                        self.run_stage('prepare')
        self.assertEqual(self.gh.calls, [])

    def test_receipt_wrong_identity_and_tampered_log(self):
        self.setup_receipts()
        for field in ('productCommit', 'productVersion'):
            good = self.receipt[field]
            self.receipt[field] = 'wrong'
            self.save_receipt()
            with self.assertRaises(ValueError):
                self.run_stage('prepare')
            self.receipt[field] = good
        self.save_receipt()
        (self.root / 'fixture.log').write_text('changed')
        with self.assertRaisesRegex(ValueError, '摘要'):
            self.run_stage('prepare')

    def test_receipt_outside_directory_is_rejected(self):
        self.setup_receipts()
        self.receipt['platforms']['mac-arm64']['checks']['signature']['file'] = '../escape'
        self.save_receipt()
        with self.assertRaises(ValueError):
            self.run_stage('prepare')

    def test_conflicting_draft_asset_is_never_overwritten(self):
        self.setup_receipts()
        self.run_stage('prepare')
        self.gh.rows[0]['assets'][0]['digest'] = 'sha256:' + '0' * 64
        count = len(self.gh.calls)
        for stage in ('prepare', 'publish'):
            with self.assertRaises(ValueError):
                self.run_stage(stage)
        self.assertEqual(len(self.gh.calls), count)

    def test_publish_requires_all_assets(self):
        self.setup_receipts()
        with self.assertRaises(ValueError):
            self.run_stage('publish')
        self.run_stage('prepare')
        self.gh.rows[0]['assets'].pop()
        with self.assertRaises(ValueError):
            self.run_stage('publish')
        self.assertNotIn('edit', [c[0] for c in self.gh.calls])

    def test_newer_release_duplicate_draft_or_changed_notes_blocks(self):
        self.setup_receipts()
        self.run_stage('prepare')
        good = copy.deepcopy(self.gh.rows)
        variants = [good + good, good + [{'tag_name': 'v2.0.0.107', 'draft': False, 'prerelease': False}],
                    [{**good[0], 'body': 'unexpected'}], [{**good[0], 'prerelease': True}]]
        for rows in variants:
            with self.subTest(rows=rows):
                self.gh.rows = rows
                with self.assertRaises(ValueError):
                    self.run_stage('publish')
        self.assertNotIn('edit', [c[0] for c in self.gh.calls])

    def test_git_cli_failure_cannot_be_treated_as_no_release(self):
        result = SimpleNamespace(returncode=1, stdout='', stderr='sensitive diagnostic')
        with mock.patch.object(module.shutil, 'which', return_value=sys.executable), \
                mock.patch.object(module.subprocess, 'run', return_value=result) as run:
            with self.assertRaises(ValueError) as error:
                module.GitHub().releases()
            self.assertNotIn('sensitive', str(error.exception))
            self.assertEqual(run.call_args.args[0][0], str(Path(sys.executable).resolve()))
            self.assertFalse(run.call_args.kwargs['shell'])
            self.assertEqual(run.call_args.kwargs['timeout'], 600)

    def test_missing_git_cli_cannot_start_remote_operations(self):
        with mock.patch.object(module.shutil, 'which', return_value=None), \
                mock.patch.object(module.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, '缺少 GitHub CLI'):
                module.GitHub().releases()
            run.assert_not_called()

    def test_real_cli_rejects_missing_inputs_before_network(self):
        # 固定解释器和被测脚本；缺失输入必须在任何远端调用之前失败。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python_exec_rule-subprocess-call-array
        result = subprocess.run([str(Path(sys.executable).resolve(strict=True)), str(Path(module.__file__).resolve()), '--manifest', str(self.root / 'missing'),  # nosec B603 - 可执行文件已解析，参数数组不经 shell。
                                 '--asset-dir', str(self.root), '--qualification', str(self.root / 'missing'),
                                 '--notes', str(self.root / 'missing'), '--output', str(self.root / 'result.json')],
                                capture_output=True, text=True, timeout=30, shell=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads((self.root / 'result.json').read_text())['status'], 'blocked')

    def test_cli_representative_prepare_writes_verified_receipt(self):
        self.setup_receipts()
        path = self.root / 'manifest.json'
        path.write_text(json.dumps(self.manifest))
        out = self.root / 'result.json'
        args = [module.__file__, '--manifest', str(path), '--asset-dir', str(self.root), '--qualification',
                str(self.receipt_path), '--notes', str(self.notes), '--stage', 'prepare', '--output', str(out)]
        with mock.patch.object(sys, 'argv', args), mock.patch.object(module, 'GitHub', return_value=self.gh), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(module.main(), 0)
        self.assertEqual(json.loads(out.read_text())['status'], 'draft_assets_verified')

    def test_existing_output_and_active_lock_prevent_mutations(self):
        self.setup_receipts()
        manifest = self.root / 'manifest.json'
        manifest.write_text(json.dumps(self.manifest))
        out = self.root / 'result.json'
        args = [module.__file__, '--manifest', str(manifest), '--asset-dir', str(self.root), '--qualification',
                str(self.receipt_path), '--notes', str(self.notes), '--stage', 'prepare', '--output', str(out)]
        out.write_text('previous evidence')
        with mock.patch.object(sys, 'argv', args), mock.patch.object(module, 'GitHub', return_value=self.gh), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(module.main(), 1)
            self.assertEqual(out.read_text(), 'previous evidence')
            out.unlink()
            lock = self.root / '.aegis-release.lock'
            lock.write_text('other process')
            self.assertEqual(module.main(), 1)
            self.assertEqual(lock.read_text(), 'other process')
        self.assertEqual(self.gh.calls, [])

    def test_publish_rechecks_tag_and_latest_readback(self):
        self.setup_receipts()
        self.run_stage('prepare')
        original = self.gh.api
        count = 0
        def moved_tag(endpoint):
            nonlocal count
            if '/commits/' in endpoint:
                count += 1
                if count == 2:
                    return {'sha': 'b' * 40}
            return original(endpoint)
        self.gh.api = moved_tag
        with self.assertRaisesRegex(ValueError, 'tag'):
            self.run_stage('publish')
        self.assertNotIn('edit', [call[0] for call in self.gh.calls])
        def wrong_latest(endpoint):
            if endpoint.endswith('/releases/latest'):
                return {**original(endpoint), 'id': 99}
            return original(endpoint)
        self.gh.api = wrong_latest
        with self.assertRaisesRegex(ValueError, 'latest'):
            self.run_stage('publish')
        # 公开动作可能已经成功，保留回读失败，绝不能据此新建发行版本。
        self.assertFalse(self.gh.rows[0]['draft'])

    def test_invalid_release_identity_or_unexpected_asset_blocks(self):
        self.setup_receipts()
        self.run_stage('prepare')
        good = copy.deepcopy(self.gh.rows[0])
        for change in ({'id': None}, {'assets': [*good['assets'], {'name': 'unlisted'}]}):
            self.gh.rows = [{**good, **change}]
            with self.assertRaises(ValueError):
                self.run_stage('publish')
        self.assertNotIn('edit', [call[0] for call in self.gh.calls])


if __name__ == '__main__':
    unittest.main()
