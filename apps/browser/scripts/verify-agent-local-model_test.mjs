import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {test} from 'node:test';
import {parseArguments, modelCall, routeCases, planCases} from './verify-agent-local-model.mjs';

const base = ['--base-url', 'http://127.0.0.1:8000/v1', '--model', 'test-model'];

test('默认保持原有模型请求时限', () => {
  assert.equal(parseArguments(base).transportGraceMs, 0);
});

test('远程验收传输余量显式且有界', () => {
  assert.equal(parseArguments([...base, '--transport-grace-ms', '30000']).transportGraceMs, 30000);
  for (const value of ['-1', '60001', 'NaN', '1.5', undefined]) {
    assert.throws(() => parseArguments([...base, '--transport-grace-ms', value]));
  }
});

test('传输余量不放宽模型端点或凭据边界', () => {
  for (const endpoint of ['http://example.com/v1', 'http://user:secret@127.0.0.1/v1',
    'http://127.0.0.1/v1?key=secret']) {
    assert.throws(() => parseArguments(['--base-url', endpoint, '--model', 'test-model',
      '--transport-grace-ms', '30000']));
  }
});

for (const [id, domain] of [
  ['named-site', 'jd.com'],
  ['named-site-cnbeta-regression', 'cnbeta.com.tw'],
  ['official-download', 'videolan.org'],
]) test('点名站点预检拒绝相似后缀、明文地址和凭据：' + id, () => {
  const check = routeCases().find(item => item.id === id);
  const route = {schema_version: 1, workflow: check.workflow,
    entry_kind: 'open_url', target: 'https://' + domain, summary: '合成路由'};
  assert.equal(check.validate(route), true);
  assert.equal(check.validate({...route, target: 'https://www.' + domain + '/path'}), true);
  for (const target of ['https://not' + domain, 'http://' + domain,
    'https://user:synthetic@' + domain, 'https://' + domain + ':8443',
    'https://' + domain + '.example.test', '无效地址']) {
    assert.equal(check.validate({...route, target}), false, target);
  }
});

test('浏览器内部任务的路由目标必须为空', () => {
  for (const check of routeCases().filter(item => ['current-page', 'bookmarks'].includes(item.id))) {
    const route = {workflow: check.workflow, entry_kind: 'browser_only', target: ''};
    assert.equal(check.validate(route), true);
    assert.equal(check.validate({...route, target: 'https://example.test'}), false);
  }
});

test('计划预检不能忽略范围外工具', () => {
  const plans = planCases();
  const monitor = plans.find(item => item.id === 'daily-page-monitor');
  assert.equal(monitor.validate(['page.observe', 'monitor.create']), true);
  assert.equal(monitor.validate(['page.observe', 'bookmark.apply', 'monitor.create']), false);
  const bookmark = plans.find(item => item.id === 'bookmark-preview');
  const tools = ['bookmark.list', 'bookmark.check_urls', 'bookmark.plan'];
  assert.equal(bookmark.validate(tools), true);
  assert.equal(bookmark.validate([...tools, 'page.navigate']), false);
});

test('书签预览缺步的修复错误与当前原生验证器一致', () => {
  const check = planCases().find(item => item.id === 'bookmark-preview');
  const error = check.repairError(['bookmark.list', 'bookmark.check_urls']);
  assert.equal(error, 'bookmark organization goal omitted required bookmark.plan step');
  const native = fs.readFileSync(new URL('../overlay/chrome/browser/aegis/agent/agent_planner.cc', import.meta.url), 'utf8');
  assert(native.includes(JSON.stringify(error)));
  assert.equal(check.repairError(['bookmark.list']), null);
});

test('否定约束监控保留完整限制且只允许观察和注册', () => {
  const check = planCases().find(item => item.id === 'negative-constraints-page-monitor');
  assert(check.input.user_goal.includes('不要下载、整理书签、提交或购买；仅允许读取这个本地公开测试来源并创建上述监控。'));
  assert(check.input.user_goal.includes('interval_minutes=15'));
  assert.deepEqual(check.input.maximum_tools, ['page.observe', 'monitor.create']);
  assert.equal(check.validate(['page.observe', 'monitor.create']), true);
  assert.equal(check.validate(['page.observe', 'bookmark.list', 'monitor.create']), false);
});

