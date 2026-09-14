import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {
  actionRequest,
  helperApkPath,
  JACOCO_ARTIFACTS,
  parseCoverageExec,
  parseResult,
  SELF_TEST_CASES,
  summarizeJacocoXml,
  validateSelfTestResult,
  HELPER,
} from './android-agent-ui.mjs';

const hash = 'a'.repeat(64);
const now = Date.now();
const options = {profile: '/data/user/0/app.gcsa.aegis/aegis-test-user-data-r1', apkSha256: hash, node: '0.2', text: '帮我总结页面内容 🔋'};
const snapshot = () => ({package: 'app.gcsa.aegis', profile: options.profile, apkSha256: hash,
  snapshotSha256: hash, observedAt: new Date(now).toISOString(),
  nodes: [{node: '0.2', visible: true, enabled: true, editable: true, clickable: true, password: false}]});

test('Unicode 输入保持原文，点击不夹带文本参数', () => {
  assert.equal(actionRequest('set-text', options, snapshot(), now).text, options.text);
  assert.equal(actionRequest('click', options, snapshot(), now).text, undefined);
});

test('观察不伪造操作节点或成功结果', () => {
  assert.deepEqual(actionRequest('snapshot', options), {action: 'snapshot', profile: options.profile, apkSha256: hash});
});

for (const [name, patch] of [
  ['错误应用', {package: 'other.app'}], ['错误资料', {profile: 'app_chrome'}],
  ['旧 APK', {apkSha256: 'b'.repeat(64)}], ['没有摘要', {snapshotSha256: ''}],
  ['过期', {observedAt: new Date(now - 60001).toISOString()}],
  ['未来时间', {observedAt: new Date(now + 1000).toISOString()}], ['未知时间', {observedAt: 'unknown'}],
  ['缺少节点', {nodes: []}],
]) test(name + '快照拒绝操作', () => assert.throws(() => actionRequest('click', options, {...snapshot(), ...patch}, now)));

test('密码、隐藏、禁用和不支持动作的节点拒绝操作', () => {
  for (const patch of [{password: true}, {visible: false}, {enabled: false}, {editable: false}]) {
    const state = snapshot(); Object.assign(state.nodes[0], patch);
    assert.throws(() => actionRequest('set-text', options, state, now));
  }
  const state = snapshot(); state.nodes.push({...state.nodes[0]});
  assert.throws(() => actionRequest('click', options, state, now));
  assert.throws(() => actionRequest('set-text', {...options, text: '\0'}, snapshot(), now));
  assert.throws(() => actionRequest('set-text', {...options, text: 'x'.repeat(8193)}, snapshot(), now));
});

test('工具安装路径不能指向其他包或夹带命令', () => {
  const apk = '/data/app/~~test/' + HELPER + '-safe/base.apk';
  assert.equal(helperApkPath('package:' + apk), apk);
  for (const bad of ['package:/data/app/other.app-safe/base.apk', 'package:' + apk + '\npackage:/other',
    'package:' + apk.replace('/base.apk', '/../../base.apk'), 'package:' + apk + ';x']) assert.throws(() => helperApkPath(bad));
});

test('instrumentation 必须明确成功，不能伪称产品或发行通过', () => {
  const good = {ok: true, qualification: 'ui-driver-only', runtimeTested: false, releaseEligible: false};
  const output = value => 'INSTRUMENTATION_RESULT: aegis_result=' + Buffer.from(JSON.stringify(value)).toString('base64') + '\nINSTRUMENTATION_CODE: -1\n';
  assert.deepEqual(parseResult(output(good)), good);
  for (const patch of [{ok: false}, {runtimeTested: true}, {releaseEligible: true}, {qualification: 'release'}]) {
    assert.throws(() => parseResult(output({...good, ...patch})));
  }
  assert.throws(() => parseResult(output(good).replace('CODE: -1', 'CODE: 0')));
  assert.throws(() => parseResult(output(good) + output(good)));
  assert.throws(() => parseResult('INSTRUMENTATION_RESULT: shortMsg=Process crashed.\nINSTRUMENTATION_CODE: 0\n'),
    /"resultKeys":\["shortMsg"\].*"codes":\[0\]/);
});

