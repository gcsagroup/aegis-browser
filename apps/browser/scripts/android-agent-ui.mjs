// Android USB 一次性 UI 验收：构建测试工具、工具自测、已核验候选的观察/点击/中文输入。
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {PACKAGE, inspectDevice, parseKeyguard, verifyCandidateFiles, verifyTarget} from './verify-android-agent-target.mjs';

export const HELPER = 'app.gcsa.aegis.qa.driver';
const here = path.dirname(fileURLToPath(import.meta.url));
const sources = ['android-ui-driver/AndroidManifest.xml', 'android-ui-driver/Driver.java'];
const hash = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fail = message => { throw new Error(message); };
const save = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', {flag: 'wx', mode: 0o600});

function command(program, args, options = {}) {
  const result = spawnSync(program, args, {encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024, ...options});
  if (result.error || result.signal || result.status !== 0) {
    fail(path.basename(program) + ' 未正常结束；不自动重试 UI 操作，需先检查设备状态');
  }
  return result.stdout;
}

export function helperApkPath(output) {
  const value = output.trim();
  if (!/^package:\/data\/app\/[A-Za-z0-9_+=~./-]+\/base\.apk$/.test(value) ||
      value.split('/').some(part => part === '..' || part === '.') ||
      !value.split('/').some(part => part.startsWith(HELPER + '-'))) fail('验收工具的安装路径无效');
  return value.slice(8);
}

export function parseResult(output) {
  const lines = [...output.matchAll(/^INSTRUMENTATION_RESULT: aegis_result=([A-Za-z0-9+/=]+)\r?$/gm)];
  if (lines.length !== 1 || lines[0][1].length > 400000) fail('缺少唯一、有界的 UI 结果');
  const result = JSON.parse(Buffer.from(lines[0][1], 'base64').toString('utf8'));
  if (result.ok !== true || !/^INSTRUMENTATION_CODE: -1\r?$/m.test(output)) {
    fail(typeof result.error === 'string' ? result.error.slice(0, 240) : 'UI 操作未成功');
  }
  if (result.qualification !== 'ui-driver-only' || result.runtimeTested !== false || result.releaseEligible !== false) {
    fail('UI 驱动结果不能提升为模型或发行验收');
  }
  return result;
}

export function actionRequest(action, options, prior, now = Date.now()) {
  const request = {action, profile: options.profile, apkSha256: options.apkSha256};
  if (action === 'snapshot') return request;
  if (!['click', 'set-text'].includes(action)) fail('不支持的 UI 操作');
  if (prior?.package !== PACKAGE || prior.profile !== options.profile || prior.apkSha256 !== options.apkSha256 ||
      !/^[a-f0-9]{64}$/.test(prior.snapshotSha256 ?? '') || !Array.isArray(prior.nodes)) fail('必须提供同一候选和资料目录的真实快照');
  const age = now - Date.parse(prior.observedAt);
  if (!Number.isFinite(age) || age < 0 || age > 60000) fail('快照已过期，请重新观察');
  const nodes = prior.nodes.filter(node => node.node === options.node);
  if (nodes.length !== 1 || !/^0(?:\.\d{1,3}){0,40}$/.test(options.node ?? '')) fail('节点不存在或不唯一');
  const node = nodes[0];
  if (!node.visible || !node.enabled || node.password || (action === 'click' ? !node.clickable : !node.editable)) {
    fail('节点不可操作，或属于密码框');
  }
  Object.assign(request, {snapshotSha256: prior.snapshotSha256, node: options.node});
  if (action === 'set-text') {
    if (typeof options.text !== 'string' || options.text.length > 8192 || options.text.includes('\0')) fail('输入文本无效或过长');
    request.text = options.text;
  }
  return request;
}

