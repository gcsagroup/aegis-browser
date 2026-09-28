"""构建前只读核对完整 Chromium/V8 补丁树与 overlay，禁止覆盖旧工作区。"""
import argparse
import json
from pathlib import Path
import sys

from ci.candidate import BROWSER, git, verify_tree


def verify_source(source, browser=BROWSER):
    source = Path(source).resolve(strict=True)
    browser = Path(browser).resolve(strict=True)
    for repository in (source, source / 'v8'):
        if Path(git(repository, 'rev-parse', '--show-toplevel')).resolve() != repository:
            raise ValueError('构建依赖缺少独立 Git 来源，不能借用父仓库身份：' + str(repository))
    base = (browser / 'CHROMIUM_COMMIT').read_text().strip()
    patches = browser / 'patches'
    chromium_tree = verify_tree(source, base, patches)
    v8_base = git(source, 'rev-parse', base + ':v8')
    v8_tree = verify_tree(source / 'v8', v8_base, patches / 'v8')
    checked = 0
    for item in sorted((browser / 'overlay').rglob('*')):
        if not item.is_file():
            continue
        relative = item.relative_to(browser / 'overlay')
        if '.DS_Store' in relative.parts:
            continue
        target = source / relative
        if not target.is_file() or item.read_bytes() != target.read_bytes():
            raise ValueError('overlay 与构建源码不一致：' + relative.as_posix())
        checked += 1
    if not checked:
        raise ValueError('overlay 为空，不能建立构建来源')
    return {'sourceHead': git(source, 'rev-parse', 'HEAD'),
            'chromiumTree': chromium_tree, 'v8Tree': v8_tree,
            'overlayFilesChecked': checked, 'sourceVerified': True,
            'built': False, 'runtimeTested': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(verify_source(args.source), ensure_ascii=False, indent=2))
    except Exception as error:
        print('构建前源码核对未通过：' + str(error), file=sys.stderr)
        sys.exit(1)
