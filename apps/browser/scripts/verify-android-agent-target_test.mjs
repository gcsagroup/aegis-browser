// 合成输入验证失败边界；另由 inspect/verify 在指定真机上实际检查。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {test} from 'node:test';
import {PACKAGE, packageApkPath, activeProfileRoots, parseKeyguard,
  verifyTarget, inspectDevice, verifyBuildRecords, verifyCandidateFiles} from './verify-android-agent-target.mjs';

const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const hash = digest('合成 APK');
const apk = '/data/app/~~safe/app.gcsa.aegis-build/base.apk';
const profile = '/data/user/0/app.gcsa.aegis/aegis-test-user-data-recovery-r1';
const unlocked = {known: true, unlocked: true, screenOn: true};
const good = () => ({package: PACKAGE, androidUser: '0', installedSha256: hash,
  keyguard: unlocked, processStable: true, profileRoots: [profile]});

test('安装路径只接受指定包的单一 APK', () => {
  assert.equal(packageApkPath('package:' + apk + '\n'), apk);
  for (const value of [
    'package:/data/app/other.app-build/base.apk',
    'package:' + apk + '\npackage:/data/app/split.apk',
    'package:/data/app/../app.gcsa.aegis-build/base.apk',
    'package:/data/app/app.gcsa.aegis-build;echo-bad/base.apk',
    'package:/data/app/app.gcsa.aegis-build/base.apk\n额外内容',
  ]) assert.throws(() => packageApkPath(value));
});

test('只用打开的 Profile 文件证明目录，不根据参数或缓存推断', () => {
  const listing = `1 -> ${profile}/Default/History\n2 -> ${profile}/Default/Session Storage/LOCK\n` +
    '3 -> /data/user/0/app.gcsa.aegis/app_chrome/paks/resources.pak\n' +
    '4 -> /data/user/0/app.gcsa.aegis/cache/opaque-file\n';
  assert.deepEqual(activeProfileRoots(listing), [profile]);
  assert.deepEqual(activeProfileRoots('--user-data-dir=' + profile), []);
  assert.deepEqual(activeProfileRoots('1 -> /data/data/app.gcsa.aegis/app_chrome/Default/History'),
    ['/data/user/0/app.gcsa.aegis/app_chrome']);
  assert.deepEqual(activeProfileRoots('1 -> /data/user/0/app.gcsa.aegis/../other/Default/History'), []);
});

test('未知、锁定或灭屏状态不能当作可交互', () => {
  assert.deepEqual(parseKeyguard('KeyguardServiceDelegate\n showing=false\n screenState=SCREEN_STATE_ON'), unlocked);
  assert.deepEqual(parseKeyguard('KeyguardServiceDelegate\n showing=false\n screenState=2\n interactiveState=2'), unlocked);
  for (const policy of ['', 'showing=false', 'KeyguardServiceDelegate\n showing=true\n screenState=SCREEN_STATE_ON',
    'KeyguardServiceDelegate\n showing=false\n screenState=SCREEN_STATE_OFF',
    'KeyguardServiceDelegate\n showing=false\n screenState=1']) {
    const report = {...good(), keyguard: parseKeyguard(policy)};
    assert.throws(() => verifyTarget(report, hash, profile));
  }
});

test('目标通过不提升为界面、运行或发布通过', () => {
  assert.deepEqual(verifyTarget(good(), hash, profile), {targetVerified: true,
    uiTested: false, runtimeTested: false, releaseEligible: false, qualification: 'target-only'});
});

for (const [name, change] of [
  ['旧 APK 即使版本号一致也拒绝', {installedSha256: digest('旧 APK'), versionName: '151.0.7922.77'}],
  ['默认资料目录拒绝', {profileRoots: ['/data/user/0/app.gcsa.aegis/app_chrome']}],
  ['没有可观察的 Profile 不能猜测', {profileRoots: []}],
  ['多个 Profile 混用拒绝', {profileRoots: [profile, '/data/user/0/app.gcsa.aegis/app_chrome']}],
  ['检查中进程或用户切换拒绝', {processStable: false}],
  ['其他 Android 用户拒绝', {androidUser: '10'}],
  ['其他应用拒绝', {package: 'other.app'}],
]) test(name, () => assert.throws(() => verifyTarget({...good(), ...change}, hash, profile)));

test('期望参数也必须为独立测试目录和有效摘要', () => {
  for (const value of ['/data/user/0/app.gcsa.aegis/app_chrome', profile + '/..', profile + '/Default', '', '/sdcard/test']) {
    assert.throws(() => verifyTarget(good(), hash, value));
  }
  assert.throws(() => verifyTarget(good(), 'wrong', profile));
});

