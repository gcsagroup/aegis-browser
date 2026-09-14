// Android USB 一次性 UI 验收：构建测试工具、工具自测、已核验候选的观察/点击/中文输入。
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {PACKAGE, inspectDevice, parseKeyguard, verifyCandidateFiles, verifyTarget} from './verify-android-agent-target.mjs';

export const HELPER = 'app.gcsa.aegis.qa.driver';
export const SELF_TEST_CASES = Object.freeze([
  'unicode-input',
  'stale-snapshot-rejected',
  'wrong-package-rejected',
  'password-edit-rejected',
  'click-updates-result',
  'password-value-hidden',
]);
export const JACOCO_ARTIFACTS = Object.freeze({
  version: '0.8.14',
  cli: Object.freeze({
    file: 'org.jacoco.cli-0.8.14-nodeps.jar',
    url: 'https://repo.maven.apache.org/maven2/org/jacoco/org.jacoco.cli/0.8.14/org.jacoco.cli-0.8.14-nodeps.jar',
    sha1: 'e0fb9637fca1384d0da018a9738d776a4b1badc1',
    sha256: '811c7f8c6b358c5d68a8973cfa867f6892be7a671b697a4b13c4b447e6daf75c',
  }),
  runtime: Object.freeze({
    file: 'org.jacoco.agent-0.8.14-runtime.jar',
    url: 'https://repo.maven.apache.org/maven2/org/jacoco/org.jacoco.agent/0.8.14/org.jacoco.agent-0.8.14-runtime.jar',
    sha1: '4bb9b49d4e6c5b042fc7e6b4f1e3e808f7441dde',
    sha256: '3fb76eea65f81bd9415202bab34b6571728841dff1ab8e6bbe81adc2e299face',
  }),
});
const here = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(here, '../../..');
const sources = ['android-ui-driver/AndroidManifest.xml', 'android-ui-driver/Driver.java',
  'android-ui-driver/jacoco-agent.properties'];
const coverageConfiguration = sources[2];
const fail = message => { throw new Error(message); };
const hash = (file, algorithm = 'sha256') => crypto.createHash(algorithm).update(fs.readFileSync(file)).digest('hex');
const hashText = value => crypto.createHash('sha256').update(value).digest('hex');
const save = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n', {flag: 'wx', mode: 0o600});

function command(program, args, options = {}) {
  const result = spawnSync(program, args, {encoding: 'utf8', timeout: 30000, maxBuffer: 2 * 1024 * 1024, ...options});
  if (result.error || result.signal || result.status !== 0) {
    const termination = result.error?.code ?? (result.signal ? 'signal-' + result.signal : 'exit-' + result.status);
    fail(path.basename(program) + ' 未正常结束（' + termination + '）；不自动重试，需先检查环境或设备状态');
  }
  return result.stdout;
}

function requireNewAbsolute(value, label) {
  if (!value || !path.isAbsolute(value) || fs.existsSync(value)) fail(label + '必须是不存在的绝对路径');
}

function listClassFiles(directory) {
  const output = [];
  const visit = current => {
    for (const entry of fs.readdirSync(current, {withFileTypes: true})) {
      const file = path.join(current, entry.name);
      if (entry.isDirectory()) visit(file);
      else if (entry.isFile() && entry.name.endsWith('.class')) output.push(file);
    }
  };
  visit(directory);
  return output.sort();
}

function classHashes(directory) {
  return listClassFiles(directory).map(file => ({
    file: path.relative(directory, file).split(path.sep).join('/'),
    sha256: hash(file),
  }));
}

function hasJacocoMarker(file) {
  const data = fs.readFileSync(file);
  return data.includes(Buffer.from('org/jacoco/')) || data.includes(Buffer.from('$jacoco'));
}

function repositoryState() {
  const head = command('git', ['rev-parse', 'HEAD'], {cwd: repositoryRoot}).trim();
  if (process.env.AEGIS_TESTED_SHA && process.env.AEGIS_TESTED_SHA !== head) fail('工作流 tested SHA 与 checkout HEAD 不一致');
  return {head, dirty: command('git', ['status', '--porcelain=v1', '--untracked-files=all'], {cwd: repositoryRoot}).trim() !== ''};
}

function verifyArtifact(file, artifact) {
  if (!fs.existsSync(file) || !fs.statSync(file).isFile() || hash(file, 'sha1') !== artifact.sha1 || hash(file) !== artifact.sha256) {
    fail('JaCoCo 工件校验失败：' + artifact.file);
  }
}

