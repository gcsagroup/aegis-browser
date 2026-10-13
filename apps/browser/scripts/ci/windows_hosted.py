#!/usr/bin/env python3
"""一次性 Windows 托管构建：固定基线、完整编译及原生测试，保留失败证据。"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

import candidate

ROOT = candidate.ROOT
BROWSER = candidate.BROWSER
DEPOT_COMMIT = '2fd34a8813b6f34336aad40976cc4223768177f8'
TARGETS = ['chrome', 'mini_installer', 'aegis_browser_unittests', 'browser_tests']


class Runner:
    def __init__(self, evidence, volume, minutes=210, minimum_gib=60):
        self.evidence = evidence
        self.volume = volume
        self.deadline = time.monotonic() + minutes * 60
        self.minimum = minimum_gib * 1024**3

    def run(self, label, command, cwd, env=None):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('本次构建时限已到')
        if shutil.disk_usage(self.volume).free < self.minimum:
            raise RuntimeError('剩余空间不足，保留现场并停止')
        print(f'阶段：{label}', flush=True)
        with (self.evidence / (label + '.log')).open('w', encoding='utf-8') as log:
            options = ({'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP}
                       if os.name == 'nt' else {'start_new_session': True})
            process = subprocess.Popen([str(x) for x in command], cwd=cwd,
                                       env=env, stdout=log, stderr=subprocess.STDOUT, **options)
            last_progress = time.monotonic()
            try:
                while process.poll() is None:
                    if time.monotonic() >= self.deadline:
                        raise TimeoutError('本次构建时限已到')
                    if shutil.disk_usage(self.volume).free < self.minimum:
                        raise RuntimeError('剩余空间不足，保留现场并停止')
                    if time.monotonic() - last_progress >= 30:
                        candidate.write_json(self.evidence / 'heartbeat.json', {
                            'stage': label, 'pid': process.pid, 'checkedAt': candidate.now(),
                            'freeBytes': shutil.disk_usage(self.volume).free})
                        with (self.evidence / (label + '.log')).open('rb') as tail:
                            tail.seek(max(0, tail.seek(0, 2) - 1024))
                            lines = tail.read().decode('utf-8', errors='replace').splitlines()
                            print(f'{label}：' + (lines[-1] if lines else '执行中'), flush=True)
                        last_progress = time.monotonic()
                    time.sleep(0.2)
            finally:
                if process.poll() is None:
                    if os.name == 'nt':
                        subprocess.run([candidate.windows_system_executable('taskkill.exe'),
                                        '/PID', str(process.pid), '/T', '/F'], check=True)
                    else:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            if process.returncode:
                tail = (self.evidence / (label + '.log')).read_text(errors='replace')[-5000:]
                print(tail, flush=True)
                raise RuntimeError(f'{label} 退出码 {process.returncode}，详见日志')


def patch_checkout(runner, source, base, patches, label):
    if candidate.git(source, 'rev-parse', 'HEAD') != base:
        raise ValueError('源码不是固定基线，拒绝覆盖')
    if candidate.git(source, 'status', '--porcelain', '--ignore-submodules=all'):
        raise ValueError('源码有改动，拒绝覆盖')
    for index, name in enumerate(candidate.series(patches)):
        runner.run(f'{label}-{index:03d}', ['git', '-C', source, 'apply', '--index',
                   '--whitespace=nowarn', patches / name], source)
    runner.run(label + '-commit', ['git', '-C', source, '-c', 'user.name=Aegis CI',
               '-c', 'user.email=aegis-ci@users.noreply.github.com', 'commit',
               '-m', '应用本次审核分支的完整补丁'], source)
    return candidate.verify_tree(source, base, patches)


def check_test_summary(path, expected=None):
    data = json.loads(path.read_text(encoding='utf-8'))
    tests = data.get('per_iteration_data', [])
    if not tests or any(not iteration for iteration in tests):
        raise ValueError('测试摘要为空，不能标记通过')
    for iteration in tests:
        if expected is not None and len(iteration) != expected:
            raise ValueError('实际测试数量不匹配')
        if any(not runs or any(run.get('status') != 'SUCCESS' for run in runs)
               for runs in iteration.values()):
            raise ValueError('测试包含失败或跳过项')
    return len(tests[0])


def prepare_depot(runner, work):
    """全新机器先初始化固定版本的工具，再验证 gclient 实际使用的入口。"""
    depot = work / 'depot_tools'
    env = dict(os.environ, DEPOT_TOOLS_UPDATE='0', DEPOT_TOOLS_WIN_TOOLCHAIN='0',
               PYTHONUTF8='1', PYTHONIOENCODING='utf-8')
    env['PATH'] = str(depot) + os.pathsep + env['PATH']
    for key, value in [('core.autocrlf', 'false'), ('core.longpaths', 'true')]:
        runner.run('git-' + key, ['git', 'config', '--global', key, value], work, env)
    runner.run('depot-init', ['git', 'init', depot], work, env)
    runner.run('depot-fetch', ['git', '-C', depot, 'fetch', '--depth=1',
               'https://chromium.googlesource.com/chromium/tools/depot_tools.git', DEPOT_COMMIT], work, env)
    runner.run('depot-checkout', ['git', '-C', depot, 'checkout', '--detach', 'FETCH_HEAD'], work, env)
    cmd = [candidate.windows_system_executable('cmd.exe'), '/d', '/c']
    # 禁止自动升级不等于跳过首次初始化；此官方入口生成 git.bat / python3.bat。
    runner.run('depot-bootstrap', [*cmd, depot / 'bootstrap/win_tools.bat'], work, env)
    if candidate.git(depot, 'rev-parse', 'HEAD') != DEPOT_COMMIT:
        raise ValueError('初始化改变了 depot_tools 固定提交')
    require_depot_wrappers(depot)
    runner.run('depot-python', [*cmd, depot / 'python3.bat', '--version'], work, env)
    probe = work / 'probe_depot.py'
    probe.write_text(
        'import pathlib, subprocess, sys\n'
        'sys.path.insert(0, str(pathlib.Path(__file__).parent / "depot_tools"))\n'
        'import git_cache\n'
        'assert git_cache.Mirror.git_exe == "git.bat"\n'
        'subprocess.run([git_cache.Mirror.git_exe, "--version"], check=True)\n'
        'result = subprocess.run([git_cache.Mirror.git_exe, "config", "--type", '
        '"path", "cache.cachepath"])\n'
        'assert result.returncode in (0, 1), result.returncode\n'
        'print("gclient Git subprocess entry passed", flush=True)\n', encoding='utf-8')
    runner.run('depot-git-entry', [*cmd, depot / 'vpython3.bat', probe], work, env)
    runner.run('depot-gclient', [*cmd, depot / 'gclient.bat', '--version'], work, env)
    return depot, env


def require_depot_wrappers(depot):
    for name in ['git.bat', 'python3.bat', 'vpython3.bat', 'gclient.bat']:
        if not (depot / name).is_file():
            raise ValueError('depot_tools 初始化缺少入口：' + name)


def check_cpp_entry(runner, work, env):
    vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    vs = env.get('GYP_MSVS_OVERRIDE_PATH') or subprocess.check_output([
        str(vswhere), '-latest', '-products', '*', '-version', '[17.0,19.0)',
        '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.VisualStudio.Component.VC.ATLMFC', '-property', 'installationPath'], text=True).strip()
    if not vs:
        raise ValueError('缺少 VS C++ 与 ATL/MFC 工具链')
    (work / 'probe.cpp').write_text('#include <windows.h>\n#include <atlbase.h>\n'
                                  'int main() { return 0; }\n', encoding='utf-8')
    command = work / 'probe_cpp.cmd'
    command.write_text('@echo off\r\ncall "' + vs + '\\VC\\Auxiliary\\Build\\vcvars64.bat"\r\n'
                       'if errorlevel 1 exit /b %errorlevel%\r\n'
                       'cl.exe /nologo /EHsc probe.cpp /Fe:probe.exe\r\n'
                       'if errorlevel 1 exit /b %errorlevel%\r\nprobe.exe\r\n',
                       encoding='utf-8', newline='')
    runner.run('cpp-toolchain-entry', [candidate.windows_system_executable('cmd.exe'),
               '/d', '/c', command], work, env)


def preflight(work, evidence):
    evidence.mkdir(parents=True, exist_ok=False)
    result = {'status': 'failed', 'depotCommit': DEPOT_COMMIT}
    try:
        if sys.platform != 'win32' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
            raise ValueError('入口验收仅允许 GitHub 托管 Windows runner')
        work.mkdir(exist_ok=False)
        runner = Runner(evidence, work, minutes=15, minimum_gib=5)
        _, env = prepare_depot(runner, work)
        check_cpp_entry(runner, work, env)
        result['status'] = 'passed'
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        candidate.write_json(evidence / 'toolchain-result.json', result)


def build(work, evidence):
    evidence.mkdir(parents=True, exist_ok=False)
    result = {'status': 'preflight', 'productCommit': os.environ.get('GITHUB_SHA'),
              'startedAt': candidate.now(), 'uiAcceptance': 'pending', 'released': False}
    try:
        if sys.platform != 'win32' or os.environ.get('RUNNER_ENVIRONMENT') != 'github-hosted':
            raise ValueError('仅允许一次性 GitHub 托管 Windows runner')
        if os.environ.get('GITHUB_RUN_ATTEMPT') != '1':
            raise ValueError('付费试跑禁止直接重试，需先核对预算和新候选版本')
        if (os.cpu_count() or 0) != 32:
            raise ValueError('本轮仅授权 32 核机器')
        if candidate.git(ROOT, 'rev-parse', 'HEAD') != result['productCommit']:
            raise ValueError('产品提交与工作流不一致')
        version = (BROWSER / 'CHROMIUM_VERSION').read_text().strip()
        base = (BROWSER / 'CHROMIUM_COMMIT').read_text().strip()
        if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', version) or not re.fullmatch('[0-9a-f]{40}', base):
            raise ValueError('固定版本无效')
        if work.exists():
            raise ValueError('拒绝复用或覆盖已有构建目录')
        if shutil.disk_usage(work.anchor).free < 300 * 1024**3:
            raise ValueError('首次完整构建至少需要 300 GiB 可用空间')
        work.mkdir()
        runner = Runner(evidence, work)
        depot, env = prepare_depot(runner, work)
        check_cpp_entry(runner, work, env)
        source = work / 'src'
        runner.run('source-init', ['git', 'init', source], work, env)
        runner.run('source-fetch', ['git', '-C', source, 'fetch', '--depth=1',
                   'https://chromium.googlesource.com/chromium/src.git', 'refs/tags/' + version], work, env)
        runner.run('source-checkout', ['git', '-C', source, 'checkout', '--detach', base], work, env)
        (work / '.gclient').write_text("solutions = [{'name': 'src', 'url': "
            "'https://chromium.googlesource.com/chromium/src.git', 'managed': False, "
            "'custom_deps': {}, 'custom_vars': {}}]\ntarget_os = ['win']\n", encoding='utf-8')
        command = [candidate.windows_system_executable('cmd.exe'), '/d', '/c', depot / 'gclient.bat']
        runner.run('dependencies', [*command, 'sync', '--no-history', '--nohooks',
                   '--revision', 'src@' + base, '-j', '16'], work, env)
        runner.run('hooks', [*command, 'runhooks'], work, env)
        v8_base = candidate.git(source, 'rev-parse', base + ':v8')
        if candidate.git(source / 'v8', 'rev-parse', 'HEAD') != v8_base:
            raise ValueError('V8 依赖与 Chromium 固定基线不一致')
        result.update(chromiumVersion=version, chromiumCommit=base, depotCommit=DEPOT_COMMIT,
                      sourceTree=patch_checkout(runner, source, base, BROWSER / 'patches', 'patch'),
                      v8Tree=patch_checkout(runner, source / 'v8', v8_base,
                                            BROWSER / 'patches/v8', 'v8-patch'))
        header = Path('chrome/browser/ui/webui/help/aegis_github_update.h')
        if (source / header).read_bytes() != (BROWSER / 'overlay' / header).read_bytes():
            raise ValueError('编译版本头与提交内容不一致')
        result['productVersion'] = re.search(r'kProductVersion\[\] = "([\d.]+)"',
                                             (source / header).read_text()).group(1)
        out = source / 'out/AegisRelease'
        out.mkdir(parents=True)
        shutil.copy2(BROWSER / 'args/aegis-windows.gn', out / 'args.gn')
        result['status'] = 'building'
        candidate.write_json(evidence / 'result.json', result)
        runner.run('gn', [source / 'buildtools/win/gn.exe', 'gen', out, '--check'], source, env)
        runner.run('build', [source / 'third_party/ninja/ninja.exe', '-C', out, '-j', '28', *TARGETS], source, env)
        result['build'] = 'passed'
        for target, count, extra in [
            ('aegis_browser_unittests', None, []),
            ('browser_tests', 4, ['--gtest_filter=EnhancementBrowserTest.*'])]:
            summary = evidence / (target + '.json')
            runner.run(target, [out / (target + '.exe'), '--test-launcher-jobs=4',
                       '--test-launcher-retry-limit=0', '--test-launcher-print-test-stdio=always',
                       '--test-launcher-summary-output=' + str(summary), *extra], source, env)
            result[target] = {'passed': check_test_summary(summary, count)}
        installer = evidence / 'mini_installer.exe'
        shutil.copy2(out / installer.name, installer)
        result.update(status='build_and_native_tests_passed', installerSha256=candidate.sha256(installer))
    except Exception as error:
        result.update(status='failed', error=str(error))
        raise
    finally:
        if 'out' in locals() and (out / 'mini_installer.exe').is_file():
            # 测试失败时也保留已完成的候选包，但绝不改变失败结论。
            installer = evidence / 'mini_installer.exe'
            if not installer.exists():
                shutil.copy2(out / installer.name, installer)
            result['installerSha256'] = candidate.sha256(installer)
        result['finishedAt'] = candidate.now()
        candidate.write_json(evidence / 'result.json', result)
        summary = '\n'.join(['# Windows 托管试跑', '', '```json',
                             json.dumps(result, ensure_ascii=False, indent=2), '```',
                             '原生测试与完整编译单独记录；交互界面验收、签名和发布未执行。', ''])
        (evidence / 'summary.md').write_text(summary, encoding='utf-8')
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as stream:
                stream.write(summary)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--preflight-only', action='store_true', help='仅验证全新 Windows 工具入口')
    args = parser.parse_args()
    (preflight if args.preflight_only else build)(args.work.resolve(), args.evidence.resolve())