test('未完成、失败、被中断、源码变化或错配构建不能验收旧包', () => {
  const manifest = digest('清单');
  const started = {manifest_sha256: manifest};
  const status = {code: 0, signal: null, source_unchanged: true, apk_sha256: hash};
  verifyBuildRecords(started, status, manifest, hash);
  for (const patch of [{code: 1}, {code: null}, {signal: 'SIGINT'}, {source_unchanged: false}, {apk_sha256: digest('旧包')}]) {
    assert.throws(() => verifyBuildRecords(started, {...status, ...patch}, manifest, hash));
  }
  assert.throws(() => verifyBuildRecords(started, {}, manifest, hash));
  assert.throws(() => verifyBuildRecords({manifest_sha256: hash}, status, manifest, hash));
});

function deviceStub({switchUser = false} = {}) {
  const calls = [];
  let userReads = 0;
  const run = (program, args) => {
    assert.equal(program, '/test/adb');
    calls.push(args);
    if (args[0] === 'devices') return 'List of devices attached\nfixture123\tdevice\n';
    assert.deepEqual(args.slice(0, 2), ['-s', 'fixture123']);
    const cmd = args.slice(2).join(' ');
    if (cmd === 'shell am get-current-user') return ++userReads > 1 && switchUser ? '10\n' : '0\n';
    if (cmd === 'shell pm path ' + PACKAGE) return 'package:' + apk + '\n';
    if (cmd === 'shell sha256sum ' + apk) return hash + '  ' + apk + '\n';
    if (cmd === 'shell dumpsys package ' + PACKAGE) return 'versionCode=792207704\nversionName=151.0.7922.77\n';
    if (cmd === 'shell pidof ' + PACKAGE) return '123\n';
    if (cmd === 'exec-out run-as ' + PACKAGE + ' ls -l /proc/123/fd') {
      return `1 -> ${profile}/Default/History\n2 -> /data/user/0/${PACKAGE}/cache/敏感文件名-不输出\n`;
    }
    if (cmd === 'shell dumpsys window policy') return 'KeyguardServiceDelegate\n showing=false\n screenState=SCREEN_STATE_ON';
    throw new Error('出现意外命令');
  };
  return {run, calls};
}

test('实机检查命令只读且不输出原始目录清单', () => {
  const stub = deviceStub();
  const report = inspectDevice({serial: 'fixture123', adb: '/test/adb'}, stub.run);
  assert.equal(report.installedSha256, hash);
  assert.deepEqual(report.profileRoots, [profile]);
  assert.equal(report.processStable, true);
  assert.equal(report.targetVerified, false);
  assert.equal(JSON.stringify(report).includes('敏感文件名'), false);
  assert.equal(stub.calls.some(args => args.includes('install') || args.includes('input') || args.includes('start') || args.includes('clear')), false);
  assert.throws(() => inspectDevice({serial: 'fixture123;bad', adb: '/test/adb'}, stub.run));
  assert.throws(() => inspectDevice({serial: 'missing123', adb: '/test/adb'}, stub.run));
});

test('只读检查末尾重验 Android 用户', () => {
  const stub = deviceStub({switchUser: true});
  assert.equal(inspectDevice({serial: 'fixture123', adb: '/test/adb'}, stub.run).processStable, false);
});

test('使用真实临时文件核对源码、APK、清单和路径边界', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-android-target-test-'));
  try {
    const source = path.join(dir, 'source');
    const build = path.join(dir, 'build');
    const sourceFile = path.join(source, 'chrome/example.cc');
    const candidateApk = path.join(source, 'out/AegisAndroid/apks/ChromePublic.apk');
    fs.mkdirSync(path.dirname(sourceFile), {recursive: true});
    fs.mkdirSync(path.dirname(candidateApk), {recursive: true});
    fs.mkdirSync(build);
    fs.writeFileSync(sourceFile, '候选代码');
    fs.writeFileSync(candidateApk, '合成 APK');
    const manifestFile = path.join(dir, 'manifest.json');
    const manifest = {baseline: 'a'.repeat(40), files: [{path: 'chrome/example.cc', after_sha256: digest('候选代码')}]};
    const reset = () => {
      fs.writeFileSync(manifestFile, JSON.stringify(manifest));
      fs.writeFileSync(path.join(build, 'started.json'), JSON.stringify({baseline: manifest.baseline, manifest_sha256: digest(fs.readFileSync(manifestFile))}));
      fs.writeFileSync(path.join(build, 'status.json'), JSON.stringify({code: 0, signal: null, source_unchanged: true, apk_sha256: hash}));
    };
    reset();
    const run = (_program, args) => args.includes('rev-parse') ? manifest.baseline + '\n' :
      args.includes('ls-files') || args.includes('--diff-filter=D') ? '' : 'chrome/example.cc\0';
    const options = {sourceRoot: source, manifestFile, buildDir: build};
    assert.equal(verifyCandidateFiles(options, run), hash);
    assert.throws(() => verifyCandidateFiles(options, (_program, args) => args.includes('rev-parse') ? 'other' : ''));
    assert.throws(() => verifyCandidateFiles(options, (_program, args) => args.includes('rev-parse') ? manifest.baseline : 'extra.cc\0'));
    fs.writeFileSync(sourceFile, '后改的代码');
    assert.throws(() => verifyCandidateFiles(options, run));
    fs.writeFileSync(sourceFile, '候选代码');
    fs.writeFileSync(candidateApk, '其他 APK');
    assert.throws(() => verifyCandidateFiles(options, run));
    fs.writeFileSync(candidateApk, '合成 APK');
    manifest.files.push({...manifest.files[0]}); reset();
    assert.throws(() => verifyCandidateFiles(options, run));
    manifest.files.pop();
    manifest.files[0].path = '../outside.cc'; reset();
    assert.throws(() => verifyCandidateFiles(options, run));
    fs.unlinkSync(path.join(build, 'status.json'));
    assert.throws(() => verifyCandidateFiles(options, run), /候选构建尚未完成/);
  } finally {
    fs.rmSync(dir, {recursive: true});
  }
});

