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

    def test_current_major_uses_continuous_android_code(self):
        for path in [self.src / self.header, self.browser / 'overlay' / self.header,
                     self.browser / 'scripts/package.sh', self.browser / 'args/aegis-android.gn']:
            text = path.read_text().replace('2.1.0.126', '5.0.0.208').replace(
                'Ver 2.1 (126)', 'Ver 5.0 (208)').replace('2001000126', '2005000208')
            path.write_text(text)
        self.assertEqual(contract.validate_version(self.src, self.browser, 207), ('5.0.0.208', 208))
        path = self.browser / 'args/aegis-android.gn'
        text = path.read_text()
        for code in ['0', '2100000001', '5000000208']:
            path.write_text(text.replace('2005000208', code))
            with self.assertRaisesRegex(ValueError, '超出发行范围'):
                contract.validate_version(self.src, self.browser)

    def test_android_history_rejects_equal_and_lower_code(self):
        repo = self.root / 'history-product'
        browser = repo / 'apps/browser'
        shutil.copytree(self.browser, browser)
        executable = str(Path(shutil.which('git')).resolve(strict=True))
        def git(*args):
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
            return subprocess.check_output([executable, '-C', str(repo), *args],  # nosec B603
                                           text=True, timeout=30, shell=False)
        git('init', '-q'); git('config', 'user.name', 'test')
        git('config', 'user.email', 'test@example.invalid')
        git('add', 'apps'); git('commit', '-qm', '保留既有 Android 版本')
        for code in [2001000126, 2001000125]:
            with self.assertRaisesRegex(ValueError, '必须高于'):
                contract.validate_android_history(browser, code, 'Ver 5.0 (208)')
        contract.validate_android_history(browser, 2005000208, 'Ver 5.0 (208)')
        # 已提交当前版本时必须继续找到前一不同版本，不能与自身比较。
        path = browser / 'args/aegis-android.gn'
        path.write_text(path.read_text().replace('2001000126', '2005000208').replace(
            'Ver 2.1 (126)', 'Ver 5.0 (208)'))
        git('add', 'apps'); git('commit', '-qm', '新版本')
        contract.validate_android_history(browser, 2005000208, 'Ver 5.0 (208)')
        shallow = self.root / 'shallow-product'
        git('clone', '--quiet', '--depth=1', repo.as_uri(), str(shallow))
        with self.assertRaisesRegex(ValueError, '浅克隆'):
            contract.validate_android_history(shallow / 'apps/browser', 2005000208,
                                              'Ver 5.0 (208)')

    def test_platform_test_selection_is_not_allowed_to_escape_scope(self):
        row = self.features['features'][0]
        row['platforms'] = ['mac-arm64']
        for selection in [{'win-x64': ['ExampleTest.*']}, {'mac-arm64': []},
                          {'mac-arm64': ['ExampleTest.*:-ImportantTest.*']}]:
            row['testFiltersByPlatform'] = selection
            self.save_features()
            with self.assertRaisesRegex(ValueError, '测试'):
                contract.load(self.browser)

    def test_latest_features_have_existing_desktop_regression_entries(self):
        browser = Path(__file__).resolve().parents[1]
        features, _ = contract.load(browser)
        by_id = {row['id']: row for row in features['features']}
        import fnmatch
        import re
        tests = set()
        for path in (browser / 'overlay').rglob('*test.cc'):
            for fixture, name in re.findall(
                    r'(?:IN_PROC_BROWSER_TEST_F|TEST_F|TEST)\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)',
                    path.read_text()):
                tests.add(fixture + '.' + name)
        for key in ['reading-library', 'reading-translation', 'pdf-text-notes',
                    'foreground-page-watch', 'kAegisWebsiteEnhancements',
                    'kAegisUserScripts', 'kAegisMarkdownReader']:
            row = by_id[key]
            for platform in ['mac-arm64', 'win-x64']:
                for pattern in row['testFiltersByPlatform'][platform]:
                    self.assertTrue(any(fnmatch.fnmatchcase(name, pattern) for name in tests), pattern)
        self.assertNotIn('android-arm64', by_id['kAegisMarkdownReader']['platforms'])

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
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
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
