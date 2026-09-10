// 真机任务的只读前置检查；不安装、不启动 App，不读取浏览资料正文或修改系统设置。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export const PACKAGE = 'app.gcsa.aegis';
const HASH = /^[a-f0-9]{64}$/;
const fail = message => { throw new Error(message); };
const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const relativeSourcePath = value => typeof value === 'string' && !path.isAbsolute(value) &&
  !value.split('/').some(part => !part || part === '.' || part === '..') && !value.includes('\0');

export function packageApkPath(output) {
  const lines = output.trim().split(/\r?\n/);
  if (lines.length !== 1 || !/^package:\/data\/app\/[A-Za-z0-9_+=~./-]+\/base\.apk$/.test(lines[0])) {
    fail('安装路径不是单一、可核验的 APK');
  }
  const value = lines[0].slice('package:'.length);
  if (value.split('/').some(part => part === '.' || part === '..') ||
      !value.split('/').some(part => part.startsWith(PACKAGE + '-'))) {
    fail('安装路径不属于指定 Aegis 包');
  }
  return value;
}

export function activeProfileRoots(fdListing) {
  // 只识别已打开的 Profile 文件路径，不把 Java 公用缓存目录当作资料目录。
  const roots = new Set();
  const pattern = / -> (\/data\/(?:user\/0|data)\/app\.gcsa\.aegis\/[^\r\n]*?)\/(?:Default|Profile \d+)\//g;
  for (const match of fdListing.matchAll(pattern)) {
    const root = match[1].replace('/data/data/', '/data/user/0/');
    if (!root.split('/').some(part => part === '..' || part === '.')) roots.add(root);
  }
  return [...roots].sort();
}

export function parseKeyguard(policy) {
  const delegate = policy.split('KeyguardServiceDelegate')[1];
  const showing = delegate?.match(/\bshowing=(true|false)\b/);
  const screen = delegate?.match(/\bscreenState=(SCREEN_STATE_\w+)/);
  return {known: !!showing && !!screen, unlocked: showing?.[1] === 'false',
    screenOn: screen?.[1] === 'SCREEN_STATE_ON'};
}

export function verifyTarget(report, expectedHash, expectedProfile) {
  if (!HASH.test(expectedHash)) fail('候选 APK 摘要无效');
  if (!/^\/data\/user\/0\/app\.gcsa\.aegis\/aegis-test-user-data-[a-z0-9-]+$/.test(expectedProfile)) {
    fail('必须指定 Aegis 独立测试资料目录');
  }
  if (report.package !== PACKAGE || report.androidUser !== '0') fail('包或 Android 用户不匹配');
  if (report.installedSha256 !== expectedHash) fail('手机安装的 APK 不是本次候选');
  if (!report.keyguard.known || !report.keyguard.unlocked || !report.keyguard.screenOn) {
    fail('真机尚未确认解锁并亮屏');
  }
  if (!report.processStable || report.profileRoots.length !== 1 || report.profileRoots[0] !== expectedProfile) {
    fail('运行中的独立 Profile 尚未证实；不得在默认资料中继续验收');
  }
  return {targetVerified: true, uiTested: false, runtimeTested: false,
    releaseEligible: false, qualification: 'target-only'};
}

function command(program, args) {
  const result = spawnSync(program, args, {encoding: 'utf8', timeout: 15000, maxBuffer: 2 * 1024 * 1024});
  if (result.status !== 0 || result.error || result.signal) {
    // 不输出远端原始 stdout/stderr，避免将路径、界面或资料内容写入诊断错误。
    fail('只读命令失败：' + path.basename(program));
  }
  return result.stdout;
}