// 使用真实 Git，避免模拟命令把暂存区、新增和删除遗漏成同一种状态。
function sourceFixture(callback, {preservedDeletion = false} = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-source-state-test-'));
  try {
    const source = path.join(dir, 'source');
    const build = path.join(dir, 'build');
    fs.mkdirSync(source); fs.mkdirSync(build);
    const write = (file, content) => {
      const full = path.join(source, file);
      fs.mkdirSync(path.dirname(full), {recursive: true});
      fs.writeFileSync(full, content);
    };
    const git = (...args) => execFileSync('git', ['-C', source, ...args], {encoding: 'utf8'});
    write('.gitignore', 'out/\n');
    write('chrome/example.cc', '原代码');
    write('chrome/extra.cc', '清单外原代码');
    write('chrome/old-fixture.cc', '原有夹具');
    git('init', '--quiet');
    git('add', '.');
    git('-c', 'user.name=Aegis 测试', '-c', 'user.email=aegis-test@example.invalid',
      '-c', 'commit.gpgsign=false', 'commit', '--quiet', '-m', '合成基线');
    const baseline = git('rev-parse', 'HEAD').trim();
    write('chrome/example.cc', '候选代码');
    write('out/AegisAndroid/apks/ChromePublic.apk', '合成 APK');
    const manifestFile = path.join(dir, 'manifest.json');
    fs.writeFileSync(manifestFile, JSON.stringify({baseline,
      files: [{path: 'chrome/example.cc', after_sha256: digest('候选代码')}]}));
    const manifestHash = digest(fs.readFileSync(manifestFile));
    const sourceBeforeFile = path.join(dir, 'before.json');
    const deleted = preservedDeletion ? ['chrome/old-fixture.cc'] : [];
    if (preservedDeletion) fs.unlinkSync(path.join(source, deleted[0]));
    fs.writeFileSync(sourceBeforeFile, JSON.stringify({manifest_sha256: manifestHash,
      original_deletions_preserved: deleted}));
    fs.writeFileSync(path.join(build, 'started.json'), JSON.stringify({baseline,
      manifest_sha256: manifestHash, original_deletions_preserved: deleted.length,
      script_inputs: [{file: sourceBeforeFile, sha256: digest(fs.readFileSync(sourceBeforeFile))}]}));
    fs.writeFileSync(path.join(build, 'status.json'), JSON.stringify({code: 0, signal: null,
      source_unchanged: true, apk_sha256: hash}));
    callback({options: {sourceRoot: source, manifestFile, buildDir: build, sourceBeforeFile},
      source, build, write, git});
  } finally {
    // 只清理本用例创建的单一合成仓库，不触及产品工作区。
    fs.rmSync(dir, {recursive: true});
  }
}

test('真实 Git 的清单内源码和忽略的构建产物可通过', () => {
  sourceFixture(({options}) => assert.equal(verifyCandidateFiles(options), hash));
});

function bindSupplementaryFixture(f, value) {
  const manifest = JSON.parse(fs.readFileSync(f.options.manifestFile));
  manifest.chromium_files = value;
  fs.writeFileSync(f.options.manifestFile, JSON.stringify(manifest));
  const manifestHash = digest(fs.readFileSync(f.options.manifestFile));
  const before = JSON.parse(fs.readFileSync(f.options.sourceBeforeFile));
  before.manifest_sha256 = manifestHash;
  fs.writeFileSync(f.options.sourceBeforeFile, JSON.stringify(before));
  const startedPath = path.join(f.build, 'started.json');
  const started = JSON.parse(fs.readFileSync(startedPath));
  started.manifest_sha256 = manifestHash;
  started.script_inputs[0].sha256 = digest(fs.readFileSync(f.options.sourceBeforeFile));
  fs.writeFileSync(startedPath, JSON.stringify(started));
}

