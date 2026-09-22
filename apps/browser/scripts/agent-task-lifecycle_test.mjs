// 直接执行产品状态与按钮函数，验证任务切换及异步失败；DOM桩不代表App验收。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
const repo = fileURLToPath(new URL('../../../', import.meta.url)).replace(/\/$/, '');
const file = process.argv[2] || repo + '/apps/browser/overlay/chrome/browser/resources/aegis_agent/agent.ts';
const ts = createRequire(repo + '/packages/core/package.json')('typescript');
const source = readFileSync(file, 'utf8');
const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
const names = ['render', 'withBusy', 'bindActions', 'humanStatus', 'statusTone',
  'showCreatedTask', 'scheduledTaskStatus', 'hasPartialResult', 'friendlyError', 'inferWorkflow', 'refersToCurrentPage', 'inferAutomationSchedule', 'isDownloadedFileReviewGoal', 'reviewCurrentDownload'];
const selected = tree.statements.filter(n => ts.isFunctionDeclaration(n) && names.includes(n.name?.text));
assert.equal(selected.length, names.length);
const compiled = ts.transpileModule(selected.map(n => n.getText(tree)).join('\n'),
  {compilerOptions: {target: ts.ScriptTarget.ES2022}}).outputText;
const elements = new Map();
const element = id => {
  if (!elements.has(id)) elements.set(id, {value: '总结新页面', dataset: {}, textContent: '',
    events: {}, addEventListener(name, callback) {this.events[name] = callback;}});
  return elements.get(id);
};
let resolveCreate, rejectCreate, resolvePlan;
const context = vm.createContext({element, document: {querySelector: element},
  loadTimeData: {getString: key => key}, busy: false, snapshot: null, selectedWorkflow: null,
  goalUserEdited: true, autoRunTaskId: '', creatingTask: false, creatingTaskPreviousId: '', selectedTaskId: null, taskCreationError: '', AgentMode: {kAct: 1}, Workflow: {kResearch: 1},
  proxy: {handler: {
    createTask: () => new Promise((resolve, reject) => {resolveCreate = resolve; rejectCreate = reject;}),
    requestPlan: () => new Promise(resolve => {resolvePlan = resolve;}),
  }},
});
for (const name of ['renderView','renderModel','renderPlan','renderResult','renderTimeline','renderDownloadEvidence',
  'renderMonitors','renderCheckoutSummary','maybeAutoRun','detectModels','selectDetectedModel',
  'syncDetectedModel','resetDetectedModels','saveModel']) context[name] = () => {};
vm.runInContext(compiled, context);
context.bindActions();
const a = {taskId: 'A', state: 'completed', resultOutcome: 'completed', mode: 'act',
  monitors: [], unfinishedItems: [], lastError: '', modelConfigured: true, agentEnabled: true,
  resultSummary: '旧任务结果'};
const b = {...a, taskId: 'B', state: 'planning', resultOutcome: '', resultSummary: ''};
const observations = [];
const capture = (label, expected) => observations.push({label, expected,
  actual: {taskId: context.snapshot.taskId, status: element('status').textContent,
    error: element('error').textContent},
  passed: expected(context, element)});
// 报告只保留中文预期，不序列化断言函数。
context.render(a);
const pending = element('plan-button').events.click();
capture('新任务创建等待时清除旧完成状态', (c,e) => e('status').textContent === 'statusUnderstanding' && c.snapshot.resultSummary === '' && c.snapshot.timeline.length === 0);
resolveCreate({snapshot: b});
await new Promise(resolve => setImmediate(resolve));
assert.equal(typeof resolvePlan, 'function', '必须已进入真实规划调用');
capture('创建成功后立即显示新任务', c => c.snapshot.taskId === 'B' && c.snapshot.resultSummary === '');
resolvePlan({snapshot: b}); await pending;
context.render(a);
capture('迟到旧任务快照不覆盖新任务', c => c.snapshot.taskId === 'B');
// 对照：已有任务暂停期间仍保留任务，不应由未来修复一律清空。
context.render({...b, state: 'running'});
let finishPause;
const pause = context.withBusy(() => new Promise(resolve => {finishPause = resolve;}));
capture('普通暂停操作保留当前任务', c => c.snapshot.taskId === 'B');
finishPause({snapshot: {...b, state: 'paused_by_user'}}); await pause;
const failed = element('plan-button').events.click();
rejectCreate(new Error('synthetic-create-disconnect'));
let rejected = false;
try {await failed;} catch {rejected = true;}
capture('创建失败显示可读错误', (c,e) => e('error').textContent === 'planningGenericError');
const receipt = {observedAt: new Date().toISOString(), source: file,
  sourceSha256: createHash('sha256').update(source).digest('hex'),
  qualification: '真实产品按钮和渲染函数的DOM回归，非App实机验收',
  createFailurePromiseRejected: rejected,
  cases: observations.map(({expected, ...rest}) => rest)};

console.log(JSON.stringify(receipt,null,2));
assert.equal(receipt.cases.length, 5);
assert(receipt.cases.every(item => item.passed), '新旧任务、创建失败与普通操作回归必须全部通过');
assert.equal(rejected, false, '创建失败不应产生未处理的Promise拒绝');