export function inspectDevice({serial, adb}, run = command) {
  if (!/^[A-Za-z0-9_-]{4,80}$/.test(serial ?? '')) fail('需要明确的 USB 真机序列号');
  const device = run(adb, ['devices']).split(/\r?\n/)
    .some(line => line.trim() === serial + '\tdevice');
  if (!device) fail('指定真机不在线或未授权');
  const shell = (...args) => run(adb, ['-s', serial, 'shell', ...args]);
  const androidUser = shell('am', 'get-current-user').trim();
  if (androidUser !== '0') fail('当前不是预期的 Android 用户，未自动切换');
  const apk = packageApkPath(shell('pm', 'path', PACKAGE));
  const checksum = shell('sha256sum', apk).trim();
  const installedSha256 = checksum.split(/\s+/)[0];
  if (!HASH.test(installedSha256) || !checksum.endsWith('  ' + apk)) fail('无法确认安装 APK 的实际摘要');
  const metadata = shell('dumpsys', 'package', PACKAGE);
  const pid = shell('pidof', PACKAGE).trim();
  if (!/^\d+$/.test(pid)) fail('未找到唯一浏览器进程，未自动启动 App');
  const descriptors = run(adb, ['-s', serial, 'exec-out', 'run-as', PACKAGE,
    'ls', '-l', '/proc/' + pid + '/fd']);
  const keyguard = parseKeyguard(shell('dumpsys', 'window', 'policy'));
  const endPid = shell('pidof', PACKAGE).trim();
  const endApk = packageApkPath(shell('pm', 'path', PACKAGE));
  const endUser = shell('am', 'get-current-user').trim();
  return {package: PACKAGE, serial, androidUser, installedSha256,
    versionName: metadata.match(/\bversionName=([^\s]+)/)?.[1] ?? null,
    versionCode: metadata.match(/\bversionCode=(\d+)/)?.[1] ?? null,
    profileRoots: activeProfileRoots(descriptors), keyguard,
    processStable: pid === endPid && apk === endApk && androidUser === endUser,
    targetVerified: false, uiTested: false, runtimeTested: false, releaseEligible: false,
    checkedAt: new Date().toISOString()};
}

export function verifyBuildRecords(started, status, manifestHash, apkHash) {
  if (!HASH.test(apkHash) || !HASH.test(manifestHash) ||
      status.code !== 0 || status.signal !== null || status.source_unchanged !== true ||
      status.apk_sha256 !== apkHash || started.manifest_sha256 !== manifestHash) {
    fail('缺少同一候选的成功构建和 APK 证据，不能使用旧安装包');
  }
}

function preservedDeletions(sourceBeforeFile, started, manifestHash) {
  if (!sourceBeforeFile) return [];
  const beforePath = fs.realpathSync(sourceBeforeFile);
  const inputs = (Array.isArray(started.script_inputs) ? started.script_inputs : []).filter(input =>
    typeof input?.file === 'string' && path.isAbsolute(input.file) && fs.existsSync(input.file) &&
    fs.realpathSync(input.file) === beforePath);
  if (inputs.length !== 1 || inputs[0].sha256 !== sha256(beforePath)) {
    fail('原有删除记录未绑定本次构建开始时的摘要');
  }
  const before = JSON.parse(fs.readFileSync(beforePath, 'utf8'));
  const deleted = before.original_deletions_preserved;
  if (before.manifest_sha256 !== manifestHash || !Array.isArray(deleted) ||
      deleted.length !== started.original_deletions_preserved ||
      deleted.some(file => !relativeSourcePath(file)) || new Set(deleted).size !== deleted.length) {
    fail('原有删除清单与本次候选不匹配');
  }
  return deleted;
}

// 单独复核源码，不会把进行中的构建提升为成功，也不访问手机。
export function verifySourceTree({sourceRoot, manifestFile, started, sourceBeforeFile}, run = command) {
  const source = fs.realpathSync(sourceRoot);
  const manifestHash = sha256(manifestFile);
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'));
  if (started.manifest_sha256 !== manifestHash) fail('构建开始记录与源码清单不匹配');
  if (run('git', ['-C', source, 'rev-parse', 'HEAD']).trim() !== manifest.baseline ||
      started.baseline !== manifest.baseline || !Array.isArray(manifest.files) || !manifest.files.length) {
    fail('候选源码基线不匹配');
  }
  const seen = new Set();
  if (manifest.chromium_files !== undefined && !Array.isArray(manifest.chromium_files)) {
    fail('Chromium 补充源码清单无效');
  }
  // 启动恢复等上游补丁与 overlay 使用同一摘要、路径和 Git 改动边界。
  for (const file of [...manifest.files, ...(manifest.chromium_files ?? [])]) {
    if (!relativeSourcePath(file.path) ||
        seen.has(file.path) || !HASH.test(file.after_sha256)) fail('候选源码清单无效');
    seen.add(file.path);
    const real = fs.realpathSync(path.join(source, file.path));
    if (!real.startsWith(source + path.sep) || sha256(real) !== file.after_sha256) {
      fail('候选源文件已改变');
    }
  }
  const allowedDeleted = preservedDeletions(sourceBeforeFile, started, manifestHash);
  if (allowedDeleted.some(file => seen.has(file))) fail('原有删除不能覆盖候选源文件');
  const names = args => run('git', ['-C', source, ...args]).split('\0').filter(Boolean);
  // 相对 HEAD 比较同时覆盖暂存区和工作树；禁用改名折叠，两个路径都必须核对。
  const changed = names(['diff', 'HEAD', '--name-only', '--no-renames', '-z']);
  const deleted = names(['diff', 'HEAD', '--name-only', '--no-renames', '--diff-filter=D', '-z']);
  const untracked = names(['ls-files', '--others', '--exclude-standard', '-z']);
  if (JSON.stringify([...deleted].sort()) !== JSON.stringify([...allowedDeleted].sort())) {
    fail('源码删除与构建前保留清单不匹配');
  }
  if (changed.some(file => !seen.has(file) && !allowedDeleted.includes(file)) ||
      untracked.some(file => !seen.has(file))) fail('候选清单外还有源码改动或新增文件');
  return {sourceVerified: true, candidateFiles: seen.size, preservedDeletions: deleted.length,
    buildVerified: false, runtimeTested: false, releaseEligible: false};
}

