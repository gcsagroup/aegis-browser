"""构建前按平台只读核对完整 Chromium/V8 补丁树，禁止覆盖旧工作区。"""
import argparse
import json
from pathlib import Path
import sys

from ci.candidate import BROWSER, git, verify_tree


def verify_source(source, browser=BROWSER, platform='desktop'):
    source = Path(source).resolve(strict=True)
    browser = Path(browser).resolve(strict=True)
    for repository in (source, source / 'v8'):
        if Path(git(repository, 'rev-parse', '--show-toplevel')).resolve() != repository:
            raise ValueError('构建依赖缺少独立 Git 来源，不能借用父仓库身份：' + str(repository))
    if platform == 'android':
        pin = json.loads((browser / 'ci-pins/android.json').read_text())
        base = pin['commit']
        patches = (browser / pin['patchDirectory']).resolve(strict=True)
        if not patches.is_relative_to(browser):
            raise ValueError('Android 补丁目录必须位于 apps/browser 内')
    elif platform == 'desktop':
        base = (browser / 'CHROMIUM_COMMIT').read_text().strip()
        patches = browser / 'patches'
    else:
        raise ValueError('不支持的源码平台：' + platform)
    chromium_tree = verify_tree(source, base, patches)
    v8_base = git(source, 'rev-parse', base + ':v8')
    v8_tree = verify_tree(source / 'v8', v8_base, patches / 'v8')
    checked = 0
    # Android 的独立补丁序列已经参与完整树比对；桌面 overlay 并非其构建输入。
    overlay = sorted((browser / 'overlay').rglob('*')) if platform == 'desktop' else []
    for item in overlay:
        if not item.is_file():
            continue
        relative = item.relative_to(browser / 'overlay')
        if '.DS_Store' in relative.parts:
            continue
        target = source / relative
        if not target.is_file() or item.read_bytes() != target.read_bytes():
            raise ValueError('overlay 与构建源码不一致：' + relative.as_posix())
        checked += 1
    if platform == 'desktop' and not checked:
        raise ValueError('overlay 为空，不能建立构建来源')
    return {'platform': platform, 'chromiumBase': base,
            'patchDirectory': patches.relative_to(browser).as_posix(),
            'sourceHead': git(source, 'rev-parse', 'HEAD'),
            'chromiumTree': chromium_tree, 'v8Tree': v8_tree,
            'overlayFilesChecked': checked, 'sourceVerified': True,
            'built': False, 'runtimeTested': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--platform', choices=['desktop', 'android'], default='desktop')
    args = parser.parse_args()
    try:
        print(json.dumps(verify_source(args.source, platform=args.platform), ensure_ascii=False, indent=2))
    except Exception as error:
        print('构建前源码核对未通过：' + str(error), file=sys.stderr)
        sys.exit(1)
