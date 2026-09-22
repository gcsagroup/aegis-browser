import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';

// 使用仓库已有的 TypeScript 编译器，直接测试产品中的纯状态函数。
const requireCore = createRequire(new URL('../../../packages/core/package.json', import.meta.url));
const ts = requireCore('typescript');
const sourcePath = process.argv[2] || fileURLToPath(new URL(
    '../overlay/chrome/browser/resources/aegis_agent/agent.ts', import.meta.url));
const source = readFileSync(sourcePath, 'utf8');
const tree = ts.createSourceFile(sourcePath, source, ts.ScriptTarget.Latest, true);
const names = ['humanRisk', 'scheduledTaskStatus', 'hasPartialResult', 'statusTone', 'humanStatus', 'friendlyError', 'inferAutomationSchedule', 'isDownloadedFileReviewGoal'];
const functions = tree.statements.filter(node =>
  ts.isFunctionDeclaration(node) && names.includes(node.name?.text));
assert.equal(functions.length, names.length, '必须测试真实产品函数，不能跳过缺失函数');
const compiled = ts.transpileModule(functions.map(node => node.getText(tree)).join('\n'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText;
const context = vm.createContext({loadTimeData: {getString: key => key}});
vm.runInContext(compiled, context);
const scheduleCases = [
  ['每小时检查当前网页变化', '60'],
  ['每15分钟检查价格', '15'],
  ['每6小时检查库存', '360'],
  ['每天检查变化', '1440'],
  ['每週檢查目前網頁', '10080'],
  ['Check this page hourly', '60'],
  ['Watch this page every 6 hours', '360'],
  ['每2小时检查变化', ''],
  ['持续监控网页', ''],
  ['检查当前网页', null],
  ['只检查一次，不要每小时检查', null],
  ['不要监控，每天的记录仅总结一次', null],
  ['Do not monitor this page hourly', null],
  ['总结这篇关于每小时产量的文章', null],
];
for (const [goal, interval] of scheduleCases) {
  assert.equal(context.inferAutomationSchedule(goal), interval, goal);
}
console.log(`PASS: 周期意图及否定请求 ${scheduleCases.length}/${scheduleCases.length}`);
const task = overrides => ({
  taskId: 'test-task', mode: 'act', state: 'running', resultSummary: '',
  resultOutcome: '', unfinishedItems: [], monitors: [], ...overrides,
});
const monitor = {taskId: 'test-task', paused: false};
const scheduled = task({mode: 'automate', resultSummary: 'done', monitors: [monitor]});
const cases = [
  ['空闲', task({state: ''}), 'statusIdle'],
  ['规划中', task({state: 'planning'}), 'statusPlanning'],
  ['执行中', task({}), 'statusRunning'],
  ['验证中', task({state: 'verifying'}), 'statusRunning'],
  ['用户暂停', task({state: 'paused_by_user'}), 'statusPaused'],
  ['任务取消', task({state: 'cancelled'}), 'statusCancelled'],
  ['任务到期', task({state: 'expired'}), 'statusExpired'],
  ['任务恢复', task({state: 'recovering'}), 'statusRecovering'],
  ['定时等待', scheduled, 'statusScheduled'],
  ['全部监控暂停', {...scheduled, monitors: [{...monitor, paused: true}]}, 'statusPaused'],
  ['仍有启用监控', {...scheduled, monitors: [monitor, {...monitor, paused: true}]}, 'statusScheduled'],
  ['恢复中任务不能虚报定时就绪', {...scheduled, state: 'recovering', resultSummary: ''}, 'statusRecovering'],
  ['正常收尾的监控仍等待定时', {...scheduled, state: 'completed', resultOutcome: 'monitoring'}, 'statusScheduled'],
  ['重启后已收尾监控不需要旧模型摘要', {...scheduled, state: 'completed', resultSummary: ''}, 'statusScheduled'],
  ['创建后仍在执行计划', {...scheduled, resultSummary: ''}, 'statusRunning'],
  ['其他任务的监控不覆盖本任务', {...scheduled, monitors: [{taskId: 'other', paused: true}]}, 'statusRunning'],
  ['监控不掩盖失败', {...scheduled, state: 'failed'}, 'statusFailed'],
  ['监控不掩盖确认', {...scheduled, state: 'awaiting_action_approval'}, 'statusApproval'],
  ['监控不掩盖接管', {...scheduled, state: 'user_takeover'}, 'statusTakeover'],
  ['监控不掩盖任务暂停', {...scheduled, state: 'paused_by_user'}, 'statusPaused'],
  ['普通任务不显示自动化状态', {...scheduled, mode: 'act'}, 'statusRunning'],
  ['已完整完成', task({state: 'completed', resultOutcome: 'completed'}), 'statusCompleted'],
  ['已结束但结果未到达', task({state: 'completed'}), 'statusEnded'],
  ['明确部分完成', task({state: 'completed', resultOutcome: 'partial'}), 'statusPartial'],
  ['未完成项不能显示全部完成', task({state: 'completed', resultOutcome: 'completed', unfinishedItems: ['来源未读取']}), 'statusPartial'],
  ['部分结果不掩盖失败', task({state: 'failed', resultOutcome: 'partial'}), 'statusFailed'],
  ['部分结果不掩盖待确认', task({state: 'awaiting_action_approval', resultOutcome: 'partial'}), 'statusApproval'],
];
for (const [label, input, expected] of cases) {
  assert.equal(context.humanStatus(input), expected, label);
}
console.log(`PASS: Agent 界面状态 ${cases.length}/${cases.length}`);
const tones = [
  [task({state: 'completed', resultOutcome: 'partial'}), 'warning'],
  [task({state: 'completed', resultOutcome: 'completed'}), 'success'],
  [task({state: 'completed'}), 'neutral'],
  [task({state: 'failed', resultOutcome: 'partial'}), 'danger'],
  [task({state: 'awaiting_action_approval'}), 'warning'],
  [task({state: 'planning'}), 'neutral'],
];
for (const [input, expected] of tones) {
  assert.equal(context.statusTone(input), expected);
}
console.log(`PASS: Agent 状态颜色 ${tones.length}/${tones.length}`);
assert.equal(context.friendlyError('execution stopped because browser context changed', true),
    'pageContextUnavailableError', '页面尚未就绪不能被误报为模型连接失败');
assert.equal(context.friendlyError('', true), '', '成功后不应保留错误横幅');
console.log('PASS: Agent 页面上下文错误提示 2/2');

// 直接运行产品渲染函数；模拟 DOM 只检查文本赋值与状态，不冒充浏览器界面验收。
const monitorRenderer = tree.statements.find(node =>
  ts.isFunctionDeclaration(node) && node.name?.text === 'renderMonitors');
assert(monitorRenderer, '监控渲染函数不能缺失');
class TestElement {
  constructor(tag) { this.tag = tag; this.children = []; this.dataset = {}; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  addEventListener() {}
  set innerHTML(_) { assert.fail('模型摘要不能通过 HTML 解析'); }
}
const elements = new Map();
const element = name => {
  if (!elements.has(name)) elements.set(name, new TestElement(name));
  return elements.get(name);
};
const rendererContext = vm.createContext({
  document: {createElement: tag => new TestElement(tag)}, element, busy: false,
  loadTimeData: {getString: key => key}, withBusy: () => {}, proxy: {handler: {}},
});
vm.runInContext(ts.transpileModule(monitorRenderer.getText(tree), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText, rendererContext);
const monitorInput = {taskId: 'test-task', monitorId: 'test-monitor', kind: 'page_change',
  paused: false, interval: '15 min', origin: 'https://fixture.example', sessionOnly: false,
  nextRun: String(Date.now()), failures: 0, lastCheckStatus: 1, lastHttpStatus: 200,
  changeSummary: ''};
for (const [label, overrides, expectedStatus, hidden] of [
  ['正常变化摘要', {changeSummary: '续航由18小时提高到24小时。'}, 1, false],
  ['摘要失败不是网页或模型连接失败', {lastCheckStatus: 14, failures: 1}, 14, true],
  ['无摘要不显示空标题', {}, 1, true],
  ['未知状态保留失败提示', {lastCheckStatus: 999}, 11, true],
  ['模型 HTML 只能作为普通文本显示', {changeSummary: '<img src=x onerror=alert(1)>'}, 1, false],
  ['片段摘要明确显示范围限制', {changeSummary: '观察到部分变化', changeSummaryPartial: true}, 1, false],
]) {
  rendererContext.renderMonitors([{...monitorInput, ...overrides}]);
  const row = element('monitors').children[0];
  const summary = row.children.find(child => child.className === 'monitor-change-summary');
  const outcome = row.children.find(child => child.className === 'monitor-outcome');
  assert.equal(summary.hidden, hidden, label);
  assert(outcome.textContent.startsWith('automationCheckStatus' + expectedStatus), label);
  assert.equal(summary.children.length, 0, label);
  if (!hidden) assert(summary.textContent.includes(overrides.changeSummary), label);
  if (overrides.changeSummaryPartial) assert(summary.textContent.includes('automationChangeSummaryPartial'), label);
}
console.log('PASS: 监控变化摘要渲染 6/6（DOM 单元测试，非实机验收）');
for (const paused of [false, true]) {
  for (const busy of [false, true]) {
    rendererContext.busy = busy;
    rendererContext.renderMonitors([{...monitorInput, paused}]);
    const row = element('monitors').children[0];
    const actions = row.children.find(child => child.className === 'monitor-actions');
    const check = actions.children.find(child => child.dataset.monitorAction === 'check');
    assert(check, '每条监控都能看到立即检查入口');
    assert.equal(check.disabled, paused || busy, '暂停或请求处理中不得再次检查');
    assert.equal(check.textContent, 'checkMonitorNow');
  }
}
rendererContext.busy = false;
assert.equal(context.friendlyError('monitor immediate check unavailable', true),
    'checkMonitorNowUnavailable');
console.log('PASS: 立即检查入口及暂停/忙碌/失败状态 5/5');


// 模型配置使用真实产品函数和有界异步响应；不把 DOM 测试等同于键盘或实机操作。
const modelFunctions = tree.statements.filter(node => ts.isFunctionDeclaration(node) &&
  ['renderModel', 'saveModel', 'friendlyModelError', 'showModelSaveError'].includes(node.name?.text));
for (const name of ['renderModel', 'saveModel', 'friendlyModelError']) {
  assert(modelFunctions.some(node => node.name.text === name), `模型表单函数缺失：${name}`);
}
const modelCode = ts.transpileModule(modelFunctions.map(node => node.getText(tree)).join('\n'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText;
const savedModel = {
  modelConfigured: true, modelProvider: 'openai',
  modelBaseUrl: 'http://127.0.0.1:8000/v1', modelName: 'previous-model', lastError: '',
};
const requestedModel = 'Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit';
function modelHarness(initial = savedModel) {
  const fields = new Map();
  const field = name => {
    if (!fields.has(name)) fields.set(name, {value: '', textContent: '', disabled: false, open: true});
    return fields.get(name);
  };
  const calls = [];
  let response = {snapshot: {...savedModel, modelName: requestedModel}};
  const sandbox = vm.createContext({
    element: field, modelBusy: false, modelFormInitialized: false, snapshot: initial,
    loadTimeData: {getString: key => key},
    proxy: {handler: {configureModel: async (...args) => {
      calls.push(args);
      if (response instanceof Error) throw response;
      return typeof response === 'function' ? response() : response;
    }}},
  });
  sandbox.render = next => {
    sandbox.snapshot = next;
    sandbox.renderModel(next);
  };
  vm.runInContext(modelCode, sandbox);
  sandbox.render(initial);
  field('model-name').value = requestedModel;
  field('model-api-key').value = 'synthetic-test-value';
  return {field, calls, sandbox, setResponse: value => { response = value; }};
}
const modelCases = [
  ['输入中的完整模型名不被普通快照刷新覆盖', async () => {
    const h = modelHarness();
    h.field('model-base-url').value = 'http://127.0.0.1:9000/v1';
    for (let i = 0; i < 12; ++i) h.sandbox.render({...savedModel, modelName: 'snapshot-model'});
    assert.equal(h.field('model-name').value, requestedModel);
    assert.equal(h.field('model-base-url').value, 'http://127.0.0.1:9000/v1');
  }],
  ['保存成功更新已保存值并清除密码输入', async () => {
    const h = modelHarness();
    await h.sandbox.saveModel();
    assert.equal(h.calls.length, 1);
    assert.equal(h.calls[0][2], requestedModel);
    assert.equal(h.field('model-feedback').textContent, 'modelSaved');
    assert.equal(h.field('model-name').value, requestedModel);
    assert.equal(h.field('model-details').open, false);
    assert.equal(h.field('model-api-key').value, '');
    assert.equal(h.sandbox.modelBusy, false);
  }],
  ['已有连接不能掩盖新配置保存失败', async () => {
    const h = modelHarness();
    h.field('model-base-url').value = 'file:///invalid';
    h.setResponse({snapshot: {...savedModel, lastError: 'invalid model provider base URL'}});
    await h.sandbox.saveModel();
    assert.equal(h.field('model-feedback').textContent, 'modelConfigurationError');
    assert.equal(h.field('model-details').open, true);
    assert.equal(h.field('model-name').value, requestedModel);
    assert.equal(h.field('model-base-url').value, 'file:///invalid');
    assert(h.field('model-state').textContent.endsWith('previous-model'));
    assert.equal(h.field('model-api-key').value, '');
  }],
  ['首次失败也保留非敏感输入供修正', async () => {
    const initial = {...savedModel, modelConfigured: false};
    const h = modelHarness(initial);
    h.setResponse({snapshot: {...initial, lastError: 'invalid model name'}});
    await h.sandbox.saveModel();
    assert.equal(h.field('model-name').value, requestedModel);
    assert.equal(h.field('model-feedback').textContent, 'modelConfigurationError');
    assert.equal(h.field('model-details').open, true);
  }],
  ['安全存储失败不被说成连接成功或网络错误', async () => {
    const h = modelHarness();
    h.setResponse({snapshot: {...savedModel, lastError: 'secure credential storage unavailable'}});
    await h.sandbox.saveModel();
    assert.equal(h.field('model-feedback').textContent, 'modelStorageError');
    assert.equal(h.field('model-details').open, true);
    assert.equal(h.field('model-api-key').value, '');
  }],
  ['响应中断后仍可重试且不显示原始错误或密钥', async () => {
    const h = modelHarness();
    h.setResponse(new Error('synthetic-private-error'));
    await h.sandbox.saveModel();
    assert.equal(h.field('model-feedback').textContent, 'modelSaveError');
    assert.equal(h.field('model-details').open, true);
    assert.equal(h.field('model-name').value, requestedModel);
    assert.equal(h.field('model-api-key').value, '');
    assert.equal(h.field('save-model-button').disabled, false);
    assert.equal(h.sandbox.modelBusy, false);
  }],
  ['保存进行中只发送一次并禁用输入', async () => {
    const h = modelHarness();
    let finish;
    h.setResponse(() => new Promise(resolve => { finish = resolve; }));
    const pending = h.sandbox.saveModel();
    assert.equal(h.field('model-name').disabled, true);
    assert.equal(h.field('save-model-button').disabled, true);
    await h.sandbox.saveModel();
    assert.equal(h.calls.length, 1);
    finish({snapshot: {...savedModel, modelName: requestedModel}});
    await pending;
    assert.equal(h.field('save-model-button').disabled, false);
  }],
  ['修正失败输入后可再次成功保存', async () => {
    const h = modelHarness();
    h.setResponse({snapshot: {...savedModel, lastError: 'invalid model name'}});
    await h.sandbox.saveModel();
    h.field('model-name').value = requestedModel;
    h.setResponse({snapshot: {...savedModel, modelName: requestedModel}});
    await h.sandbox.saveModel();
    assert.equal(h.calls.length, 2);
    assert.equal(h.field('model-feedback').textContent, 'modelSaved');
    assert.equal(h.field('model-details').open, false);
  }],
];
const modelFailures = [];
for (const [label, run] of modelCases) {
  try { await run(); }
  catch (error) { modelFailures.push(label); console.error(`FAIL: ${label}: ${error.message}`); }
}
assert.equal(modelFailures.length, 0, '模型表单状态回归未全部通过');
console.log(`PASS: 模型表单状态 ${modelCases.length}/${modelCases.length}（DOM 单元测试，非实机验收）`);

// 执行真实按钮绑定，禁止语句不应替自动化选择一次性的高风险工作流。
const actionFunctions = tree.statements.filter(node => ts.isFunctionDeclaration(node) &&
  ['inferWorkflow', 'inferAutomationSchedule', 'bindActions', 'showCreatedTask', 'reviewCurrentDownload', 'isDownloadedFileReviewGoal'].includes(node.name?.text));
assert.equal(actionFunctions.length, 6);
const actionCode = ts.transpileModule(actionFunctions.map(node => node.getText(tree)).join('\n'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText;
const actionFields = new Map();
const actionField = id => {
  if (!actionFields.has(id)) actionFields.set(id, {
    value: '', listeners: new Map(), focus() { this.focused = true; },
    addEventListener(event, listener) { this.listeners.set(event, listener); },
  });
  return actionFields.get(id);
};
const actionCalls = [];
const actionContext = vm.createContext({
  loadTimeData: {getString: key => key}, busy: false,
  element: actionField, withBusy: callback => callback(), snapshot: null, activeView: 'task',
  creatingTask: false, creatingTaskPreviousId: '', selectedTaskId: null, render: () => {},
  Workflow: {kResearch: 0, kBrowserSteward: 1, kSafeDownload: 2, kShopping: 3},
  AgentMode: {kAct: 1, kAutomate: 2}, selectedWorkflow: null,
  detectModels: () => {}, saveModel: () => {},
  selectDetectedModel: () => {}, syncDetectedModel: () => {}, resetDetectedModels: () => {},
  proxy: {handler: {createTask: async (...args) => {
    actionCalls.push(args); return {snapshot: {taskId: `task-${actionCalls.length}`, lastError: ''}};
  }, requestPlan: async taskId => ({snapshot: {taskId}})}},
});
vm.runInContext(actionCode, actionContext);
actionContext.bindActions();
actionField('automation-schedule').value = '15';
const automationGoals = [
  '每15分钟检查 http://127.0.0.1:52861/article 网页内容，只在有重要更新时总结变化并提醒。只读取本地公开页面，不搜索、登录、填写表单、下载或执行其他操作。',
  '监控当前页面价格，不购买、不付款，不加入购物车。',
  '监控网页变化，不修改书签、不读取历史记录。',
  '監控這個網頁的更新，不下載、不購買、不改書籤。',
  'Monitor this page; do not download, purchase, or change bookmarks.',
  '提醒我官方下载版本是否更新，仅监控版本信息。',
];
const actionFailures = [];
for (const goal of automationGoals) {
  actionField('automation-goal').value = goal;
  await actionField('create-automation-button').listeners.get('click')();
  const args = actionCalls.at(-1);
  assert.equal(args[0], goal, '完整目标和禁止条款必须原样交给原生端');
  assert.equal(args[1], 2);
  assert.equal(args[4], 15);
  if (args[2] !== 0) actionFailures.push(goal);
}
for (const [goal, workflow] of [['下载官方安装包', 2], ['购买商品', 3], ['整理收藏夹', 1]]) {
  actionField('goal').value = goal;
  await actionField('plan-button').listeners.get('click')();
  assert.equal(actionCalls.at(-1)[1], 1);
  assert.equal(actionCalls.at(-1)[2], workflow, '普通任务工作流不能被自动化修正改变');
}
assert.equal(actionFailures.length, 0, `自动化错误选择工作流：${actionFailures.join(' | ')}`);
console.log('PASS: 自动化入口及普通任务对照 9/9（真实按钮绑定单元测试，非实机验收）');
for (const [goal, interval] of [['每小时检查网页变化', '60'], ['每2小时检查网页变化', '']]) {
  const before = actionCalls.length;
  actionField('goal').value = goal;
  await actionField('plan-button').listeners.get('click')();
  assert.equal(actionCalls.length, before, '引导不能直接创建任务');
  assert.equal(actionField('automation-goal').value, goal);
  assert.equal(actionField('automation-schedule').value, interval);
  assert.equal(actionContext.activeView, 'automation');
}
console.log('PASS: 普通输入只预填监控确认面板 2/2');


const timelineRenderer = tree.statements.find(node =>
  ts.isFunctionDeclaration(node) && node.name?.text === 'renderTimeline');
assert(timelineRenderer);
vm.runInContext(compiled, rendererContext);
vm.runInContext(ts.transpileModule(timelineRenderer.getText(tree), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText, rendererContext);
const timelineEvent = {title: 'completed', detail: 'browser verification passed', timestamp: String(Date.now())};
const timelineCases = [
  ['普通任务完整完成', task({state: 'completed', resultOutcome: 'completed'}), 'timelineCompleted', 'timelineCompletedDetail'],
  ['尚无结果不能伪报成功', task({state: 'completed'}), 'statusEnded', 'timelineEndedDetail'],
  ['监控创建完成不是尚无结果', {...scheduled, state: 'completed', resultOutcome: 'monitoring'}, 'timelineMonitorReady', 'timelineMonitorReadyDetail'],
  ['重启后的已完成监控保持准确说明', {...scheduled, state: 'completed', resultSummary: ''}, 'timelineMonitorReady', 'timelineMonitorReadyDetail'],
  ['暂停监控不改写已完成的创建记录', {...scheduled, state: 'completed', monitors: [{...monitor, paused: true}]}, 'timelineMonitorReady', 'timelineMonitorReadyDetail'],
  ['仍有未完成事项时明确部分完成', {...scheduled, state: 'completed', resultOutcome: 'partial', unfinishedItems: ['另一个来源尚未检查']}, 'statusPartial', 'timelinePartialDetail'],
];
const timelineFailures = [];
for (const [label, input, title, detail] of timelineCases) {
  rendererContext.renderTimeline({...input, timeline: [timelineEvent]});
  const row = element('timeline').children[0];
  if (row.textContent !== title || !row.children[0].textContent.startsWith(detail)) timelineFailures.push(label);
}
assert.equal(timelineFailures.length, 0, `时间线误报：${timelineFailures.join(' | ')}`);
console.log('PASS: 监控收尾与部分完成时间线 6/6（DOM 单元测试，非实机验收）');

// 重启后的监控没有活动计划和内存时间线，不能因此显示仍在规划或暂无任务。
const planRenderer = tree.statements.find(node =>
  ts.isFunctionDeclaration(node) && node.name?.text === 'renderPlan');
assert(planRenderer);
vm.runInContext(ts.transpileModule(planRenderer.getText(tree), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText, rendererContext);
const planDetails = new TestElement('details');
element('plan-card').querySelector = selector => {
  assert.equal(selector, '.task-details');
  return planDetails;
};
const restoredUiFailures = [];
for (const [label, hasTask, state, hidden, summary] of [
  ['无任务不显示计划', false, '', true, ''],
  ['仅真正规划中显示规划提示', true, 'planning', false, 'statusPlanning'],
  ['规划失败保留失败说明', true, 'failed', false, 'planFailed'],
  ['已完成监控不伪报规划', true, 'completed', true, ''],
  ['恢复状态不伪报规划', true, 'recovering', true, ''],
  ['取消任务不伪报规划', true, 'cancelled', true, ''],
  ['用户暂停不伪报规划', true, 'paused_by_user', true, ''],
]) {
  rendererContext.renderPlan(null, hasTask, state);
  if (element('plan-card').hidden !== hidden ||
      element('plan-summary').textContent !== summary) {
    restoredUiFailures.push(label);
  }
  assert.equal(element('risk-badge').hidden, true, label);
  assert.equal(planDetails.hidden, true, label);
  assert.equal(element('scope-grid').children.length, 0, label);
  assert.equal(element('plan-steps').children.length, 0, label);
}
for (const [label, input, expected] of [
  ['重启后监控等待不能显示暂无任务',
    {...scheduled, state: 'completed'}, 'automationScheduledHelp'],
  ['重启后暂停不能显示暂无任务',
    {...scheduled, state: 'completed', monitors: [{...monitor, paused: true}]},
    'automationPausedHelp'],
  ['真正空闲时仍显示暂无任务', task({taskId: '', state: ''}), 'noTask'],
]) {
  element('empty-task').textContent = '未更新';
  rendererContext.renderTimeline({...input, timeline: []});
  if (element('empty-task').hidden !== false ||
      element('empty-task').textContent !== expected) {
    restoredUiFailures.push(label);
  }
}
assert.equal(restoredUiFailures.length, 0,
    `恢复后的界面状态错误：${restoredUiFailures.join(' | ')}`);
console.log('PASS: 无计划及空时间线状态 10/10（DOM 单元测试，非实机验收）');

// 来源标题取浏览器字段，模型正文和控件文本不能覆盖引用标题。
const resultFunctions = ['renderResult', 'hasPartialResult', 'scheduledTaskStatus'];
vm.runInContext(ts.transpileModule(tree.statements.filter(node =>
  ts.isFunctionDeclaration(node) && resultFunctions.includes(node.name?.text))
  .map(node => node.getText(tree)).join('\n'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText, rendererContext);
const sourceResult = task({state: 'completed', resultOutcome: 'completed',
  resultSummary: '模型正文中的上传入口', resultSources: ['https://fixture.example/article'],
  resultSourceTitles: ['浏览器页面标题'], researchSaveAvailable: false});
rendererContext.renderResult(sourceResult);
assert.equal(element('result-sources').children[0].children[0].textContent,
  '浏览器页面标题 · https://fixture.example/article');
assert.equal(element('result-summary').textContent, sourceResult.resultSummary);
rendererContext.renderResult({...sourceResult, resultSourceTitles: []});
assert.equal(element('result-sources').children[0].children[0].textContent,
  'https://fixture.example/article');
console.log('PASS: 浏览器来源标题与模型正文隔离 3/3');

const downloadReviewGoals = [
  ['核对刚下载的文件是否已经安装。', true],
  ['检查这次下载文件的哈希是否变更', true],
  ['核對剛下載的檔案是否已安裝', true],
  ['Check whether the downloaded file has been installed.', true],
  ['Has this download been installed?', true],
  ['核对刚下载的文件，然后安装', false],
  ['下载并安装这个文件', false],
  ['不要核对刚下载的文件是否安装', false],
  ['核对刚下载的文件是否安装，不要执行', true],
  ['核對剛下載的檔案是否安裝，不要安裝', true],
  ['Check whether the downloaded file has been installed; do not install it.', true],
  ['Do not check whether the downloaded file is installed.', false],
  ['Check this download and install it', false],
  ['Check whether the page offers an installer', false],
  ['核对当前官方发布页', false],
];
for (const [goal, expected] of downloadReviewGoals) {
  assert.equal(context.isDownloadedFileReviewGoal(goal), expected, goal);
}
console.log(`PASS: 下载回读问答与操作命令分离 ${downloadReviewGoals.length}/${downloadReviewGoals.length}`);
for (const [value, key] of Object.entries({
  'browser verified all actions; model summary fallback used': 'timelineVerifiedFallback',
  reflecting: 'timelineVerifying', awaiting_action_approval: 'statusApproval',
  'exact action approval required': 'timelineActionApprovalRequired',
  'exact action approval consumed': 'timelineActionApprovalConsumed',
  'cancelled by user': 'timelineCancelledByUser',
  'execution model failed twice': 'timelineExecutionModelFailed',
})) {
  rendererContext.renderTimeline({...task({}), timeline: [{...timelineEvent, title: value, detail: value}]});
  const row = element('timeline').children[0];
  assert.equal(row.textContent, key);
  assert(row.children[0].textContent.startsWith(key));
}
console.log('PASS: 新增时间线状态与详情本地化 7/7');

const createCountBeforeReview = actionCalls.length;
actionContext.snapshot = null;
actionField('goal').value = '核对刚下载的文件是否已经安装。';
await actionField('plan-button').listeners.get('click')();
assert.equal(actionCalls.length, createCountBeforeReview);
assert.equal(actionField('download-review-status').textContent, 'downloadReviewUnassociated');
assert.equal(actionField('download-evidence-card').open, true);
let reviewedId = '';
actionContext.snapshot = {taskId: 'download-task', state: 'completed', downloadEvidence: [{name: 'download_id', value: 'native-guid'}]};
actionContext.proxy.handler.reviewDownload = async id => { reviewedId = id; return {status: 'match', sha256: 'fixture-hash'}; };
await actionField('plan-button').listeners.get('click')();
assert.equal(reviewedId, 'download-task');
assert.equal(actionCalls.length, createCountBeforeReview);
assert.equal(actionField('download-review-status').textContent, 'downloadReviewMatch\nSHA-256: fixture-hash');
console.log('PASS: 安装问答复用当前任务回执且不创建下载任务 2/2');

// 不变快照保留节点，状态刷新不会把整段历史再次送入旁白。
const stableTimeline = {...task({}), timeline: [timelineEvent]};
rendererContext.renderTimeline(stableTimeline);
const originalRow = element('timeline').children[0];
rendererContext.renderTimeline(stableTimeline);
assert.equal(element('timeline').children[0], originalRow);
rendererContext.renderTimeline({...stableTimeline, timeline: [timelineEvent, {...timelineEvent, title: 'paused by user'}]});
assert.equal(element('timeline').children.length, 2);
assert.equal(element('timeline').children[1].textContent, 'timelineDetail21');
for (const [risk, label] of [['R0 · read only', 'riskLevel0'], ['R1 · reversible', 'riskLevel1'], ['R2 · approval required', 'riskLevel2'], ['R3 · user takeover', 'riskLevel3'], ['R9 unknown', 'R9 unknown']]) {
  assert.equal(context.humanRisk(risk), label);
}
const agentHtml = readFileSync(new URL('../overlay/chrome/browser/resources/aegis_agent/agent.html', import.meta.url), 'utf8');
assert(!/<ol[^>]*id="timeline"[^>]*aria-live/.test(agentHtml));
assert(/id="status"[^>]*role="status"[^>]*aria-atomic="true"/.test(agentHtml));
console.log('PASS: 风险文字、稳定时间线与单一任务状态播报');

assert.equal(context.friendlyError('browser goal needs an explicit target', false),
    'browserGoalClarification');
console.log('PASS: 含糊浏览器目标显示可操作的澄清提示');
