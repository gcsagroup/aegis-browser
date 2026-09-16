#!/usr/bin/env python3
"""专用构建机的三平台候选流程；失败保留源码、产物及日志。"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[4]
BROWSER = ROOT / 'apps/browser'
PLATFORMS = {
    'mac': ('Mac', 'Darwin', {'arm64'}, 'aegis-release.gn', 'AegisRelease'),
    'windows': ('Windows', 'Windows', {'amd64', 'x86_64'}, 'aegis-windows.gn', 'AegisRelease'),
    'android': ('Android', 'Linux', {'amd64', 'x86_64'}, 'aegis-android.gn', 'AegisAndroid'),
}
HEADER = Path('chrome/browser/ui/webui/help/aegis_github_update.h')
REQUIRED_CHECKS = {'native_tests', 'browser_smoke', 'actor_permissions', 'v8_security_regressions'}


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def system_tool(name):
    found = shutil.which(name)
    if not found:
        raise ValueError(f'缺少所需工具：{name}')
    return str(Path(found).resolve(strict=True))


def git(src, *args, env=None):
    return subprocess.check_output(
        [system_tool('git'), '-C', str(src), *args], env=env, text=True).strip()


def series(directory):
    names = [s.strip() for s in (directory / 'series').read_text().splitlines()
             if s.strip() and not s.lstrip().startswith('#')]
    if not names or len(names) != len(set(names)):
        raise ValueError('补丁列表为空或重复')
    for name in names:
        if Path(name).name != name or '..' in name or '\\' in name:
            raise ValueError('不安全的补丁路径：' + name)
        if not (directory / name).is_file():
            raise ValueError('补丁不存在：' + name)
    return names


def apply_if_base(src, base, patches, log):
    """只在干净官方基线上首次应用补丁；冲突保留 git am 现场。"""
    if git(src, 'status', '--porcelain', '--ignore-submodules=all'):
        raise ValueError('源码不干净，禁止覆盖补丁冲突现场')
    if git(src, 'rev-parse', 'HEAD') != base:
        return  # 已迁移的源码随后必须通过完整树比对。
    with log.open('w', encoding='utf-8') as output:
        for name in series(patches):
            output.write('正在应用：' + name + '\n')
            output.flush()
            result = subprocess.run([system_tool('git'), '-C', str(src), '-c', 'user.name=Aegis CI',
                '-c', 'user.email=aegis-ci@users.noreply.github.com', 'am', '--3way', str(patches / name)],
                stdout=output, stderr=subprocess.STDOUT)
            if result.returncode:
                raise RuntimeError('补丁冲突已保留：' + name)


def verify_tree(src, base, patches):
    """从官方基线在临时索引重放，要求完整源码树一致。"""
    if git(src, 'status', '--porcelain', '--ignore-submodules=all'):
        raise ValueError('源码有未保存的改动或冲突，保留现场后停止：' + str(src))
    fd, index = tempfile.mkstemp(prefix='aegis-ci-index-')
    os.close(fd)
    Path(index).unlink()
    env = dict(os.environ, GIT_INDEX_FILE=index)
    try:
        git(src, 'read-tree', base, env=env)
        for name in series(patches):
            git(src, 'apply', '--cached', '--whitespace=nowarn', str(patches / name), env=env)
        expected = git(src, 'write-tree', env=env)
        actual = git(src, 'rev-parse', 'HEAD^{tree}')
        if expected != actual:
            raise ValueError('构建机源码与本次候选补丁不一致，禁止编译旧源码')
        return actual
    finally:
        Path(index).unlink(missing_ok=True)


def candidate_pin(name, report, browser=BROWSER):
    # 不同平台发布补丁号可能不同；可在审核后的候选分支提供独立 pin 与补丁目录。
    override = browser / 'ci-pins' / (name + '.json')
    if override.exists():
        pin = json.loads(override.read_text())
        patch_dir = (browser / pin['patchDirectory']).resolve()
        if not patch_dir.is_relative_to(browser.resolve()):
            raise ValueError('补丁目录必须位于 apps/browser 内')
    else:
        pin = {'version': (browser / 'CHROMIUM_VERSION').read_text().strip(),
               'commit': (browser / 'CHROMIUM_COMMIT').read_text().strip()}
        patch_dir = browser / 'patches'
    if report.get('errors') or report.get('status') != 'checked':
        raise ValueError('官方核查不完整，禁止解释为无更新')
    official = report['candidates'][PLATFORMS[name][0]]
    if any(pin[k] != official[k] for k in ('version', 'commit')):
        raise ValueError(f"{name} 候选尚未适配官方 {official['version']}，不能拿 {pin['version']} 冒充升级")
    if not re.fullmatch('[0-9a-f]{40}', pin['commit']):
        raise ValueError('无效的 Chromium 提交')
    return pin, patch_dir


def bump_header(text, previous=0):
    match = re.search(r'kProductVersion\[\] = "(\d+\.\d+\.\d+)\.(\d+)"', text)
    if not match:
        raise ValueError('产品构建号不存在')
    old = match.group(0).split('"')[1]
    number = max(int(match[2]), previous) + 1
    new = f'{match[1]}.{number}'
    return text.replace(old, new).replace(f'({int(match[2]):03d})', f'({number:03d})'), new, number


def validate_receipt(receipt, artifact_hash, run_id):
    if receipt.get('runId') != run_id or receipt.get('artifactSha256') != artifact_hash:
        raise ValueError('验收记录不是本次产物')
    checks = receipt.get('checks', {})
    if any(checks.get(key) != 'passed' for key in REQUIRED_CHECKS):
        raise ValueError('原生、浏览器运行、Actor 或漏洞回归尚未全部通过')
    if not receipt.get('evidenceFiles'):
        raise ValueError('验收记录缺少实际日志文件')


def command_argv(command, *, allow_path_lookup=True):
    if not isinstance(command, (list, tuple)) or not command:
        raise ValueError('命令参数必须是非空数组')
    if not all(isinstance(item, (str, os.PathLike)) for item in command):
        raise ValueError('命令参数必须是路径或字符串')
    executable = Path(command[0])
    if executable.is_absolute():
        resolved = executable.resolve(strict=True)
    elif allow_path_lookup:
        resolved = Path(system_tool(str(executable)))
    else:
        raise ValueError('验收命令必须使用绝对可执行文件路径')
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise ValueError('命令首项不是可执行文件：' + str(resolved))
    return [str(resolved), *(str(item) for item in command[1:])]


def windows_system_executable(name):
    system_root = os.environ.get('SystemRoot')
    if not system_root:
        raise RuntimeError('Windows 缺少 SystemRoot，无法安全定位系统工具')
    executable = (Path(system_root) / 'System32' / name).resolve(strict=True)
    if not executable.is_file():
        raise RuntimeError('Windows 系统工具不存在：' + str(executable))
    return str(executable)


def run(command, cwd, log, source, minimum, *, allow_path_lookup=True):
    argv = command_argv(command, allow_path_lookup=allow_path_lookup)
    with log.open('w', encoding='utf-8') as stream:
        options = {'creationflags': subprocess.CREATE_NEW_PROCESS_GROUP} if os.name == 'nt' else {'start_new_session': True}
        process = subprocess.Popen(argv, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT, shell=False, **options)
        started = time.monotonic()
        while process.poll() is None:
            if shutil.disk_usage(source).free < minimum * 1024**3 or time.monotonic() - started > 23 * 3600:
                if os.name == 'nt':
                    subprocess.run([windows_system_executable('taskkill.exe'), '/PID',
                                    str(process.pid), '/T', '/F'], check=False)
                else:
                    import signal
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                raise RuntimeError('空间不足或执行超时，已停止并保留全部文件')
            time.sleep(2)
        if process.returncode:
            raise RuntimeError(f'命令退出 {process.returncode}，见 {log.name}')


def build(name, evidence):
    evidence.mkdir(parents=True, exist_ok=True)
    run_id = f"{os.environ.get('GITHUB_RUN_ID', 'local')}-{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}"
    result = {'platform': name, 'runId': run_id, 'startedAt': now(), 'status': 'preflight',
              'productCommit': os.environ.get('GITHUB_SHA'), 'releaseReady': False, 'installed': False, 'runtimeAcceptance': 'pending'}
    state = evidence / 'result.json'
    write_json(state, result)
    try:
        config_path = os.environ.get('AEGIS_CI_CONFIG')
        if not config_path:
            raise ValueError('缺少构建机环境 AEGIS_CI_CONFIG，参见接入文档')
        config = json.loads(Path(config_path).read_text(encoding='utf-8'))
        _, host, arch, args_name, out_name = PLATFORMS[name]
        if platform.system() != host or platform.machine().lower() not in arch:
            raise ValueError(f'{name} 构建机系统或架构不匹配')
        src = Path(config['sourceRoot']).resolve(strict=True)
        if not (src / 'BUILD.gn').is_file() or not (src.parent / '.gclient').is_file():
            raise ValueError('需要独立、已同步依赖的 Chromium 候选源码')
        report = json.loads((evidence / 'upstream/latest.json').read_text())
        pin, patches = candidate_pin(name, report)
        minimum = max(30, int(config.get('minFreeGiB', 100)))
        if shutil.disk_usage(src).free < minimum * 1024**3:
            raise ValueError('可用空间不足；不会自动清理源码、缓存或旧产物')
        lock = src.parent / '.aegis-ci-lock'
        lock.mkdir()  # 已存在时停止，不删除其他运行留下的锁。
        try:
            apply_if_base(src, pin['commit'], patches, evidence / 'chromium-patches.log')
            source_tree = verify_tree(src, pin['commit'], patches)
            v8_base = git(src, 'rev-parse', pin['commit'] + ':v8')
            apply_if_base(src / 'v8', v8_base, patches / 'v8', evidence / 'v8-patches.log')
            v8_tree = verify_tree(src / 'v8', v8_base, patches / 'v8')
            out = src / 'out' / out_name
            out.mkdir(parents=True, exist_ok=True)
            tracking = out / '.aegis-ci'
            tracking.mkdir(exist_ok=True)
            counter = tracking / 'build-number.json'
            previous = json.loads(counter.read_text())['number'] if counter.exists() else 0
            original = (src / HEADER).read_bytes()
            updated, version, number = bump_header(original.decode(), previous)
            write_json(counter, {'number': number, 'version': version, 'runId': run_id})
            result.update(chromium=pin, sourceHead=git(src, 'rev-parse', 'HEAD'), sourceTree=source_tree,
                          v8Tree=v8_tree, productVersion=version, status='building')
            write_json(state, result)
            args_file = out / 'args.gn'
            old_args = args_file.read_bytes() if args_file.exists() else None
            try:
                (src / HEADER).write_text(updated, encoding='utf-8')
                gn_args = (BROWSER / 'args' / args_name).read_text()
                gn_args = re.sub(r'^use_siso\s*=.*$', '', gn_args, flags=re.M)
                args_file.write_text(gn_args + '\nuse_siso = false\nv8_enable_memory_corruption_api = false\n', encoding='utf-8')
                gn = src / 'buildtools' / {'mac': 'mac', 'windows': 'win', 'android': 'linux64'}[name] / ('gn.exe' if name == 'windows' else 'gn')
                ninja = src / 'third_party/ninja' / ('ninja.exe' if name == 'windows' else 'ninja')
                targets = ['chrome', 'aegis_agent_core_unittests', 'aegis_github_update_unittests']
                if name == 'windows':
                    targets.append('mini_installer')
                if name == 'android':
                    targets = ['chrome_public_apk', 'aegis_agent_core_unittests']
                run([gn, 'gen', out, '--check'], src, evidence / 'gn.log', src, minimum)
                run([ninja, '-C', out, '-j', str(max(1, int(config.get('jobs', 6)))), *targets], src, evidence / 'build.log', src, minimum)
                result['build'] = 'passed'
                if name != 'android':
                    for target in targets[1:3]:
                        binary = out / (target + ('.exe' if name == 'windows' else ''))
                        run([binary, '--test-launcher-jobs=2', '--test-launcher-print-test-stdio=always'], src, evidence / (target + '.log'), src, minimum)
                    result['nativeTests'] = 'passed'
                else:
                    result['nativeTests'] = 'pending_device_execution'
                artifact = evidence / ('candidate.zip' if name == 'mac' else 'candidate.exe' if name == 'windows' else 'candidate.apk')
                if name == 'mac':
                    app = out / 'GCSA Aegis.app'
                    run(['bash', BROWSER / 'scripts/sign-chromium-app.sh', app, out], src, evidence / 'adhoc-sign.log', src, minimum)
                    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, artifact], src, evidence / 'package.log', src, minimum)
                else:
                    built = out / ('mini_installer.exe' if name == 'windows' else 'apks/ChromePublic.apk')
                    shutil.copy2(built, artifact)
                result.update(artifact=artifact.name, artifactSha256=sha256(artifact), status='runtime_pending')
                write_json(state, result)
                acceptance = config.get('acceptanceCommand')
                if not isinstance(acceptance, list) or not acceptance or not all(isinstance(x, str) for x in acceptance):
                    raise ValueError('候选包已生成，但未配置真实运行验收命令，不能标记通过')
                acceptance = command_argv(acceptance, allow_path_lookup=False)
                receipt = evidence / 'acceptance.json'
                run([*acceptance, '--artifact', artifact, '--source', src, '--out', out, '--evidence', evidence,
                     '--receipt', receipt, '--run-id', run_id], src, evidence / 'acceptance.log', src, minimum,
                    allow_path_lookup=False)
                accepted = json.loads(receipt.read_text())
                validate_receipt(accepted, result['artifactSha256'], run_id)
                for item in accepted['evidenceFiles']:
                    path = (evidence / item).resolve()
                    if not path.is_relative_to(evidence.resolve()) or not path.is_file() or not path.stat().st_size:
                        raise ValueError('验收日志缺失或超出本次证据目录')
                result.update(status='candidate_validated', nativeTests='passed', runtimeAcceptance='passed')
            finally:
                (src / HEADER).write_bytes(original)
                if old_args is None:
                    args_file.unlink(missing_ok=True)
                else:
                    args_file.write_bytes(old_args)
                result['sourceHeaderRestored'] = (src / HEADER).read_bytes() == original
        finally:
            lock.rmdir()
    except Exception as error:
        result.update(status='failed', error=str(error))
        raise
    finally:
        result['finishedAt'] = now()
        write_json(state, result)


def summary(evidence):
    lines = ['# Chromium 候选证据', '']
    upstream = evidence / 'upstream/latest.json'
    if upstream.exists():
        report = json.loads(upstream.read_text())
        lines += [f"官方采集：{report.get('status')}；错误：{len(report.get('errors', []))}", '']
        for name, pin in report.get('candidates', {}).items():
            lines.append(f"- {name}：{pin['version']}（{pin['commit']}）")
        for entry in report.get('unresolvedExploited', []):
            lines.append('- 尚未验证安装修复：' + ', '.join(entry['cves']))
    state = evidence / 'result.json'
    if state.exists():
        result = json.loads(state.read_text())
        lines += ['', f"平台：{result['platform']}；阶段：{result['status']}",
                  f"实际运行验收：{result['runtimeAcceptance']}；正式发布：未执行。"]
        if result.get('error'):
            lines.append('失败原因：' + result['error'])
    text = '\n'.join(lines) + '\n'
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / 'summary.md').write_text(text, encoding='utf-8')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as output:
            output.write(text)
    print(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['build', 'summary'])
    parser.add_argument('--platform', choices=PLATFORMS)
    parser.add_argument('--evidence', type=Path, required=True)
    options = parser.parse_args()
    if options.command == 'build':
        if not options.platform:
            parser.error('build 需要 --platform')
        build(options.platform, options.evidence.resolve())
    else:
        summary(options.evidence.resolve())


if __name__ == '__main__':
    main()