function fetchJacoco({output}) {
  requireNewAbsolute(output, 'JaCoCo 输出目录');
  fs.mkdirSync(output, {mode: 0o700});
  for (const artifact of [JACOCO_ARTIFACTS.cli, JACOCO_ARTIFACTS.runtime]) {
    const file = path.join(output, artifact.file);
    command('curl', ['--fail', '--location', '--silent', '--show-error', '--output', file, artifact.url], {timeout: 60000});
    fs.chmodSync(file, 0o600);
    verifyArtifact(file, artifact);
  }
  const record = {source: 'Maven Central', version: JACOCO_ARTIFACTS.version,
    artifacts: [JACOCO_ARTIFACTS.cli, JACOCO_ARTIFACTS.runtime]};
  save(path.join(output, 'tools.json'), record);
  console.log(JSON.stringify(record, null, 2));
}

function coverageTools(directory) {
  if (!directory || !path.isAbsolute(directory)) fail('coverage 构建需要绝对 JaCoCo 工件目录');
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'tools.json'), 'utf8'));
  if (manifest.source !== 'Maven Central' || manifest.version !== JACOCO_ARTIFACTS.version ||
      JSON.stringify(manifest.artifacts) !== JSON.stringify([JACOCO_ARTIFACTS.cli, JACOCO_ARTIFACTS.runtime])) {
    fail('JaCoCo 工件清单与固定版本不符');
  }
  const cli = path.join(directory, JACOCO_ARTIFACTS.cli.file);
  const runtime = path.join(directory, JACOCO_ARTIFACTS.runtime.file);
  verifyArtifact(cli, JACOCO_ARTIFACTS.cli);
  verifyArtifact(runtime, JACOCO_ARTIFACTS.runtime);
  return {cli, runtime};
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
  if (lines.length !== 1 || lines[0][1].length > 400000) {
    const keys = prefix => [...output.matchAll(new RegExp('^INSTRUMENTATION_' + prefix + ': ([A-Za-z][A-Za-z0-9_.-]{0,63})=', 'gm'))]
      .map(match => match[1]).slice(0, 16);
    const codes = [...output.matchAll(/^INSTRUMENTATION_CODE: (-?\d+)\r?$/gm)]
      .map(match => Number(match[1])).slice(0, 8);
    fail('缺少唯一、有界的 UI 结果；instrumentation 协议=' + JSON.stringify({
      resultKeys: keys('RESULT'), statusKeys: keys('STATUS'), codes,
      failed: /^INSTRUMENTATION_FAILED:/m.test(output),
    }));
  }
  const result = JSON.parse(Buffer.from(lines[0][1], 'base64').toString('utf8'));
  if (result.ok !== true || !/^INSTRUMENTATION_CODE: -1\r?$/m.test(output)) {
    fail(typeof result.error === 'string' ? result.error.slice(0, 240) : 'UI 操作未成功');
  }
  if (result.qualification !== 'ui-driver-only' || result.runtimeTested !== false || result.releaseEligible !== false) {
    fail('UI 驱动结果不能提升为模型或发行验收');
  }
  return result;
}

export function parseCoverageExec(output, required) {
  const lines = [...output.matchAll(/^INSTRUMENTATION_RESULT: aegis_coverage=([A-Za-z0-9+/=]+)\r?$/gm)];
  if (!required) {
    if (lines.length !== 0) fail('normal 工具意外返回 coverage 数据');
    return null;
  }
  if (lines.length !== 1 || lines[0][1].length > 2800000) fail('缺少唯一、有界的 JaCoCo exec 数据');
  const data = Buffer.from(lines[0][1], 'base64');
  if (data.length < 5 || data.length > 2 * 1024 * 1024) fail('JaCoCo exec 数据大小无效');
  return data;
}

