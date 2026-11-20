"""Windows 一键开发启动器。整次同步和 Ninja 编译共享源码锁，只有成功生成可执行文件才交给桌面。"""

import argparse
import json
import os
from pathlib import Path
# 本地开发工具仅通过参数数组调用，浏览器启动另行校验绝对可执行路径。
import subprocess  # nosec B404
import sys
import tempfile

from chromium_access_gtests import acquire_lock, command_argv, read_pin, run_process, write_json
from windows_browser_sync import (
    PatchTree, apply_changes, git, identities, overlay_files, overlay_id, plan, publish,
)

PROJECT = Path(__file__).resolve().parents[2]
GN_ARGS = "apps/browser/args/aegis-windows.gn"


def synchronize(project, src, cache, state_file, check_only):
    """两棵源码树和 GN 参数全部预检成功后才发布。先记录恢复信息，允许断电后重新运行。"""
    browser = project / "apps/browser"
    base = read_pin(browser / "CHROMIUM_COMMIT")
    v8_base = git(src, "rev-parse", base + ":v8").decode().strip()
    files = overlay_files(project)
    plans = []
    state = json.loads(state_file.read_text("utf-8")) if state_file.is_file() else {}
    stable, intent, active = {}, {}, {}
    for key, directory, pin, patches in [
        ("chromium", src, base, browser / "patches"),
        ("v8", src / "v8", v8_base, browser / "patches/v8"),
    ]:
        subset = ({k[3:]: v for k, v in files.items() if k.startswith("v8/")} if key == "v8"
                  else {k: v for k, v in files.items() if not k.startswith("v8/")})
        tree = PatchTree(directory, pin, patches, cache / key)
        active[key], wanted, changes = plan(
            tree, subset, state.get("stable", {}).get(key, {}), state.get("intent", {}).get(key, {}))
        # 记录本轮真实观察到的旧值，包括从上一次中断恢复的文件。
        stable[key] = dict(wanted)
        stable[key].update({path.relative_to(directory).as_posix(): old for path, old, _, _ in changes})
        intent[key] = wanted
        plans.append((tree, changes))
        print(f"{key} 需要同步 {len(changes)} 个文件。", flush=True)

    args = src / "out/AegisRelease/args.gn"
    content = (project / GN_ARGS).read_bytes()
    wanted_args = overlay_id(content)
    current = identities(args)
    args_changed = wanted_args not in current
    # 初次接管允许仓库 HEAD 的 Windows 参数；保留编译树中开发者自行设定的 GN 参数。
    if args_changed and current[0] is not None:
        previous = state.get("args", [overlay_id(git(project, "show", "HEAD:" + GN_ARGS))])
        if not any(value in current for value in previous):
            raise ValueError(f"编译目录有独立 GN 参数，请先合并：{args}")
    if check_only:
        print(f"GN 参数{'需要更新' if args_changed else '已一致'}。预检完成。", flush=True)
        return args_changed
    write_json(state_file, {"stable": stable, "intent": intent, "args": [current[0], wanted_args]})
    for tree, changes in plans:
        if changes:
            apply_changes(tree, changes)
    if args_changed:
        publish(args, current[0], content)
    write_json(state_file, {"stable": active, "args": [wanted_args]})
    return args_changed


def run(project, checkout, jobs, check_only):
    """复用固定 Windows 输出和独立开发资料目录；编译失败时将错误传回 PowerShell。"""
    src = checkout.resolve(strict=True) / "src"
    out = src / "out/AegisRelease"
    cache = src / "out/.aegis-dev-sync"
    for path in (src, src / "v8", src / "out", out, cache):
        if path.resolve() != path:
            raise ValueError(f"源码或构建目录经过链接：{path}")
    state = cache / "state.json"
    ninja = src / "third_party/ninja/ninja.exe"
    gn = src / "buildtools/win/gn.exe"
    for tool in (ninja, gn):
        if not tool.is_file():
            raise ValueError(f"Chromium 工具链不完整：{tool}")
    if check_only:
        # 预检仅使用临时 Git 对象，允许在只读的实际编译目录上检查同一套输入。
        with tempfile.TemporaryDirectory(prefix="aegis-dev-check-") as directory:
            synchronize(project, src, Path(directory), state, True)
        return
    lock = acquire_lock(src)
    try:
        args_changed = synchronize(project, src, cache, state, False)
        if args_changed or not (out / "build.ninja").is_file():
            # 首次生成和参数变更也执行头文件依赖检查，使后续 Ninja 自动重生成沿用同一契约。
            run_process([str(gn), "gen", "out/AegisRelease", "--check"], cwd=src, output=None)
        run_process([str(ninja), "-C", "out/AegisRelease", "-j", str(jobs), "chrome"], cwd=src, output=None)
        binary = out / "chrome.exe"
        profile = Path(os.environ["LOCALAPPDATA"]) / "Aegis-Dev"
        command = command_argv([str(binary), "--user-data-dir=" + str(profile)])
        # 路径来自开发者明确选择的本地源码树；校验绝对可执行文件和无 NUL 参数，
        # 禁用 shell，使资料目录中的空格及元字符保持字面值，不接受网页或远程工具选择。
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit, python.lang.security.audit.dangerous-subprocess-use-tainted-env-args.dangerous-subprocess-use-tainted-env-args
        subprocess.Popen(command, cwd=out, shell=False)  # nosec B603
        print(f"已启动 {binary}", flush=True)
    finally:
        lock.rmdir()


def main():
    """PowerShell 仅传递本地工具链目录和构建选项，失败统一返回非零退出码。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--jobs", type=int, choices=range(1, 257), default=4, metavar="N")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    try:
        run(PROJECT, args.checkout, args.jobs, args.check_only)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Aegis 启动失败：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
