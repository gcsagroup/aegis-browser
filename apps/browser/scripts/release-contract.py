"""将当前功能清单绑定到产品提交和真实验收；不生成任何通过结果。"""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess  # nosec B404 - 只读 Git 参数数组，不启用 shell。

PLATFORMS = {'mac-arm64', 'win-x64', 'android-arm64'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def validate_evolution(current, previous):
    current_features = {row['id']: set(row['platforms']) for row in current['features']}
    for row in previous['features']:
        if not set(row['platforms']) <= current_features.get(row['id'], set()):
            raise ValueError('既有功能或适用平台被移除：' + row['id'])


def load(browser, enforce_history=False):
    path = Path(browser) / 'release-feature-contract.json'
    contract = json.loads(path.read_text())
    if contract.get('schemaVersion') != 1 or not contract.get('features'):
        raise ValueError('缺少有效的发行功能清单')
    ids = set()
    for feature in contract['features']:
        name = feature.get('id', '')
        platforms = feature.get('platforms', [])
        if (not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]*', name) or name in ids
                or not platforms or len(platforms) != len(set(platforms))
                or not set(platforms) <= PLATFORMS):
            raise ValueError('功能ID重复或平台范围无效')
        ids.add(name)
        selections = feature.get('testFiltersByPlatform', {})
        if not isinstance(selections, dict) or not set(selections) <= set(platforms):
            raise ValueError('功能测试选择的平台范围无效：' + name)
        for filters in [feature.get('testFilters', []), *selections.values()]:
            if (not isinstance(filters, list) or any(not isinstance(value, str)
                    or not re.fullmatch(r'[A-Za-z0-9_.*?/]+', value) for value in filters)):
                raise ValueError('功能测试过滤器无效：' + name)
        if any(not filters for filters in selections.values()):
            raise ValueError('功能测试选择不能为空：' + name)
    header = Path(browser) / 'overlay/chrome/common/aegis/features.h'
    declared = set(re.findall(r'BASE_DECLARE_FEATURE\((\w+)\)', header.read_text()))
    if not declared or not declared <= ids:
        raise ValueError('新增功能开关尚未纳入发行验收清单：' + ', '.join(sorted(declared - ids)))
    if enforce_history:
        root = Path(browser).resolve().parents[1]
        relative = path.resolve().relative_to(root).as_posix()
        executable = shutil.which('git')
        if not executable:
            raise ValueError('缺少用于核对功能历史的 Git')
        executable = str(Path(executable).resolve(strict=True))
        # 固定 log/show 子命令；路径独立传参，历史修订只来自 Git 自身。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        revisions = subprocess.check_output(  # nosec B603 - 可执行文件已解析，参数数组不经 shell。
            [executable, '-C', str(root), 'log', '-2', '--format=%H', '--', relative],
            text=True, timeout=30, shell=False).splitlines()
        if len(revisions) == 2:
            # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
            previous = subprocess.check_output(  # nosec B603 - 可执行文件已解析，参数数组不经 shell。
                [executable, '-C', str(root), 'show', revisions[1] + ':' + relative],
                text=True, timeout=30, shell=False)
            validate_evolution(contract, json.loads(previous))
    return contract, digest(path)


def validate_features(receipt, contract, contract_hash, platform, evidence_root):
    applicable = [f for f in contract['features'] if platform in f['platforms']]
    if platform not in PLATFORMS or not applicable:
        raise ValueError('发行平台未定义功能验收，禁止零项通过')
    if receipt.get('featureContractSha256') != contract_hash:
        raise ValueError('功能清单已变化，不能复用旧验收')
    checks = receipt.get('featureChecks', {})
    root = Path(evidence_root).resolve()
    for feature in applicable:
        check = checks.get(feature['id'], {})
        count = check.get('executed')
        if check.get('status') != 'passed' or type(count) is not int or count <= 0:
            raise ValueError(platform + '/' + feature['id'] + '缺少实际执行的功能回归')
        relative = check.get('file', '')
        if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
            raise ValueError('功能验收日志路径无效')
        path = root / relative
        if (path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root)
                or not path.stat().st_size or check.get('sha256') != digest(path)):
            raise ValueError('功能验收日志缺失或摘要不一致')


def validate_version(src, browser, previous=0, enforce_history=False):
    """构建前必须准备并提交完整版本；禁止只临时改一个头文件。"""
    header = Path('chrome/browser/ui/webui/help/aegis_github_update.h')
    text = (Path(src) / header).read_text()
    if text != (Path(browser) / 'overlay' / header).read_text():
        raise ValueError('源码与产品overlay版本头不一致')
    match = re.search(r'kProductVersion\[\] = "(\d+)\.(\d+)\.(\d+)\.(\d+)"', text)
    if not match:
        raise ValueError('产品版本缺失')
    major, minor, patch, number = map(int, match.groups())
    version = '.'.join(match.groups())
    label = f'Ver {major}.{minor} ({number:03d})'
    package = (Path(browser) / 'scripts/package.sh').read_text()
    android = (Path(browser) / 'args/aegis-android.gn').read_text()
    # Android 已使用独立、连续的 200xxxxxxx 编号，不能由产品主版本乘十亿重算。
    code_match = re.search(r'^android_override_version_code = "(\d+)"$', android, re.M)
    code = int(code_match[1]) if code_match else 0
    if not 1 <= code <= 2100000000:
        raise ValueError('Android版本号超出发行范围，需保持升级连续性的版本迁移')
    if (number >= 10000 or code % 10000 != number or label not in text
            or '${AEGIS_PACKAGE_VERSION:-' + version + '}' not in package
            or f'android_override_version_name = "{label}"' not in android):
        raise ValueError('产品版本、打包版本及Android版本元数据不一致')
    if enforce_history:
        validate_android_history(browser, code, label)
    if number <= previous:
        raise ValueError('本次真实编译前必须递增并提交完整产品版本')
    return version, number


def validate_android_history(browser, code, label):
    """对照最近不同版本的已提交编号，禁止大版本变化造成 Android 降级。"""
    root = Path(browser).resolve().parents[1]
    relative = (Path(browser) / 'args/aegis-android.gn').resolve().relative_to(root).as_posix()
    executable = shutil.which('git')
    if not executable:
        raise ValueError('缺少用于核对Android版本历史的 Git')
    executable = str(Path(executable).resolve(strict=True))
    def git(*args):
        # 固定只读命令，修订来自 Git 自身，不经 shell。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        return subprocess.check_output([executable, '-C', str(root), *args],  # nosec B603
                                       text=True, timeout=30, shell=False)
    for revision in git('log', '--format=%H', '--', relative).splitlines():
        old = git('show', revision + ':' + relative)
        match = re.search(r'^android_override_version_code = "(\d+)"$', old, re.M)
        name = re.search(r'^android_override_version_name = "([^"\n]+)"$', old, re.M)
        if not match or not name:
            raise ValueError('既有Android版本历史不完整，禁止跳过升级连续性核对')
        old_code = int(match[1])
        if (old_code, name[1]) == (code, label):
            continue
        if code <= old_code:
            raise ValueError('Android versionCode 必须高于上一已提交版本')
        return
