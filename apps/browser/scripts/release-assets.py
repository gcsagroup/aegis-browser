"""检查三平台发行资产，并核对 GitHub 草稿回读；不签名、不发布、不替代实机验收。"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

REPOSITORY = 'gcsagroup/aegis-browser'
PLATFORMS = ('mac-arm64', 'win-x64', 'android-arm64')
MAX_SIZE = 2 * 1024 ** 3


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', value),
            '产品版本必须为四段无前导零数字')
    parts = tuple(map(int, value.split('.')))
    require(all(part <= 2147483647 for part in parts), '产品版本超出客户端范围')
    return parts


def expected_name(version, platform, chromium):
    if platform == 'android-arm64':
        require(isinstance(chromium, str) and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+', chromium),
                '缺少 Android Chromium 版本')
        return f'GCSA-aegis-{version}-chromium-{chromium}-android-arm64.apk'
    suffix = 'dmg' if platform == 'mac-arm64' else 'exe'
    return f'GCSA-aegis-{version}-{platform}.{suffix}'


def sha256(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def check_local(manifest, directory):
    """清单为构建输入；本检查只证明资产一致性，不能证明来源或发行资格。"""
    require(manifest.get('schemaVersion') == 1, '不支持的清单格式')
    version = manifest.get('productVersion')
    current = version_tuple(version)
    require(current > version_tuple(manifest.get('previousProductVersion')), '拒绝同版本或版本降级')
    require(re.fullmatch(r'[0-9a-f]{40}', manifest.get('productCommit', '')), '缺少完整产品提交')
    require(manifest.get('repository') == REPOSITORY, '发行仓库不匹配')
    assets = manifest.get('assets')
    require(isinstance(assets, list) and len(assets) == 3, '必须同时提供三个平台的安装包')
    require({asset.get('platform') for asset in assets} == set(PLATFORMS), '平台重复或缺失')
    root = Path(directory).resolve(strict=True)
    checked = []
    for asset in assets:
        name = expected_name(version, asset['platform'], asset.get('chromiumVersion'))
        require(asset.get('name') == name, f"安装包名称不兼容：{asset['platform']}")
        path = root / name
        require(not path.is_symlink() and path.is_file() and path.resolve().parent == root, f'缺少真实安装包：{name}')
        size = path.stat().st_size
        require(0 < size <= MAX_SIZE, f'安装包大小不受客户端支持：{name}')
        require(type(asset.get('size')) is int and asset['size'] == size, f'安装包大小不符：{name}')
        digest = sha256(path)
        require(asset.get('sha256') == digest, f'安装包摘要不符：{name}')
        checked.append({'platform': asset['platform'], 'name': name, 'size': size, 'sha256': digest})
    return {'repository': REPOSITORY, 'tag': f'v{version}', 'productCommit': manifest['productCommit'], 'assets': checked,
            'qualification': 'asset_consistency_only', 'releaseReady': False}


def check_remote(local, release, *, require_draft=True):
    """读取 gh api 的完整单次 Release 响应，禁止缺摘要和重名资产。"""
    tag = local['tag']
    base = f'https://github.com/{REPOSITORY}/releases'
    require(release.get('tag_name') == tag, '远端 tag 不匹配')
    # 草稿的 html_url 可能是 /untagged/...，资产下载 URL 仍须使用最终 tag。
    url = release.get('html_url', '')
    require(url == f'{base}/tag/{tag}' or (require_draft and url.startswith(f'{base}/untagged/') and len(url) > len(f'{base}/untagged/')), '远端 Release 仓库不匹配')
    require(release.get('draft') is require_draft, '远端 Release 草稿状态不匹配')
    require(release.get('prerelease') is False, '不能用预发布替代正式发行')
    assets = release.get('assets')
    require(isinstance(assets, list), '远端资产列表缺失')
    names = [asset.get('name') for asset in assets]
    require(all(isinstance(name, str) for name in names) and len(names) == len(set(names)), '远端资产存在重复名称')
    for expected in local['assets']:
        matches = [asset for asset in assets if asset.get('name') == expected['name']]
        require(len(matches) == 1, f"远端缺少安装包：{expected['name']}")
        actual = matches[0]
        require(actual.get('state') == 'uploaded', '远端安装包尚未完成上传')
        require(type(actual.get('size')) is int and actual['size'] == expected['size'], '远端安装包大小不匹配')
        require(actual.get('digest') == 'sha256:' + expected['sha256'], '远端安装包摘要缺失或不匹配')
        require(actual.get('browser_download_url') == f"{base}/download/{tag}/{expected['name']}", '远端安装包下载地址不匹配')
    return {**local, 'remoteAssetsVerified': True, 'remoteDraft': require_draft}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--asset-dir', required=True, type=Path)
    parser.add_argument('--release-json', type=Path, help='gh api 返回的完整 Release JSON')
    parser.add_argument('--published', action='store_true', help='回读已发布版本；不会执行发布')
    args = parser.parse_args()
    try:
        require(not args.published or args.release_json, '--published 必须提供远端回读')
        result = check_local(json.loads(args.manifest.read_text()), args.asset_dir)
        if args.release_json:
            result = check_remote(result, json.loads(args.release_json.read_text()), require_draft=not args.published)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as exc:
        print(json.dumps({'status': 'blocked', 'reason': str(exc), 'releaseReady': False}, ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