// 全局监控变化不能被任务隔离丢弃，尤其是最后一条删除后变为空数组。
context.selectedTaskId = null;
context.render({...b, state: 'completed', resultSummary: '当前研究结果'});
let visibleMonitors = [];
context.renderMonitors = monitors => { visibleMonitors = monitors; };
for (const count of [3, 2, 1, 0]) {
  const monitors = Array.from({length: count}, (_, i) => ({
    taskId: `monitor-task-${i}`, monitorId: `monitor-${i}`, paused: true,
  }));
  context.render({...a, taskId: 'monitor-task', monitors});
  assert.equal(visibleMonitors.length, count, '列表更新不能因任务不同被丢弃');
  assert.equal(context.snapshot.monitors.length, count, '忙碌态重绘不能恢复旧列表');
  assert.equal(context.snapshot.taskId, 'B', '仍保持当前研究任务');
  assert.equal(context.snapshot.resultSummary, '当前研究结果', '旧结果不能串入');
}
console.log('PASS: 跨任务监控删除与当前结果隔离 4/4');

for (const button of ['plan-button', 'create-automation-button']) {
  for (const refused of [{...a, lastError: 'Task input is invalid'}, {...a},
      {...a, taskId: '', lastError: 'Task input is invalid'},
      {...b, lastError: 'Task scope could not be created'},
      {...a, modelConfigured: false, lastError: 'Configure a valid Agent model provider before planning'}]) {
    context.selectedTaskId = null;
    context.render(a);
    let planCalls = 0;
    context.proxy.handler.requestPlan = async () => {++planCalls; return {snapshot: b};};
    const pending = element(button).events.click();
    resolveCreate({snapshot: refused});
    await pending;
    assert.equal(context.snapshot.taskId, '');
    assert.equal(element('status').textContent, 'statusFailed');
    assert.equal(element('status').dataset.tone, 'danger');
    assert.equal(context.snapshot.modelConfigured, refused.modelConfigured);
    assert.ok(element('error').textContent);
    assert.equal(planCalls, 0, '拒绝结果不能启动旧任务或错误新任务');
  }
}
console.log('PASS: 普通与自动化原生创建拒绝及配置刷新 10/10');

// 审批展示必须使用实际风险、完整地址和来源，不能回退成工具的静态R1。
context.selectedTaskId = null;
const transferTask = {...b, taskId: 'url-approval', state: 'awaiting_action_approval',
  pendingApproval: {toolName: 'page.navigate', origin: 'https://receiver.example',
    risk: 'R2 · approval required', actionId: 'url-call', actionFingerprint: 'exact-hash',
    argumentSummary: '{"url":"https://receiver.example/path?payload=synthetic"}',
    targetUrl: 'https://receiver.example/path?payload=synthetic#section',
    isDataTransfer: true, dataSourceOrigins: ['https://source.example'],
    requiresUserTakeover: false}};
context.render(transferTask);
assert.equal(element('approval-card').hidden, false);
assert.match(element('approval-detail').textContent, /R2/);
assert.match(element('approval-data-flow').textContent, /https:\/\/source.example/);
assert.equal(element('approval-target-url').textContent, transferTask.pendingApproval.targetUrl);
assert.equal(element('approval-target-url').hidden, false);
context.render({...transferTask, pendingApproval: {...transferTask.pendingApproval,
  toolName: 'page.click', targetUrl: '', targetDescription: '执行操作 <示例>'}});
assert.equal(element('approval-target-url').textContent, '执行操作 <示例>');
assert.equal(element('approval-target-url').hidden, false);
context.render({...transferTask, pendingApproval: {...transferTask.pendingApproval,
  toolName: 'bookmark.apply', isDataTransfer: false, targetUrl: '', dataSourceOrigins: []}});
assert.equal(element('approval-data-flow').hidden, true);
assert.equal(element('approval-data-flow').textContent, '');
assert.equal(element('approval-target-url').textContent, '');
assert.equal(element('approval-target-url').hidden, true);
console.log('PASS: 出站审批显示实际风险、完整地址和来源；本地操作清除旧传输提示');

// 接管或结束后，即使快照残留旧批准也不能继续提供可操作入口。
for (const state of ['user_takeover', 'paused_by_user', 'recovering', 'cancelled', 'failed', 'completed']) {
  context.render({...transferTask, state});
  assert.equal(element('approval-card').hidden, true, `${state} 隐藏旧批准`);
  assert.equal(element('approve-button').disabled, true, `${state} 禁用旧批准`);
  assert.equal(element('approval-id').textContent, '');
}
// 真正的最终接管信息仍可查看，但不能由代理代为批准。
context.render({...transferTask, state: 'user_takeover', pendingApproval: {
  ...transferTask.pendingApproval, requiresUserTakeover: true}});
assert.equal(element('approval-card').hidden, false);
assert.equal(element('approve-button').hidden, true);
assert.equal(element('approve-button').disabled, true);
console.log('PASS: 接管与终态撤销旧批准入口，最终接管信息保留');