export function verifyCandidateFiles({sourceRoot, manifestFile, buildDir, sourceBeforeFile}, run = command) {
  const source = fs.realpathSync(sourceRoot);
  const apk = path.join(source, 'out/AegisAndroid/apks/ChromePublic.apk');
  if ([manifestFile, path.join(buildDir, 'started.json'), path.join(buildDir, 'status.json'), apk]
    .some(file => !fs.existsSync(file))) {
    fail('候选构建尚未完成，或缺少源码清单、APK、构建记录');
  }
  const started = JSON.parse(fs.readFileSync(path.join(buildDir, 'started.json'), 'utf8'));
  const status = JSON.parse(fs.readFileSync(path.join(buildDir, 'status.json'), 'utf8'));
  const apkHash = sha256(apk);
  verifyBuildRecords(started, status, sha256(manifestFile), apkHash);
  verifySourceTree({sourceRoot: source, manifestFile, started, sourceBeforeFile}, run);
  return apkHash;
}

function main(argv) {
  if (argv.length === 0 || argv.includes('--help')) {
    console.log('只读检查：inspect --adb PATH --serial SERIAL [--output FILE]\n' +
      '验收前置：verify --adb PATH --serial SERIAL --profile DIR --source-root DIR --manifest FILE --build-dir DIR [--source-before FILE] [--output FILE]\n' +
      '有原有删除时，source-before 必须是构建 started.json 已按摘要绑定的准备记录。\n' +
      'verify 只证明目标身份，不证明入口、模型流程或发布资格；不会安装、启动、清理资料或解锁。');
    return;
  }
  const mode = argv.shift();
  if (!['inspect', 'verify'].includes(mode)) fail('不支持的模式');
  const options = {};
  const allowed = new Set(['adb', 'serial', 'output', ...(mode === 'verify' ? ['profile', 'source-root', 'manifest', 'build-dir', 'source-before'] : [])]);
  while (argv.length) {
    const flag = argv.shift();
    if (!flag.startsWith('--')) fail('参数名必须以 -- 开头');
    const key = flag.slice(2);
    const value = argv.shift();
    if (!allowed.has(key) || options[key] !== undefined || !value || value.startsWith('--')) fail('参数无效或重复');
    options[key] = value;
  }
  if (!options.adb || !options.serial) fail('缺少 adb 或 serial');
  if (options.output && fs.existsSync(options.output)) fail('不覆盖已有验收报告');
  let expectedHash;
  if (mode === 'verify') {
    if (!options.profile || !options['source-root'] || !options.manifest || !options['build-dir']) fail('缺少候选或 Profile 参数');
    expectedHash = verifyCandidateFiles({sourceRoot: options['source-root'], manifestFile: options.manifest,
      buildDir: options['build-dir'], sourceBeforeFile: options['source-before']});
  }
  const report = inspectDevice(options);
  if (expectedHash) Object.assign(report, verifyTarget(report, expectedHash, options.profile));
  const result = JSON.stringify(report, null, 2) + '\n';
  if (options.output) fs.writeFileSync(options.output, result, {flag: 'wx', mode: 0o600});
  console.log(result);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error('验收前置检查未通过：' + error.message); process.exitCode = 1; }
}