function build({sdk, jdk, output}) {
  if (!sdk || !jdk || !output || !path.isAbsolute(output) || fs.existsSync(output)) fail('构建需要 SDK、JDK 和不存在的绝对输出目录');
  const android = path.join(sdk, 'platforms/android-36/android.jar');
  const tool = name => path.join(sdk, 'build-tools/36.1.0', name);
  for (const file of [android, ...['aapt2', 'd8', 'apksigner', 'zipalign'].map(tool), path.join(jdk, 'bin/javac'), path.join(jdk, 'bin/keytool')]) {
    if (!fs.existsSync(file)) fail('缺少指定 SDK/JDK 工具：' + path.basename(file));
  }
  fs.mkdirSync(output, {mode: 0o700});
  const classes = path.join(output, 'classes');
  const dex = path.join(output, 'dex');
  fs.mkdirSync(classes); fs.mkdirSync(dex);
  const sourceHashes = sources.map(file => ({file, sha256: hash(path.join(here, file))}));
  const environment = {...process.env, JAVA_HOME: jdk, PATH: path.join(jdk, 'bin') + path.delimiter + process.env.PATH};
  const run = (program, args, extra = {}) => command(program, args, {env: environment, ...extra});
  run(path.join(jdk, 'bin/javac'), ['--release', '8', '-encoding', 'UTF-8', '-cp', android, '-d', classes, path.join(here, sources[1])]);
  const classRoot = path.join(classes, 'app/gcsa/aegis/qa/driver');
  const classFiles = fs.readdirSync(classRoot).filter(file => file.endsWith('.class')).map(file => path.join(classRoot, file));
  run(tool('d8'), ['--lib', android, '--min-api', '26', '--output', dex, ...classFiles]);
  const unsigned = path.join(output, 'unsigned.apk');
  run(tool('aapt2'), ['link', '-I', android, '--manifest', path.join(here, sources[0]), '-o', unsigned]);
  run('/usr/bin/zip', ['-q', unsigned, 'classes.dex'], {cwd: dex});
  const aligned = path.join(output, 'aligned.apk');
  run(tool('zipalign'), ['-p', '4', unsigned, aligned]);
  // 临时测试签名只存在仓库外的私有目录，不复用产品密钥，不打印密码。
  const keyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-ui-key-'));
  fs.chmodSync(keyDir, 0o700);
  const keyFile = path.join(keyDir, 'driver.p12');
  const signingEnvironment = {...environment, AEGIS_QA_SIGN_PASS: crypto.randomBytes(32).toString('hex')};
  const apk = path.join(output, 'driver.apk');
  try {
    command(path.join(jdk, 'bin/keytool'), ['-genkeypair', '-keystore', keyFile, '-storetype', 'PKCS12',
      '-storepass:env', 'AEGIS_QA_SIGN_PASS', '-keypass:env', 'AEGIS_QA_SIGN_PASS', '-alias', 'qa',
      '-keyalg', 'RSA', '-keysize', '2048', '-validity', '30', '-dname', 'CN=Aegis local UI test'], {env: signingEnvironment});
    command(tool('apksigner'), ['sign', '--ks', keyFile, '--ks-pass', 'env:AEGIS_QA_SIGN_PASS', '--key-pass',
      'env:AEGIS_QA_SIGN_PASS', '--out', apk, aligned], {env: signingEnvironment});
  } finally {
    // 仅清理本函数刚创建的单一测试密钥；不递归删除输出或用户目录。
    if (fs.existsSync(keyFile)) fs.unlinkSync(keyFile);
    fs.rmdirSync(keyDir);
    delete signingEnvironment.AEGIS_QA_SIGN_PASS;
  }
  run(tool('apksigner'), ['verify', '--verbose', apk]);
  for (const item of sourceHashes) if (hash(path.join(here, item.file)) !== item.sha256) fail('构建期间验收工具源码改变');
  const record = {package: HELPER, apkSha256: hash(apk), sourceHashes, builtAt: new Date().toISOString(),
    temporarySigningKeyRemoved: true, runtimeTested: false, releaseEligible: false};
  save(path.join(output, 'build.json'), record);
  console.log(JSON.stringify(record, null, 2));
}

function driverArtifact(directory) {
  const record = JSON.parse(fs.readFileSync(path.join(directory, 'build.json'), 'utf8'));
  const apk = path.join(directory, 'driver.apk');
  if (record.package !== HELPER || record.apkSha256 !== hash(apk) ||
      JSON.stringify(record.sourceHashes) !== JSON.stringify(sources.map(file => ({file, sha256: hash(path.join(here, file))})))) {
    fail('验收工具与构建或源码记录不符');
  }
  return {apk, record};
}

