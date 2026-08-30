import assert from 'node:assert/strict';
import test from 'node:test';
import { M5RuntimeBroker, observationToken } from '../src/m5-runtime-broker.mjs';

const actions = [{ selector: 'xpath=/button[1]', description: '刷新结果', method: 'click' }];
const binding = (overrides = {}) => ({
  profileId: 'isolated-profile',
  taskId: 'task-1',
  tabId: 'tab-1',
  frameToken: 'main-frame',
  documentToken: 'document-1',
  observationToken: observationToken(actions),
  url: 'https://127.0.0.1:9443/dynamic',
  ...overrides,
});

function runtime() {
  const value = new M5RuntimeBroker({
    profileId: 'isolated-profile',
    taskId: 'task-1',
    allowedOrigins: ['https://127.0.0.1:9443'],
  });
  assert.equal(value.adoptOwnedTab('tab-1'), true);
  assert.equal(value.commitDocument(binding()), true);
  return value;
}

test('Broker 允许精确当前观察动作并拒绝重放和旧文档', () => {
  const value = runtime();
  assert.deepEqual(value.authorize({
    actionId: 'action-1', tool: 'interact', binding: binding(), actionIndex: 0, observedActions: actions,
  }), { allowed: true, reason: 'allow' });
  assert.equal(value.authorize({
    actionId: 'action-1', tool: 'interact', binding: binding(), actionIndex: 0, observedActions: actions,
  }).reason, 'duplicate-action');
  assert.equal(value.authorize({
    actionId: 'action-2', tool: 'interact', binding: binding({ documentToken: 'stale' }), actionIndex: 0, observedActions: actions,
  }).reason, 'stale-document');
});

test('Broker 拒绝当前文档的同 URL 空导航', () => {
  const value = runtime();
  assert.equal(value.authorize({
    actionId: 'same-url', tool: 'navigate', binding: binding(), destination: binding().url,
  }).reason, 'no-op-navigation');
});

test('Broker 只在 Result Verifier 已通过时允许 complete', () => {
  const value = runtime();
  assert.equal(value.authorize({
    actionId: 'complete-early', tool: 'complete', binding: binding(), completionVerified: false,
  }).reason, 'completion-not-verified');
  assert.deepEqual(value.authorize({
    actionId: 'complete-ready', tool: 'complete', binding: binding(), completionVerified: true,
  }), { allowed: true, reason: 'allow' });
});

test('Broker 拒绝跨域导航、最终交易、重定向和观察索引漂移', () => {
  const value = runtime();
  assert.equal(value.authorize({
    actionId: 'nav', tool: 'navigate', binding: binding(), destination: 'https://outside.test/',
  }).reason, 'invalid-destination');
  assert.equal(value.authorize({
    actionId: 'buy', tool: 'interact', binding: binding(), actionIndex: 0,
    observedActions: [{ ...actions[0], description: '最终下单' }],
  }).reason, 'invalid-observed-action');
  const buyActions = [{ ...actions[0], description: '最终下单' }];
  const buyBinding = binding({ observationToken: observationToken(buyActions) });
  assert.equal(value.commitDocument(buyBinding), true);
  assert.equal(value.authorize({
    actionId: 'buy-2', tool: 'interact', binding: buyBinding, actionIndex: 0, observedActions: buyActions,
  }).reason, 'final-transaction-user-takeover');
  const redirectActions = [{ ...actions[0], description: '尝试外部重定向' }];
  const redirectBinding = binding({ observationToken: observationToken(redirectActions) });
  assert.equal(value.commitDocument(redirectBinding), true);
  assert.equal(value.authorize({
    actionId: 'redirect', tool: 'interact', binding: redirectBinding, actionIndex: 0, observedActions: redirectActions,
  }).reason, 'redirect-requires-preflight');
});

test('Broker 在点击前解析嵌套重定向并拒绝下载动作', () => {
  const value = runtime();
  const redirectActions = [{
    ...actions[0],
    description: '链接',
    targetUrl: 'https://127.0.0.1:9443/redirect-out?to=https%3A%2F%2Foutside.test%2F',
  }];
  const redirectBinding = binding({ observationToken: observationToken(redirectActions) });
  assert.equal(value.commitDocument(redirectBinding), true);
  assert.equal(value.authorize({
    actionId: 'nested', tool: 'interact', binding: redirectBinding, actionIndex: 0, observedActions: redirectActions,
  }).reason, 'redirect-target-denied');
  const downloadActions = [{ ...actions[0], description: '下载文本样本' }];
  const downloadBinding = binding({ observationToken: observationToken(downloadActions) });
  assert.equal(value.commitDocument(downloadBinding), true);
  assert.equal(value.authorize({
    actionId: 'download', tool: 'interact', binding: downloadBinding, actionIndex: 0, observedActions: downloadActions,
  }).reason, 'download-requires-dedicated-tool');
});

test('Broker 要求接管按钮只能通过专用工具处理', () => {
  const value = runtime();
  const handoffActions = [{ ...actions[0], description: '需要用户接管' }];
  const handoffBinding = binding({ observationToken: observationToken(handoffActions) });
  assert.equal(value.commitDocument(handoffBinding), true);
  assert.equal(value.authorize({
    actionId: 'handoff-click', tool: 'interact', binding: handoffBinding,
    actionIndex: 0, observedActions: handoffActions,
  }).reason, 'handoff-requires-dedicated-tool');
});

test('Stop 撤销 owned tabs 并拒绝后续动作', () => {
  const value = runtime();
  assert.deepEqual(value.stop(), ['tab-1']);
  assert.equal(value.authorize({ actionId: 'after-stop', tool: 'complete', binding: binding() }).reason, 'stopped');
  assert.equal(value.adoptOwnedTab('tab-2'), false);
});