test('JaCoCo 固定为 Maven Central 0.8.14 的已核验工件', () => {
  assert.equal(JACOCO_ARTIFACTS.version, '0.8.14');
  assert.deepEqual({
    cli: [JACOCO_ARTIFACTS.cli.url, JACOCO_ARTIFACTS.cli.sha1, JACOCO_ARTIFACTS.cli.sha256],
    runtime: [JACOCO_ARTIFACTS.runtime.url, JACOCO_ARTIFACTS.runtime.sha1, JACOCO_ARTIFACTS.runtime.sha256],
  }, {
    cli: ['https://repo.maven.apache.org/maven2/org/jacoco/org.jacoco.cli/0.8.14/org.jacoco.cli-0.8.14-nodeps.jar',
      'e0fb9637fca1384d0da018a9738d776a4b1badc1', '811c7f8c6b358c5d68a8973cfa867f6892be7a671b697a4b13c4b447e6daf75c'],
    runtime: ['https://repo.maven.apache.org/maven2/org/jacoco/org.jacoco.agent/0.8.14/org.jacoco.agent-0.8.14-runtime.jar',
      '4bb9b49d4e6c5b042fc7e6b4f1e3e808f7441dde', '3fb76eea65f81bd9415202bab34b6571728841dff1ab8e6bbe81adc2e299face'],
  });
  assert.equal(fs.readFileSync(new URL('./android-ui-driver/jacoco-agent.properties', import.meta.url), 'utf8'),
    'output=none\ndumponexit=false\n');
});

test('coverage exec 必须来自唯一 instrumentation 结果，normal 结果不得夹带', () => {
  const encoded = Buffer.from([1, 2, 3, 4, 5]).toString('base64');
  const line = 'INSTRUMENTATION_RESULT: aegis_coverage=' + encoded + '\n';
  assert.deepEqual(parseCoverageExec(line, true), Buffer.from([1, 2, 3, 4, 5]));
  assert.equal(parseCoverageExec('', false), null);
  assert.throws(() => parseCoverageExec('', true));
  assert.throws(() => parseCoverageExec(line, false));
  assert.throws(() => parseCoverageExec(line + line, true));
  assert.throws(() => parseCoverageExec('INSTRUMENTATION_RESULT: aegis_coverage=AQ==\n', true));
});

test('工具自测必须逐项返回固定六个 fixture 且不冒充浏览器验收', () => {
  const result = {browserTested: false, selfTestCases: 6,
    selfTestResults: SELF_TEST_CASES.map(id => ({id, passed: true}))};
  assert.doesNotThrow(() => validateSelfTestResult(result));
  assert.throws(() => validateSelfTestResult({...result, browserTested: true}));
  assert.throws(() => validateSelfTestResult({...result, selfTestResults: result.selfTestResults.slice(1)}));
  assert.throws(() => validateSelfTestResult({...result,
    selfTestResults: result.selfTestResults.map((item, index) => index === 2 ? {...item, passed: false} : item)}));
});

test('JaCoCo XML 只用完整 Driver class 集和真实源码行计数生成百分比', () => {
  const classes = ['app/gcsa/aegis/qa/driver/Driver', 'app/gcsa/aegis/qa/driver/Driver$Fixture',
    'app/gcsa/aegis/qa/driver/Driver$GuardFailure'];
  const xml = '<report><package name="app/gcsa/aegis/qa/driver">' +
    classes.map(name => '<class name="' + name + '" sourcefilename="Driver.java"/>').join('') +
    '<sourcefile name="Driver.java"><counter type="LINE" missed="3" covered="5"/></sourcefile></package></report>';
  assert.deepEqual(summarizeJacocoXml(xml, classes),
    {measurement: 'jacoco-line-counter', covered: 5, missed: 3, total: 8, percent: 62.5});
  assert.throws(() => summarizeJacocoXml(xml, classes.slice(1)));
  assert.throws(() => summarizeJacocoXml(xml.replace('covered="5"', 'covered="0"'), classes));
  assert.throws(() => summarizeJacocoXml(xml.replace('<sourcefile name="Driver.java">', '<sourcefile name="Other.java">'), classes));
});