test('真实 Git 将 Chromium 补充源码纳入同一候选核验', () => {
  sourceFixture(f => {
    f.write('chrome/extra.cc', '启动恢复补丁');
    bindSupplementaryFixture(f, [{path: 'chrome/extra.cc', after_sha256: digest('启动恢复补丁')}]);
    assert.equal(verifyCandidateFiles(f.options), hash);
    f.write('chrome/extra.cc', '后改启动补丁');
    assert.throws(() => verifyCandidateFiles(f.options), /候选源文件已改变/);
  });
});

for (const [name, value] of [
  ['非数组', {}],
  ['空值', null],
  ['跨清单重复', [{path: 'chrome/example.cc', after_sha256: digest('候选代码')}]],
  ['路径越界', [{path: '../escape.cc', after_sha256: digest('候选代码')}]],
  ['无效摘要', [{path: 'chrome/extra.cc', after_sha256: 'invalid'}]],
]) test('Chromium 补充源码拒绝' + name, () => {
  sourceFixture(f => {
    bindSupplementaryFixture(f, value);
    assert.throws(() => verifyCandidateFiles(f.options), /源码清单无效/);
  });
});

for (const [name, change, expected] of [
  ['暂存修改', f => { f.write('chrome/extra.cc', '后改代码'); f.git('add', 'chrome/extra.cc'); }, /清单外还有源码改动/],
  ['未跟踪新增', f => f.write('chrome/new.cc', '新增代码'), /清单外还有源码改动/],
  ['暂存新增', f => { f.write('chrome/new.cc', '新增代码'); f.git('add', 'chrome/new.cc'); }, /清单外还有源码改动/],
  ['暂存改名', f => f.git('mv', 'chrome/extra.cc', 'chrome/renamed.cc'), /源码删除/],
  ['未暂存删除', f => fs.unlinkSync(path.join(f.source, 'chrome/extra.cc')), /源码删除/],
  ['暂存删除', f => f.git('rm', '--quiet', 'chrome/extra.cc'), /源码删除/],
]) test('真实 Git 拒绝清单外' + name, () => {
  sourceFixture(f => { change(f); assert.throws(() => verifyCandidateFiles(f.options), expected); });
});

test('只有构建开始时绑定的原有删除清单可以保留', () => {
  sourceFixture(({options}) => assert.equal(verifyCandidateFiles(options), hash), {preservedDeletion: true});
});

test('原有删除记录不能授权额外删除', () => {
  sourceFixture(f => {
    fs.unlinkSync(path.join(f.source, 'chrome/extra.cc'));
    assert.throws(() => verifyCandidateFiles(f.options), /源码删除/);
  }, {preservedDeletion: true});
});

test('未提供原有删除记录时不能忽略删除', () => {
  sourceFixture(({options}) => {
    delete options.sourceBeforeFile;
    assert.throws(() => verifyCandidateFiles(options), /源码删除/);
  }, {preservedDeletion: true});
});

test('删除记录改变后即使内容合理也拒绝', () => {
  sourceFixture(({options}) => {
    fs.appendFileSync(options.sourceBeforeFile, '\n');
    assert.throws(() => verifyCandidateFiles(options), /未绑定本次构建/);
  }, {preservedDeletion: true});
});

test('原有删除被恢复也不能冒充构建时同一源码', () => {
  sourceFixture(f => {
    f.write('chrome/old-fixture.cc', '原有夹具');
    assert.throws(() => verifyCandidateFiles(f.options), /源码删除/);
  }, {preservedDeletion: true});
});

for (const [name, change] of [
  ['没有开始时绑定', record => { record.script_inputs = []; }],
  ['重复绑定', record => { record.script_inputs.push({...record.script_inputs[0]}); }],
  ['原有删除数量不符', record => { record.original_deletions_preserved = 0; }],
]) test('删除例外拒绝' + name, () => {
  sourceFixture(f => {
    const file = path.join(f.build, 'started.json');
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    change(record); fs.writeFileSync(file, JSON.stringify(record));
    assert.throws(() => verifyCandidateFiles(f.options), /未绑定本次构建|删除清单与本次候选不匹配/);
  }, {preservedDeletion: true});
});

test('清单内的暂存修改不会被误当成清单外变化', () => {
  sourceFixture(f => {
    f.git('add', 'chrome/example.cc');
    assert.equal(verifyCandidateFiles(f.options), hash);
  });
});
