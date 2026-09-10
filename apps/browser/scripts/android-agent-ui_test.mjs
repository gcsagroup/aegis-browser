import test from 'node:test';
import assert from 'node:assert/strict';
import {actionRequest, helperApkPath, parseResult, HELPER} from './android-agent-ui.mjs';

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
  assert.throws(() => parseResult('INSTRUMENTATION_CODE: -1'));
});
