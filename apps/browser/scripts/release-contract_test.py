"""功能和版本门禁回归；临时文件仅模拟元数据及日志，不是实机验收。"""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import shutil
import subprocess  # nosec B404 - 临时测试仓库的固定 Git 参数，不启用 shell。
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('contract', Path(__file__).with_name('release-contract.py'))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class ContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.browser = self.root / 'browser'
        self.src = self.root / 'src'
        self.header = Path('chrome/browser/ui/webui/help/aegis_github_update.h')
        self.write(self.src / self.header, 'kProductVersion[] = "2.1.0.126"; // Ver 2.1 (126)')
        self.write(self.browser / 'overlay' / self.header, (self.src / self.header).read_text())
        self.write(self.browser / 'scripts/package.sh', 'APP_VERSION="${AEGIS_PACKAGE_VERSION:-2.1.0.126}"')
        self.write(self.browser / 'args/aegis-android.gn',
                   'android_override_version_name = "Ver 2.1 (126)"\nandroid_override_version_code = "2001000126"')
        self.write(self.browser / 'overlay/chrome/common/aegis/features.h', 'BASE_DECLARE_FEATURE(kAegisEnabled);')
        self.features = {'schemaVersion': 1, 'features': [
            {'id': 'kAegisEnabled', 'platforms': sorted(contract.PLATFORMS)}]}
        self.save_features()
        self.write(self.root / 'native.log', '仅夹具：运行了一个测试。')

    @staticmethod
    def write(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def save_features(self):
        self.write(self.browser / 'release-feature-contract.json', json.dumps(self.features))

    def receipt(self):
        _, sha = contract.load(self.browser)
        return {'featureContractSha256': sha, 'featureChecks': {
            'kAegisEnabled': {'status': 'passed', 'executed': 1, 'file': 'native.log',
                              'sha256': contract.digest(self.root / 'native.log')}}}

    def validate(self, receipt):
        features, sha = contract.load(self.browser)
        contract.validate_features(receipt, features, sha, 'mac-arm64', self.root)

    def test_complete_version_and_next_build(self):
        self.assertEqual(contract.validate_version(self.src, self.browser, 125), ('2.1.0.126', 126))
        with self.assertRaisesRegex(ValueError, '递增'):
            contract.validate_version(self.src, self.browser, 126)

    def test_single_header_bump_cannot_build(self):
        self.write(self.src / self.header, 'kProductVersion[] = "2.1.0.127"; // Ver 2.1 (127)')
        with self.assertRaisesRegex(ValueError, '版本头不一致'):
            contract.validate_version(self.src, self.browser)

    def test_android_and_package_metadata_must_match(self):
        for relative in ['args/aegis-android.gn', 'scripts/package.sh']:
            path = self.browser / relative
            old = path.read_text()
            path.write_text(old.replace('126', '125'))
            with self.assertRaisesRegex(ValueError, '元数据不一致'):
                contract.validate_version(self.src, self.browser)
            path.write_text(old)

    def test_new_feature_flag_requires_contract_entry(self):
        self.write(self.browser / 'overlay/chrome/common/aegis/features.h',
                   'BASE_DECLARE_FEATURE(kAegisEnabled);\nBASE_DECLARE_FEATURE(kAegisNew);')
        with self.assertRaisesRegex(ValueError, 'kAegisNew'):
            contract.load(self.browser)

    def test_new_feature_invalidates_old_receipt(self):
        receipt = self.receipt()
        self.features['features'].append({'id': 'new-function', 'platforms': ['mac-arm64']})
        self.save_features()
        with self.assertRaisesRegex(ValueError, '不能复用旧验收'):
            self.validate(receipt)
        receipt['featureContractSha256'] = contract.load(self.browser)[1]
        with self.assertRaisesRegex(ValueError, 'new-function'):
            self.validate(receipt)

    def test_passed_receipt_needs_nonzero_real_log(self):
        good = self.receipt()
        self.validate(good)
        for count in [0, -1, True, '1', None]:
            receipt = copy.deepcopy(good)
            receipt['featureChecks']['kAegisEnabled']['executed'] = count
            with self.assertRaisesRegex(ValueError, '实际执行'):
                self.validate(receipt)
        (self.root / 'native.log').write_text('日志已被修改')
        with self.assertRaisesRegex(ValueError, '摘要不一致'):
            self.validate(good)

    def test_duplicate_or_invalid_platform_rejected(self):
        self.features['features'].append(copy.deepcopy(self.features['features'][0]))
        self.save_features()
        with self.assertRaisesRegex(ValueError, '重复'):
            contract.load(self.browser)

    def test_unknown_or_uncovered_platform_cannot_pass_without_tests(self):
        receipt = self.receipt()
        features, sha = contract.load(self.browser)
        for platform in ['windows-x64', 'unsupported']:
            with self.assertRaisesRegex(ValueError, '禁止零项通过'):
                contract.validate_features(receipt, features, sha, platform, self.root)
        features['features'][0]['platforms'] = ['mac-arm64']
        with self.assertRaisesRegex(ValueError, '禁止零项通过'):
            contract.validate_features(receipt, features, sha, 'win-x64', self.root)

    def test_old_behavior_and_platforms_cannot_be_removed(self):
        previous = copy.deepcopy(self.features)
        contract.validate_evolution(self.features, previous)
        for change in ['remove-feature', 'remove-platform']:
            current = copy.deepcopy(self.features)
            if change == 'remove-feature':
                current['features'] = []
            else:
                current['features'][0]['platforms'] = ['mac-arm64']
            with self.assertRaisesRegex(ValueError, '被移除'):
                contract.validate_evolution(current, previous)

    def test_committed_history_prevents_silent_feature_removal(self):
        repo = self.root / 'product'
        browser = repo / 'apps/browser'
        shutil.copytree(self.browser, browser)
        def git(*args):
            executable = shutil.which('git')
            self.assertIsNotNone(executable)
            # 仅此测试定义的命令与临时路径，不接收外部命令文本。
            return subprocess.check_output([str(Path(executable).resolve(strict=True)),  # nosec B603 - 可执行文件已解析，参数数组不经 shell。
                '-C', str(repo), *args], text=True, timeout=30, shell=False)
        git('init', '-q')
        git('config', 'user.name', 'test')
        git('config', 'user.email', 'test@example.invalid')
        previous = copy.deepcopy(self.features)
        previous['features'].append({'id': 'existing-without-flag', 'platforms': ['mac-arm64']})
        self.write(browser / 'release-feature-contract.json', json.dumps(previous))
        git('add', 'apps'); git('commit', '-qm', '初始功能基线')
        self.write(browser / 'release-feature-contract.json', json.dumps(self.features))
        git('add', 'apps'); git('commit', '-qm', '模拟删除旧功能')
        with self.assertRaisesRegex(ValueError, 'existing-without-flag'):
            contract.load(browser, enforce_history=True)

    def test_feature_log_cannot_escape_evidence_directory(self):
        receipt = self.receipt()
        receipt['featureChecks']['kAegisEnabled']['file'] = str(self.root.parent / 'external.log')
        with self.assertRaisesRegex(ValueError, '路径无效'):
            self.validate(receipt)

    def test_history_requires_git_and_never_skips_missing_tool(self):
        with mock.patch.object(contract.shutil, 'which', return_value=None):
            with self.assertRaisesRegex(ValueError, '缺少.*Git'):
                contract.load(self.browser, enforce_history=True)


if __name__ == '__main__':
    unittest.main()
