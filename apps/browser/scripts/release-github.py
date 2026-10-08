"""按验收凭据准备、核对及公开同一 GitHub Release；不负责签名或安装。"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess  # nosec B404 - 固定 gh 工具及参数数组，不经过 shell。
import sys
from urllib.parse import quote

spec = importlib.util.spec_from_file_location('release_assets', Path(__file__).with_name('release-assets.py'))
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)
require = assets.require
REPO = assets.REPOSITORY
BROWSER = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_contract', Path(__file__).with_name('release-contract.py'))
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
PREFIX = f'repos/{REPO}'
CHECKS = ('build', 'native_tests', 'security_regressions', 'permissions', 'profile_compatibility',
          'device_acceptance', 'signature', 'update_failure_paths')


def read_json(path):
    return json.loads(Path(path).read_text())


def qualification(local, receipt_path):
    """凭据必须由平台验收程序生成；日志摘要证明绑定关系，不认证日志内容真伪。"""
    receipt = read_json(receipt_path)
    require(receipt.get('schemaVersion') == 1, '验收凭据格式不支持')
    require(receipt.get('productCommit') == local['productCommit'], '验收提交不一致')
    require(receipt.get('productVersion') == local['tag'][1:], '验收产品版本不一致')
    features, feature_hash = contract.load(BROWSER, enforce_history=True)
    require(receipt.get('featureContractSha256') == feature_hash, '发行功能清单已变化，必须重新验收')
    platforms = receipt.get('platforms', {})
    require(set(platforms) == set(assets.PLATFORMS), '缺少三平台验收凭据')
    root = Path(receipt_path).resolve().parent
    for asset in local['assets']:
        platform = asset['platform']
        row = platforms[platform]
        require(row.get('artifactSha256') == asset['sha256'], f'{platform}验收产物摘要不一致')
        contract.validate_features(row, features, feature_hash, platform, root)
        required = CHECKS + (('notarization',) if platform == 'mac-arm64' else ())
        if platform == 'android-arm64':
            required += ('package_identity', 'signer_continuity', 'version_code_increase', 'install_confirmation')
        for name in required:
            evidence = row.get('checks', {}).get(name, {})
            require(evidence.get('status') == 'passed', f'{platform}/{name}尚未通过')
            relative = evidence.get('file', '')
            require(isinstance(relative, str) and relative and not Path(relative).is_absolute(), '证据须为相对路径')
            path = root / relative
            require(not path.is_symlink() and path.is_file() and path.resolve().is_relative_to(root), '证据路径无效')
            require(path.stat().st_size > 0 and evidence.get('sha256') == assets.sha256(path), '验收证据摘要不一致')
    return receipt


class GitHub:
    def run(self, args):
        # 参数数组不经过 shell；不打印环境、凭据或原始错误响应。
        executable = shutil.which('gh')
        require(executable is not None, '缺少 GitHub CLI，未执行远端操作')
        executable = str(Path(executable).resolve(strict=True))
        # args 仅由下方 api/releases/mutate 生成，绝不解释成命令文本。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run([executable, *args], capture_output=True, text=True,  # nosec B603 - 可执行文件已解析，参数数组不经 shell。
                                timeout=600, shell=False)
        require(result.returncode == 0, f'GitHub操作失败：{args[0]}；退出码{result.returncode}，保留草稿后重试')
        return result.stdout

    def api(self, endpoint):
        return json.loads(self.run(['api', endpoint]))

    def releases(self):
        pages = json.loads(self.run(['api', f'{PREFIX}/releases?per_page=100', '--paginate', '--slurp']))
        require(isinstance(pages, list) and all(isinstance(p, list) for p in pages), 'Release列表响应无效')
        return [release for page in pages for release in page]

    def mutate(self, args):
        self.run(['release', *args, '--repo', REPO])


def remote_identity(gh, local):
    repo = gh.api(PREFIX)
    require(repo.get('permissions', {}).get('push') is True, '当前GitHub API身份没有发行写权限')
    require(repo.get('private') is False, '公开客户端需要公开发行仓库')
    branch = repo.get('default_branch')
    require(isinstance(branch, str) and branch, '远端默认分支缺失')
    tag = quote(local['tag'], safe='')
    commit = gh.api(f'{PREFIX}/commits/{tag}')
    require(commit.get('sha') == local['productCommit'], '远端tag缺失或提交不匹配；不自动创建或覆盖tag')
    comparison = gh.api(f'{PREFIX}/compare/{local["productCommit"]}...{quote(branch, safe="")}')
    require(comparison.get('status') == 'identical', '默认分支已变化或被测提交尚未合入，必须重新集成验收')


def select_release(gh, local):
    releases = gh.releases()
    matches = [r for r in releases if r.get('tag_name') == local['tag']]
    require(len(matches) <= 1, '同tag出现多个Release，停止自动处理')
    for release in releases:
        tag = release.get('tag_name', '')
        if not release.get('draft') and not release.get('prerelease') and re.fullmatch(r'v\d+\.\d+\.\d+\.\d+', tag):
            require(assets.version_tuple(tag[1:]) <= assets.version_tuple(local['tag'][1:]), '已存在更高正式产品版本，拒绝倒退latest')
    if matches:
        require(type(matches[0].get('id')) is int and matches[0]['id'] > 0, 'Release身份无效')
    return matches[0] if matches else None


def check_existing_assets(local, release):
    """允许草稿缺包；已有资产必须完全一致，拒绝覆盖失败或损坏上传。"""
    existing = release.get('assets', [])
    require(isinstance(existing, list), '草稿资产响应无效')
    expected = {a['name']: a for a in local['assets']}
    names = [a.get('name') for a in existing]
    require(len(names) == len(set(names)), '草稿资产重名')
    require(set(names) <= set(expected), '草稿包含未在本次清单中的资产')
    partial = {**local, 'assets': [expected[name] for name in names]}
    assets.check_remote(partial, release, require_draft=True)
    return set(names)


def execute(manifest, directory, receipt, notes, stage, gh):
    local = assets.check_local(manifest, directory)
    qualification(local, receipt)
    body = Path(notes).read_text()
    require(body.strip(), '发布说明为空')
    remote_identity(gh, local)
    release = select_release(gh, local)
    result = {'tag': local['tag'], 'productCommit': local['productCommit'], 'assets': local['assets'],
              'stage': stage, 'releaseReady': False, 'oldClientUpdateAcceptance': 'pending'}
    if release and release.get('draft') is False:
        assets.check_remote(local, release, require_draft=False)
        return {**result, 'status': 'published_existing_verified', 'releaseUrl': release['html_url']}
    if release:
        require(release.get('prerelease') is False, '同tag为预发布，拒绝改变其用途')
        require(release.get('body') == body, '已有草稿发布说明不同，保留现场等待核对')
        check_existing_assets(local, release)
    if stage == 'preflight':
        return {**result, 'status': 'preflight_passed', 'draftExists': release is not None}
    if stage == 'prepare':
        if release is None:
            gh.mutate(['create', local['tag'], '--draft', '--verify-tag', '--title', local['tag'], '--notes-file', str(Path(notes).resolve())])
            release = select_release(gh, local)
            require(release is not None and release.get('draft') is True, '未回读到新草稿；禁止重复创建')
            require(release.get('body') == body, '草稿说明回读不一致')
        present = check_existing_assets(local, release)
        for asset in local['assets']:
            if asset['name'] not in present:
                # 再读本地摘要，检测准备期间文件变化。禁止 --clobber。
                assets.check_local(manifest, directory)
                gh.mutate(['upload', local['tag'], str((Path(directory) / asset['name']).resolve())])
        release = select_release(gh, local)
        require(release is not None, '草稿回读缺失')
        assets.check_remote(local, release)
        return {**result, 'status': 'draft_assets_verified', 'releaseUrl': release['html_url']}
    require(stage == 'publish' and release is not None, '必须先准备并核验同一草稿')
    assets.check_remote(local, release)
    # 公开前重读 tag/main、全部本地文件及验收证据，避免复用旧预检结果。
    remote_identity(gh, local)
    assets.check_local(manifest, directory)
    qualification(local, receipt)
    latest = select_release(gh, local)
    require(latest is not None and latest.get('id') == release.get('id'), '草稿身份变化')
    assets.check_remote(local, latest)
    require(latest.get('body') == body, '发布前草稿说明已变化')
    gh.mutate(['edit', local['tag'], '--draft=false', '--prerelease=false', '--latest', '--verify-tag'])
    published = select_release(gh, local)
    require(published is not None, '公开Release回读缺失')
    assets.check_remote(local, published, require_draft=False)
    public_latest = gh.api(f'{PREFIX}/releases/latest')
    require(public_latest.get('id') == published.get('id'), 'latest回读未指向本次发行')
    assets.check_remote(local, public_latest, require_draft=False)
    return {**result, 'status': 'published_verified', 'releaseUrl': published['html_url']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--asset-dir', type=Path, required=True)
    parser.add_argument('--qualification', type=Path, required=True)
    parser.add_argument('--notes', type=Path, required=True)
    parser.add_argument('--stage', choices=('preflight', 'prepare', 'publish'), default='preflight')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    # 先独占证据输出，防止完成远端操作后才发现旧记录不能覆盖。
    try:
        stream = args.output.open('x')
    except OSError as exc:
        print(json.dumps({'status': 'evidence_write_failed', 'reason': str(exc)}, ensure_ascii=False))
        return 1
    code = 0
    owned_lock = False
    lock = args.asset_dir / '.aegis-release.lock'
    try:
        with lock.open('x') as handle:
            handle.write(str(os.getpid()) + '\n')
        owned_lock = True
        result = execute(read_json(args.manifest), args.asset_dir, args.qualification, args.notes, args.stage, GitHub())
    except (OSError, ValueError, TypeError, KeyError, AttributeError, subprocess.TimeoutExpired) as exc:
        result = {'status': 'blocked', 'reason': str(exc), 'releaseReady': False, 'oldClientUpdateAcceptance': 'pending'}
        code = 1
    finally:
        if owned_lock:
            lock.unlink()
    try:
        with stream:
            stream.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
            stream.flush()
            os.fsync(stream.fileno())
        require(read_json(args.output) == result, '发行记录写入回读不一致')
    except (OSError, ValueError) as exc:
        print(json.dumps({'status': 'evidence_write_failed', 'reason': str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return code


if __name__ == '__main__':
    sys.exit(main())