const sampleSchema = {
  type: 'object', additionalProperties: false,
  required: ['tab_id', 'kind', 'fields'],
  properties: {
    tab_id: {type: 'integer', minimum: 1, maximum: 10},
    kind: {type: 'string', enum: ['article'], maxLength: 10},
    fields: {type: 'array', minItems: 1, maxItems: 2,
      items: {type: 'string', maxLength: 4}},
  },
};
const validArgs = () => ({tab_id: 7, kind: 'article', fields: ['标题']});

async function syntheticCall(t, args) {
  t.mock.method(globalThis, 'fetch', async (_url, request) => {
    const body = JSON.parse(request.body);
    assert.deepEqual(body.tools[0].parameters, sampleSchema);
    assert.equal(body.store, false);
    return {ok: true, json: async () => ({output: [{type: 'function_call',
      name: 'page.observe', arguments: JSON.stringify(args)}]})};
  });
  return modelCall({baseUrl: 'http://127.0.0.1:1/v1', model: 'synthetic', transportGraceMs: 0},
    'page.observe', '合成协议检查，不执行网页操作', sampleSchema, '合成约束', {});
}

test('协议预检接受符合请求 schema 的工具参数', async t => {
  const result = await syntheticCall(t, validArgs());
  assert.deepEqual(result.arguments, validArgs());
  assert.equal(result.input_bytes, 2);
  assert.ok(result.request_bytes > result.input_bytes);
  assert.deepEqual(result.reported_usage,
      {input_tokens: null, output_tokens: null, total_tokens: null});
});

test('用量记录保留 UTF-8 字节数，非法服务用量不伪装成零', async t => {
  const input = {text: '中文指标 42'};
  let transmittedBody;
  t.mock.method(globalThis, 'fetch', async (_url, request) => {
    transmittedBody = request.body;
    return {ok: true, json: async () => ({
      output: [{type: 'function_call', name: 'page.observe',
        arguments: JSON.stringify(validArgs())}],
      usage: {input_tokens: 123, output_tokens: -1, total_tokens: '124'},
    })};
  });
  const result = await modelCall({baseUrl: 'http://127.0.0.1:1/v1', model: 'synthetic',
    transportGraceMs: 0}, 'page.observe', '协议检查', sampleSchema, '合成约束', input);
  assert.equal(result.input_bytes, Buffer.byteLength(JSON.stringify(input)));
  assert.ok(result.input_bytes > JSON.stringify(input).length);
  assert.equal(result.request_bytes, Buffer.byteLength(transmittedBody));
  assert.deepEqual(result.reported_usage,
      {input_tokens: 123, output_tokens: null, total_tokens: null});
  assert.ok(!JSON.stringify(result).includes(input.text));
});

for (const [name, change] of [
  ['额外字段', args => ({...args, cookie: 'synthetic-only'})],
  ['缺少必需字段', args => { delete args.kind; return args; }],
  ['整数类型错误', args => ({...args, tab_id: '7'})],
  ['整数不是安全整数', args => ({...args, tab_id: 1.5})],
  ['整数超出上界', args => ({...args, tab_id: 11})],
  ['枚举值不符', args => ({...args, kind: 'other'})],
  ['数组为空', args => ({...args, fields: []})],
  ['数组过长', args => ({...args, fields: ['a', 'b', 'c']})],
  ['数组元素类型错误', args => ({...args, fields: [7]})],
  ['嵌套字符串过长', args => ({...args, fields: ['12345']})],
]) test('协议预检拒绝' + name, async t => {
  await assert.rejects(syntheticCall(t, change(validArgs())), /工具参数不符合 schema/);
});

