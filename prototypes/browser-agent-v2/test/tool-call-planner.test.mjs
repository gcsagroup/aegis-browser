import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createToolCallPlanner,
  plannerToolsForState,
  validatePlannerToolCall,
} from '../src/tool-call-planner.mjs';

test('Planner 只接受一个已声明工具与当前观察索引', () => {
  assert.deepEqual(validatePlannerToolCall({
    id: 'call-1', function: { name: 'interact', arguments: '{"actionIndex":0}' },
  }, { actionCount: 1 }), { id: 'call-1', name: 'interact', args: { actionIndex: 0 } });
  assert.throws(() => validatePlannerToolCall({
    id: 'call-2', function: { name: 'interact', arguments: '{"actionIndex":1}' },
  }, { actionCount: 1 }), /不属于当前观察/);
  assert.throws(() => validatePlannerToolCall({
    id: 'call-3', function: { name: 'shell', arguments: '{}' },
  }, { actionCount: 0 }), /未知工具/);
});

test('Planner 使用原生 tool_calls 并拒绝多工具响应', async () => {
  const requests = [];
  const planner = createToolCallPlanner({
    baseUrl: 'http://127.0.0.1:18080',
    model: 'fixture-model',
    fetchImpl: async (_url, options) => {
      requests.push(JSON.parse(options.body));
      return new Response(JSON.stringify({
        choices: [{ message: { tool_calls: [{
          id: 'call-1', function: { name: 'navigate', arguments: '{"url":"https://127.0.0.1:9443/"}' },
        }] } }],
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    },
  });
  assert.deepEqual(await planner.next({
    goal: '打开 fixture',
    state: { currentUrl: 'about:blank', availableActions: [], untrustedPageSnapshot: 'about:blank' },
  }), {
    id: 'call-1', name: 'navigate', args: { url: 'https://127.0.0.1:9443/' }, transport: 'native-tool-call',
  });
  assert.equal(requests[0].tool_choice, 'required');
  assert.equal(planner.calls, 1);
});

test('Planner 只把完整且严格的 JSON 对象归一化为兼容工具调用', async () => {
  const planner = createToolCallPlanner({
    baseUrl: 'http://127.0.0.1:18080',
    model: 'fixture-model',
    fetchImpl: async () => new Response(JSON.stringify({
      choices: [{ message: { content: '{"name":"complete","arguments":{"summary":"done"}}' } }],
    }), { status: 200, headers: { 'content-type': 'application/json' } }),
  });
  assert.equal((await planner.next({ goal: '完成', state: { availableActions: [] } })).transport, 'strict-json-fallback');
});

test('Planner 按当前状态缩窄工具，不在已打开页面继续提供 navigate', () => {
  const blankTools = plannerToolsForState('打开研究页', {
    currentUrl: 'about:blank', availableActions: [], untrustedPageSnapshot: '',
  }).map((tool) => tool.function.name);
  assert.deepEqual(blankTools, ['navigate', 'complete']);
  const pageTools = plannerToolsForState('读取收藏夹后停止', {
    currentUrl: 'https://127.0.0.1/', availableActions: [{ actionIndex: 0 }], untrustedPageSnapshot: '收藏夹',
  }).map((tool) => tool.function.name);
  assert.deepEqual(pageTools, ['interact', 'read_bookmarks', 'complete', 'stop']);
});

test('Planner 在敏感输入页和已完成的 stop 目标上只暴露唯一安全工具', () => {
  const handoffTools = plannerToolsForState('遇到用户名或密码不要输入，立即请求用户接管', {
    currentUrl: 'https://127.0.0.1/login',
    availableActions: [{ actionIndex: 0 }],
    untrustedPageSnapshot: 'textbox: 用户名\ntextbox: 密码',
    completedActions: [],
  }).map((tool) => tool.function.name);
  assert.deepEqual(handoffTools, ['request_handoff']);

  const stopTools = plannerToolsForState('点击一次后立即停止任务', {
    currentUrl: 'https://127.0.0.1/recovery',
    availableActions: [],
    untrustedPageSnapshot: '计数 1',
    completedActions: [{ tool: 'interact', args: { actionIndex: 0 } }],
  }).map((tool) => tool.function.name);
  assert.deepEqual(stopTools, ['stop']);
});

test('Planner 尊重用户对最终交易的否定约束，不把安全拒绝升级为接管', () => {
  const tools = plannerToolsForState('确认购物车为 1；不要点击最终下单，然后完成。', {
    currentUrl: 'https://127.0.0.1/shop',
    availableActions: [],
    untrustedPageSnapshot: 'button: 最终下单\n购物车：测试商品 × 1',
    lastOutcome: '动作被权限代理拒绝：final-transaction-user-takeover',
    completedActions: [{ tool: 'interact', args: { actionIndex: 0 } }],
  }).map((tool) => tool.function.name);
  assert.deepEqual(tools, ['complete']);
});

test('Planner 在 Result Verifier 未通过时不暴露 complete，并避免重复原生只读工具', () => {
  const before = plannerToolsForState('核对收藏夹', {
    currentUrl: 'https://127.0.0.1/bookmarks', availableActions: [],
    untrustedPageSnapshot: '收藏夹', completedActions: [], completionEligible: false,
  }).map((tool) => tool.function.name);
  assert.deepEqual(before, ['read_bookmarks']);
  const after = plannerToolsForState('核对收藏夹', {
    currentUrl: 'https://127.0.0.1/bookmarks', availableActions: [],
    untrustedPageSnapshot: '收藏夹',
    completedActions: [{ tool: 'read_bookmarks', args: {} }], completionEligible: true,
  }).map((tool) => tool.function.name);
  assert.deepEqual(after, ['complete']);
});