function interact(action, options) {
  if (!options.adb || !/^[A-Za-z0-9_-]{4,80}$/.test(options.serial ?? '') || !options['driver-build']) fail('缺少指定真机或验收工具');
  if (options.output && fs.existsSync(options.output)) fail('不覆盖已有验收报告');
  const adb = (...args) => command(options.adb, ['-s', options.serial, ...args]);
  if (!command(options.adb, ['devices']).split(/\r?\n/).some(line => line.trim() === options.serial + '\tdevice')) fail('指定真机不在线或未授权');
  const keyguard = parseKeyguard(adb('shell', 'dumpsys', 'window', 'policy'));
  if (adb('shell', 'am', 'get-current-user').trim() !== '0' || !keyguard.known || !keyguard.unlocked || !keyguard.screenOn) {
    fail('真机不是指定用户，或尚未解锁亮屏；未安装、启动或操作应用');
  }
  const {apk, record} = driverArtifact(options['driver-build']);
  let request;
  if (action === 'self-test') {
    request = {action};
  } else {
    const apkSha256 = verifyCandidateFiles({sourceRoot: options['source-root'], manifestFile: options.manifest,
      buildDir: options['build-dir'], sourceBeforeFile: options['source-before']});
    verifyTarget(inspectDevice(options), apkSha256, options.profile);
    request = actionRequest(action, {...options, apkSha256}, options.snapshot ? JSON.parse(fs.readFileSync(options.snapshot, 'utf8')) : undefined);
  }
  const inventory = adb('shell', 'pm', 'list', 'packages', HELPER).trim();
  if (!inventory && action === 'self-test') adb('install', '-t', apk);
  else if (inventory !== 'package:' + HELPER) fail('验收工具未安装或存在同名歧义；仅 self-test 可以安装新工具');
  const installed = helperApkPath(adb('shell', 'pm', 'path', HELPER));
  const checksum = adb('shell', 'sha256sum', installed).trim();
  if (checksum !== record.apkSha256 + '  ' + installed) fail('设备已有不同的验收工具；不覆盖、不卸载未知安装');
  const encoded = Buffer.from(JSON.stringify(request)).toString('base64');
  const result = parseResult(adb('shell', 'am', 'instrument', '-w', '-r', '-e', 'request_base64', encoded, HELPER + '/.Driver'));
  if (action !== 'self-test') {
    verifyTarget(inspectDevice(options), request.apkSha256, request.profile);
    Object.assign(result, {profile: request.profile, apkSha256: request.apkSha256});
  }
  Object.assign(result, {observedAt: new Date().toISOString(), serial: options.serial, driverSha256: record.apkSha256});
  if (options.output) save(options.output, result);
  console.log(JSON.stringify(result, null, 2));
}

function main(argv) {
  if (!argv.length || argv.includes('--help')) {
    console.log('构建：build --sdk DIR --jdk DIR --output NEW_DIR\n' +
      '工具真机自测：self-test --adb FILE --serial SERIAL --driver-build DIR [--output NEW_FILE]\n' +
      '浏览器观察：snapshot，另需 --profile DIR --source-root DIR --manifest FILE --build-dir DIR [--source-before FILE]\n' +
      '点击/中文输入：click 或 set-text，另需 --snapshot FILE --node ID [--text TEXT]\n' +
      '不会解锁、修改系统权限、接触默认 Profile 或替换浏览器；自测会安装不存在的独立测试工具。');
    return;
  }
  const action = argv.shift();
  const allowed = action === 'build' ? ['sdk', 'jdk', 'output'] : ['adb', 'serial', 'driver-build', 'output',
    ...(action === 'self-test' ? [] : ['profile', 'source-root', 'manifest', 'build-dir', 'source-before', 'snapshot', 'node', 'text'])];
  if (!['build', 'self-test', 'snapshot', 'click', 'set-text'].includes(action)) fail('未知模式');
  const options = {};
  while (argv.length) {
    const flag = argv.shift();
    const value = argv.shift();
    if (!flag.startsWith('--') || !allowed.includes(flag.slice(2)) || options[flag.slice(2)] !== undefined || value === undefined || value.startsWith('--')) fail('参数无效或重复');
    options[flag.slice(2)] = value;
  }
  if (action === 'build') build(options);
  else interact(action, options);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error('Android UI 验收未通过：' + error.message); process.exitCode = 1; }
}