test('整段 CLI 不把脚本恢复当成模型或浏览器成功，也不覆盖报告', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aegis-model-preflight-test-'));
  const reportFile = path.join(dir, 'report.json');
  const model = 'synthetic-model';
  const counts = new Map();
  const server = http.createServer(async (request, response) => {
    response.setHeader('content-type', 'application/json');
    if (request.method === 'GET' && request.url === '/v1/models') {
      response.end(JSON.stringify({data: [{id: model}]}));
      return;
    }
    if (request.method !== 'POST' || request.url !== '/v1/responses') {
      response.writeHead(404).end('{}');
      return;
    }
    let raw = '';
    for await (const part of request) raw += part;
    const body = JSON.parse(raw);
    const input = JSON.parse(body.input);
    const name = body.tool_choice.name;
    counts.set(name, (counts.get(name) || 0) + 1);
    let args;
    if (name === 'agent.route_goal') {
      const goal = input.user_goal;
      const target = goal.includes('京东') ? 'https://www.jd.com' :
        goal.includes('cnbeta') ? 'https://www.cnbeta.com.tw' :
        goal.includes('VideoLAN') ? 'https://www.videolan.org' : '';
      args = {schema_version: 1, workflow: input.requested_workflow_hint,
        entry_kind: target ? 'open_url' : 'browser_only', target, summary: '合成路由'};
    } else if (name === 'agent.submit_plan') {
      // 两次都遗漏书签检查与预览，让 CLI 走其自身的只读对照，不执行浏览器。
      const tools = input.user_goal.includes('收藏夹') ? ['bookmark.list'] :
        input.user_goal.includes('Browser-owned schedule') ? ['page.observe', 'monitor.create'] :
        ['page.observe', 'page.extract'];
      args = {schema_version: 1, summary: '合成计划',
        steps: tools.map((tool, index) => ({id: 's' + index, title: '合成步骤', tool}))};
    } else if (name === 'page.observe') {
      args = {tab_id: 7};
    } else if (name === 'page.extract') {
      args = {tab_id: 7, document_token: 'document-7', kind: 'article'};
    } else if (name === 'monitor.create') {
      args = {tab_id: 7, document_token: 'document-7', kind: 'page_change', interval_minutes: 1440};
    } else if (name === 'agent.complete') {
      args = {outcome: 'completed', summary: '合成结果',
        source_urls: ['http://127.0.0.1:18765/research/source-01'], unfinished_items: []};
    } else {
      response.writeHead(400).end('{}');
      return;
    }
    response.end(JSON.stringify({output: [{type: 'function_call', name, arguments: JSON.stringify(args)}]}));
  });
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const script = fileURLToPath(new URL('./verify-agent-local-model.mjs', import.meta.url));
    const argv = [script, '--base-url', `http://127.0.0.1:${server.address().port}/v1`,
      '--model', model, '--rounds', '1', '--report', reportFile];
    const result = await promisify(execFile)(process.execPath, argv).catch(error => error);
    assert.equal(result.code, 1);
    const report = JSON.parse(fs.readFileSync(reportFile, 'utf8'));
    assert.equal(report.ok, false);
    assert.equal(report.qualification, 'model-protocol-only');
    assert.equal(report.browser_actions_executed, false);
    assert.equal(report.runtime_tested, false);
    assert.equal(report.release_eligible, false);
    assert.equal(report.summary.total_checks, 13);
    assert.equal(report.summary.total_model_calls, 14);
    const repaired = report.checks.find(item => item.resolution === 'preflight_read_only_recovery');
    assert.equal(repaired.call_metrics.length, 2);
    assert.equal(repaired.request_bytes, repaired.call_metrics.reduce(
        (total, item) => total + item.request_bytes, 0));
    assert.equal(repaired.input_bytes, repaired.call_metrics.reduce(
        (total, item) => total + item.input_bytes, 0));
    assert.deepEqual(repaired.reported_usage,
        {input_tokens: null, output_tokens: null, total_tokens: null});
    assert.equal(report.summary.plans_preflight_read_only_recovery, 1);
    assert.equal(report.summary.plans_browser_read_only_recovery, undefined);
    assert.equal(counts.get('agent.submit_plan'), 5);
    assert.equal([...counts.values()].reduce((sum, value) => sum + value, 0), 14);
    const before = fs.readFileSync(reportFile);
    const repeated = await promisify(execFile)(process.execPath, argv).catch(error => error);
    assert.equal(repeated.code, 1);
    assert.match(repeated.stderr, /EEXIST/);
    assert.deepEqual(fs.readFileSync(reportFile), before);
  } finally {
    await new Promise(resolve => server.close(resolve));
    // 仅移除本用例创建的合成报告与目录，不接触真实验收记录。
    fs.rmSync(dir, {recursive: true});
  }
});