export function validateSelfTestResult(result) {
  if (result.browserTested !== false || result.selfTestCases !== SELF_TEST_CASES.length || !Array.isArray(result.selfTestResults)) {
    fail('工具自测结果缺少 6 个真实 fixture，或误称浏览器已测试');
  }
  const actual = result.selfTestResults.map(item => item?.id);
  if (JSON.stringify(actual) !== JSON.stringify(SELF_TEST_CASES) || result.selfTestResults.some(item => item.passed !== true)) {
    fail('工具自测 fixture 名称、顺序或结果不符');
  }
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

function build(options) {
  const {sdk, jdk, output} = options;
  const coverageEnabled = options.coverage === true;
  if (!sdk || !jdk || !output || !path.isAbsolute(output) || fs.existsSync(output)) fail('构建需要 SDK、JDK 和不存在的绝对输出目录');
  if (coverageEnabled !== Boolean(options['jacoco-dir'])) fail('只有显式 coverage 构建可以指定固定 JaCoCo 工件目录');
  const jacoco = coverageEnabled ? coverageTools(options['jacoco-dir']) : null;
  const repository = repositoryState();
  const android = path.join(sdk, 'platforms/android-36/android.jar');
  const tool = name => path.join(sdk, 'build-tools/36.1.0', name);
  for (const file of [android, ...['aapt2', 'd8', 'apksigner', 'zipalign'].map(tool), path.join(jdk, 'bin/java'),
    path.join(jdk, 'bin/javac'), path.join(jdk, 'bin/keytool')]) {
    if (!fs.existsSync(file)) fail('缺少指定 SDK/JDK 工具：' + path.basename(file));
  }
  fs.mkdirSync(output, {mode: 0o700});
  const classes = path.join(output, 'classes-original');
  const dex = path.join(output, 'dex');
  fs.mkdirSync(classes); fs.mkdirSync(dex);
  const sourceHashes = sources.map(file => ({file, sha256: hash(path.join(here, file))}));
  const environment = {...process.env, JAVA_HOME: jdk, PATH: path.join(jdk, 'bin') + path.delimiter + process.env.PATH};
  const run = (program, args, extra = {}) => command(program, args, {env: environment, ...extra});
  run(path.join(jdk, 'bin/javac'), ['--release', '8', '-encoding', 'UTF-8', '-cp', android, '-d', classes, path.join(here, sources[1])]);
  const originals = classHashes(classes);
  if (!originals.some(item => item.file === 'app/gcsa/aegis/qa/driver/Driver.class') ||
      originals.some(item => hasJacocoMarker(path.join(classes, item.file)))) fail('原始 Driver class 缺失或已被插桩');
  let dexInputs = listClassFiles(classes);
  if (coverageEnabled) {
    const instrumentedClasses = path.join(output, 'classes-instrumented');
    run(path.join(jdk, 'bin/java'), ['-jar', jacoco.cli, 'instrument', classes, '--dest', instrumentedClasses]);
    const instrumented = classHashes(instrumentedClasses);
    if (JSON.stringify(instrumented.map(item => item.file)) !== JSON.stringify(originals.map(item => item.file)) ||
        !instrumented.some(item => hasJacocoMarker(path.join(instrumentedClasses, item.file)))) {
      fail('JaCoCo 插桩没有保持完整 Driver class 集');
    }
    dexInputs = [...listClassFiles(instrumentedClasses), jacoco.runtime];
    fs.copyFileSync(jacoco.cli, path.join(output, 'jacoco-cli.jar'), fs.constants.COPYFILE_EXCL);
    fs.chmodSync(path.join(output, 'jacoco-cli.jar'), 0o600);
  }
  run(tool('d8'), ['--lib', android, '--min-api', '26', '--output', dex, ...dexInputs], {timeout: 60000});
  const dexHasJacoco = hasJacocoMarker(path.join(dex, 'classes.dex'));
  if (dexHasJacoco !== coverageEnabled) fail(coverageEnabled ? 'coverage DEX 缺少 JaCoCo runtime/probe' : 'normal DEX 意外包含 JaCoCo');
  const unsigned = path.join(output, 'unsigned.apk');
  run(tool('aapt2'), ['link', '-I', android, '--manifest', path.join(here, sources[0]), '-o', unsigned]);
  run('/usr/bin/zip', ['-q', unsigned, 'classes.dex'], {cwd: dex});
  if (coverageEnabled) run('/usr/bin/zip', ['-q', '-j', unsigned, path.join(here, coverageConfiguration)]);
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
  const apkEntries = new Set(run('/usr/bin/unzip', ['-Z1', apk]).trim().split(/\r?\n/));
  if (apkEntries.has('jacoco-agent.properties') !== coverageEnabled ||
      (coverageEnabled && run('/usr/bin/unzip', ['-p', apk, 'jacoco-agent.properties']) !==
        fs.readFileSync(path.join(here, coverageConfiguration), 'utf8'))) {
    fail('JaCoCo offline 配置没有与 coverage APK 隔离');
  }
  for (const item of sourceHashes) if (hash(path.join(here, item.file)) !== item.sha256) fail('构建期间验收工具源码改变');
  const coverage = coverageEnabled ? {enabled: true, jacocoVersion: JACOCO_ARTIFACTS.version,
    cliSha256: JACOCO_ARTIFACTS.cli.sha256, runtimeSha256: JACOCO_ARTIFACTS.runtime.sha256,
    configurationSha256: hash(path.join(here, coverageConfiguration)), output: 'none', dumpOnExit: false,
    dexContainsJacoco: true} : {enabled: false, dexContainsJacoco: false};
  const record = {package: HELPER, buildMode: coverageEnabled ? 'coverage' : 'normal', apkSha256: hash(apk), sourceHashes,
    originalClassFiles: originals, originalClassSetSha256: hashText(JSON.stringify(originals)), repository,
    toolchain: {sdk, jdk, androidPlatform: '36', buildTools: '36.1.0'}, coverage,
    builtAt: new Date().toISOString(), temporarySigningKeyRemoved: true, browserTested: false,
    runtimeTested: false, releaseEligible: false};
  save(path.join(output, 'build.json'), record);
  console.log(JSON.stringify(record, null, 2));
}

function driverArtifact(directory) {
  const record = JSON.parse(fs.readFileSync(path.join(directory, 'build.json'), 'utf8'));
  const apk = path.join(directory, 'driver.apk');
  const currentClasses = classHashes(path.join(directory, 'classes-original'));
  const expectedCoverage = record.coverage?.enabled === true ? {enabled: true, jacocoVersion: JACOCO_ARTIFACTS.version,
    cliSha256: JACOCO_ARTIFACTS.cli.sha256, runtimeSha256: JACOCO_ARTIFACTS.runtime.sha256,
    configurationSha256: hash(path.join(here, coverageConfiguration)), output: 'none', dumpOnExit: false,
    dexContainsJacoco: true} : {enabled: false, dexContainsJacoco: false};
  const apkEntries = new Set(command('/usr/bin/unzip', ['-Z1', apk]).trim().split(/\r?\n/));
  const hasCoverageConfiguration = apkEntries.has('jacoco-agent.properties');
  if (record.package !== HELPER || record.apkSha256 !== hash(apk) || record.browserTested !== false ||
      record.repository?.head !== command('git', ['rev-parse', 'HEAD'], {cwd: repositoryRoot}).trim() ||
      JSON.stringify(record.sourceHashes) !== JSON.stringify(sources.map(file => ({file, sha256: hash(path.join(here, file))}))) ||
      JSON.stringify(record.originalClassFiles) !== JSON.stringify(currentClasses) ||
      record.originalClassSetSha256 !== hashText(JSON.stringify(currentClasses)) ||
      JSON.stringify(record.coverage) !== JSON.stringify(expectedCoverage) ||
      record.coverage.dexContainsJacoco !== hasJacocoMarker(path.join(directory, 'dex/classes.dex')) ||
      hasCoverageConfiguration !== record.coverage.enabled ||
      (hasCoverageConfiguration && command('/usr/bin/unzip', ['-p', apk, 'jacoco-agent.properties']) !==
        fs.readFileSync(path.join(here, coverageConfiguration), 'utf8'))) {
    fail('验收工具与构建、class 或源码记录不符');
  }
  if (record.coverage?.enabled) verifyArtifact(path.join(directory, 'jacoco-cli.jar'), JACOCO_ARTIFACTS.cli);
  else if (fs.existsSync(path.join(directory, 'jacoco-cli.jar'))) fail('normal 构建意外携带 JaCoCo CLI');
  return {apk, record};
}

function verifyBuildModes(options) {
  requireNewAbsolute(options.output, '构建模式验证报告');
  const normal = driverArtifact(options['normal-build']);
  const coverage = driverArtifact(options['coverage-build']);
  if (normal.record.buildMode !== 'normal' || normal.record.coverage.enabled !== false ||
      coverage.record.buildMode !== 'coverage' || coverage.record.coverage.enabled !== true ||
      normal.record.apkSha256 === coverage.record.apkSha256 ||
      normal.record.repository.head !== coverage.record.repository.head ||
      JSON.stringify(normal.record.sourceHashes) !== JSON.stringify(coverage.record.sourceHashes) ||
      JSON.stringify(normal.record.originalClassFiles) !== JSON.stringify(coverage.record.originalClassFiles) ||
      normal.record.originalClassSetSha256 !== coverage.record.originalClassSetSha256) {
    fail('normal/coverage 构建身份、源码、原始 class 或 JaCoCo 隔离不符');
  }
  const result = {kind: 'aegis-android-java-build-mode-verification', testedSha: normal.record.repository.head,
    sourceHashes: normal.record.sourceHashes, originalClassSetSha256: normal.record.originalClassSetSha256,
    normal: {apkSha256: normal.record.apkSha256, dexContainsJacoco: false},
    coverage: {apkSha256: coverage.record.apkSha256, dexContainsJacoco: true, jacocoVersion: JACOCO_ARTIFACTS.version,
      configurationSha256: coverage.record.coverage.configurationSha256, output: 'none', dumpOnExit: false},
    passed: true};
  save(options.output, result);
  console.log(JSON.stringify(result, null, 2));
}

function expectedClassNames(record) {
  return record.originalClassFiles.map(item => item.file.replace(/\.class$/, '')).sort();
}

export function summarizeJacocoXml(xml, expectedClasses) {
  const packageMatch = xml.match(/<package name="app\/gcsa\/aegis\/qa\/driver">([\s\S]*?)<\/package>/);
  if (!packageMatch) fail('JaCoCo XML 缺少 Driver package');
  const actualClasses = [...packageMatch[1].matchAll(/<class name="([^"]+)"/g)].map(match => match[1]).sort();
  if (JSON.stringify(actualClasses) !== JSON.stringify([...expectedClasses].sort())) fail('JaCoCo XML 的 Driver class 集与原始 class 不一致');
  const source = packageMatch[1].match(/<sourcefile name="Driver\.java">([\s\S]*?)<\/sourcefile>/);
  if (!source) fail('JaCoCo XML 缺少 Driver.java');
  const line = source[1].match(/<counter type="LINE" missed="(\d+)" covered="(\d+)"\/>/);
  if (!line) fail('JaCoCo XML 缺少 Driver.java 行计数');
  const missed = Number(line[1]);
  const covered = Number(line[2]);
  const total = missed + covered;
  if (!Number.isSafeInteger(total) || total <= 0 || covered <= 0) fail('Driver.java 没有真实已覆盖行');
  return {measurement: 'jacoco-line-counter', covered, missed, total,
    percent: Number((covered * 100 / total).toFixed(4))};
}

function generateCoverageEvidence(directory, executionData, driverBuild, record, result) {
  requireNewAbsolute(directory, 'coverage 输出目录');
  fs.mkdirSync(directory, {mode: 0o700});
  const exec = path.join(directory, 'driver.exec');
  fs.writeFileSync(exec, executionData, {flag: 'wx', mode: 0o600});
  const xml = path.join(directory, 'jacoco.xml');
  command(path.join(record.toolchain.jdk, 'bin/java'), ['-jar', path.join(driverBuild, 'jacoco-cli.jar'), 'report', exec,
    '--classfiles', path.join(driverBuild, 'classes-original'), '--sourcefiles', path.join(here, 'android-ui-driver'), '--xml', xml],
    {env: {...process.env, JAVA_HOME: record.toolchain.jdk}, timeout: 60000});
  const line = summarizeJacocoXml(fs.readFileSync(xml, 'utf8'), expectedClassNames(record));
  const summary = {kind: 'aegis-android-java-coverage', testedSha: record.repository.head,
    repositoryDirtyAtBuild: record.repository.dirty,
    driverSourceSha256: record.sourceHashes.find(item => item.file.endsWith('Driver.java')).sha256,
    originalClassSetSha256: record.originalClassSetSha256, execSha256: hash(exec), xmlSha256: hash(xml),
    jacoco: {version: JACOCO_ARTIFACTS.version, cliSha256: JACOCO_ARTIFACTS.cli.sha256,
      runtimeSha256: JACOCO_ARTIFACTS.runtime.sha256}, fixtureCases: result.selfTestResults,
    selfTestCases: result.selfTestCases, browserTested: false, line, passed: true};
  save(path.join(directory, 'summary.json'), summary);
  return summary;
}

function interact(action, options) {
  if (!options.adb || !/^[A-Za-z0-9_-]{4,80}$/.test(options.serial ?? '') || !options['driver-build']) fail('缺少指定真机或验收工具');
  if (options.output && fs.existsSync(options.output)) fail('不覆盖已有验收报告');
  const {apk, record} = driverArtifact(options['driver-build']);
  const coverageEnabled = record.coverage?.enabled === true;
  if (coverageEnabled && action !== 'self-test') fail('coverage 工具只允许自身 fixture 验收');
  if (action === 'self-test' && coverageEnabled) requireNewAbsolute(options['coverage-output'], 'coverage 输出目录');
  else if (options['coverage-output']) fail('只有 coverage 工具 self-test 可以导出 coverage');
  const adb = (...args) => command(options.adb, ['-s', options.serial, ...args]);
  if (!command(options.adb, ['devices']).split(/\r?\n/).some(line => line.trim() === options.serial + '\tdevice')) fail('指定真机不在线或未授权');
  const keyguard = parseKeyguard(adb('shell', 'dumpsys', 'window', 'policy'));
  if (adb('shell', 'am', 'get-current-user').trim() !== '0' || !keyguard.known || !keyguard.unlocked || !keyguard.screenOn) {
    fail('真机不是指定用户，或尚未解锁亮屏；未安装、启动或操作应用');
  }
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
  const instrumentArgs = ['shell', 'am', 'instrument', '-w', '-r', '-e', 'request_base64', encoded];
  if (coverageEnabled) instrumentArgs.push('-e', 'jacoco_coverage', 'true');
  instrumentArgs.push(HELPER + '/.Driver');
  const instrumentationOutput = command(options.adb, ['-s', options.serial, ...instrumentArgs], {maxBuffer: 4 * 1024 * 1024});
  const result = parseResult(instrumentationOutput);
  const executionData = parseCoverageExec(instrumentationOutput, coverageEnabled);
  if (action === 'self-test') validateSelfTestResult(result);
  if (action !== 'self-test') {
    verifyTarget(inspectDevice(options), request.apkSha256, request.profile);
    Object.assign(result, {profile: request.profile, apkSha256: request.apkSha256});
  }
  Object.assign(result, {observedAt: new Date().toISOString(), serial: options.serial, driverSha256: record.apkSha256,
    driverBuildMode: record.buildMode, testedSha: record.repository.head});
  if (coverageEnabled) result.coverage = generateCoverageEvidence(options['coverage-output'], executionData,
    options['driver-build'], record, result);
  if (options.output) save(options.output, result);
  console.log(JSON.stringify(result, null, 2));
}

function main(argv) {
  if (!argv.length || argv.includes('--help')) {
    console.log('下载固定 coverage 工件：fetch-jacoco --output NEW_DIR\n' +
      '构建：build --sdk DIR --jdk DIR --output NEW_DIR [--coverage --jacoco-dir DIR]\n' +
      '成对验证：verify-build-modes --normal-build DIR --coverage-build DIR --output NEW_FILE\n' +
      '工具真机自测：self-test --adb FILE --serial SERIAL --driver-build DIR [--coverage-output NEW_DIR] [--output NEW_FILE]\n' +
      '浏览器观察：snapshot，另需 --profile DIR --source-root DIR --manifest FILE --build-dir DIR [--source-before FILE]\n' +
      '点击/中文输入：click 或 set-text，另需 --snapshot FILE --node ID [--text TEXT]\n' +
      '不会解锁、修改系统权限、接触默认 Profile 或替换浏览器；自测会安装不存在的独立测试工具。');
    return;
  }
  const action = argv.shift();
  const allowed = action === 'fetch-jacoco' ? ['output'] : action === 'build' ? ['sdk', 'jdk', 'output', 'coverage', 'jacoco-dir'] :
    action === 'verify-build-modes' ? ['normal-build', 'coverage-build', 'output'] : ['adb', 'serial', 'driver-build', 'coverage-output', 'output',
      ...(action === 'self-test' ? [] : ['profile', 'source-root', 'manifest', 'build-dir', 'source-before', 'snapshot', 'node', 'text'])];
  if (!['fetch-jacoco', 'build', 'verify-build-modes', 'self-test', 'snapshot', 'click', 'set-text'].includes(action)) fail('未知模式');
  const options = {};
  while (argv.length) {
    const flag = argv.shift();
    const key = flag.startsWith('--') ? flag.slice(2) : '';
    if (!allowed.includes(key) || options[key] !== undefined) fail('参数无效或重复');
    if (action === 'build' && key === 'coverage') options[key] = true;
    else {
      const value = argv.shift();
      if (value === undefined || value.startsWith('--')) fail('参数缺少值');
      options[key] = value;
    }
  }
  if (action === 'fetch-jacoco') fetchJacoco(options);
  else if (action === 'build') build(options);
  else if (action === 'verify-build-modes') verifyBuildModes(options);
  else interact(action, options);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (error) { console.error('Android UI 验收未通过：' + error.message); process.exitCode = 1; }
}
