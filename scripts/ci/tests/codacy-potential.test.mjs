import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import vm from 'node:vm';
import test from 'node:test';
import { canonicalJson as acquisition } from '../../../packages/core/src/script-risk/evaluation/public-pilot-acquisition.mjs';
import { canonicalJson as corpus } from '../../../packages/core/src/script-risk/evaluation/corpus-eval.mjs';
import { canonicalJson as blind } from '../../../packages/core/src/script-risk/evaluation/blind-protocol.mjs';

const root = new URL('../../../', import.meta.url);
const agentFile = 'apps/browser/scripts/verify-agent-runtime.mjs';
const bytecodeFile = 'apps/browser/scripts/verify-bytecode-shadow-runtime.mjs';

// 执行仓库里的实际声明，仅替换测试不能启动的外部服务。
function declaration(file, signature) {
  const source = readFileSync(new URL(file, root), 'utf8');
  const start = source.indexOf(signature);
  const end = source.indexOf('\n}', start);
  assert.ok(start >= 0 && end > start, `找不到完整声明：${signature}`);
  return source.slice(start, end + 2);
}

function load(file, signature, globals = {}) {
  return vm.runInNewContext(`(${declaration(file, signature)})`, globals);
}

for (const [name, canonical] of Object.entries({ acquisition, corpus, blind })) {
  test(`${name} 的规范化内容保留特殊自有键，摘要输入不得碰撞`, () => {
    const value = JSON.parse('{"z":1,"__proto__":{"changed":true},"constructor":{"prototype":{"flag":1}},"a":[{"__proto__":2}]}');
    const result = canonical(value);
    assert.deepEqual(JSON.parse(result), value);
    assert.notEqual(result, canonical({ z: 1, constructor: value.constructor, a: [{}] }));
    assert.equal(canonical({ z: 1, a: 2 }), '{"a":2,"z":1}');
    assert.equal(canonical(JSON.parse('{"__proto__":null}')), '{"__proto__":null}');
    assert.equal(Object.prototype.changed, undefined);
    assert.throws(() => canonical({ missing: undefined }), /undefined/);
  });
}

test('页面动作只读取快照的自有字符串映射，拒绝继承键和非字符串选择器', () => {
  const actions = load('prototypes/browser-agent-v2/src/m5-aegis-agent-worker.mjs', 'function actionsFromSnapshot(');
  const snapshot = {
    formattedTree: '[toString] link: 伪造动作\n[constructor] button: 伪造动作\n[__proto__] link: 伪造动作\n[real] link: 正常动作\n[bad] button: 无效选择器\n[empty] button: 空选择器',
    xpathMap: { real: '/html/body/a', bad: { path: '/wrong' }, empty: ' ' },
    urlMap: Object.create({ real: 'https://inherited.invalid/' }),
  };
  const result = JSON.parse(JSON.stringify(actions(snapshot)));
  assert.deepEqual(result, [{ selector: '/html/body/a', description: 'link: 正常动作', method: 'click', arguments: [], targetUrl: null }]);
  snapshot.urlMap.real = 'https://fixture.invalid/';
  assert.equal(actions(snapshot)[0].targetUrl, 'https://fixture.invalid/');
});

test('购物步骤不能借用 Object 原型属性构造导航地址', () => {
  const execute = load(agentFile, 'function executionArguments(', {
    previousResult: () => null, firstLiveTab: () => 1, latestPageEvidence: () => null,
    findOrigin: () => 'https://fixture.invalid', sourcePath: () => '/research/source-01',
  });
  for (const id of ['toString', 'constructor', '__proto__']) {
    assert.equal(execute('page.navigate', { required_step: { id } }, '').url,
      'https://fixture.invalid/research/source-01');
  }
  assert.equal(execute('page.navigate', { required_step: { id: 'shop-b-navigate' } }, '').url,
    'https://fixture.invalid/shop/b');
});

test('崩溃日志保留匹配语义，并能在有界时间内处理重复前缀长行', () => {
  const source = declaration(bytecodeFile, 'function fatalSignalCount(');
  const count = vm.runInNewContext(`(${source})`);
  for (const text of ['RenderProcessHost reported a crash', 'Child process 123 exited unexpectedly',
    'RenderProcessHost RenderProcessHost crashed', 'Child process Child process exited unexpectedly']) {
    assert.equal(count(text), 1, text);
  }
  for (const text of ['crash before RenderProcessHost', 'exited unexpectedly before Child process ',
    'RenderProcessHost\u2028crash', 'Child process \u2029exited unexpectedly',
    'RenderProcessHost\rcrash', 'Child process \rexited unexpectedly']) {
    assert.equal(count(text), 0, text);
  }
  assert.equal(count('RenderProcessHost\u2028RenderProcessHost crash'), 1);
  // 独立进程的期限确保旧的平方级回溯会失败，不用脆弱的毫秒级性能断言。
  const code = `const count = (${source}); for (const prefix of ['RenderProcessHost ', 'Child process ']) { if (count(prefix.repeat(60000)) !== 0) process.exit(1); }`;
  assert.doesNotThrow(() => execFileSync(process.execPath, ['--input-type=module', '-e', code], {
    timeout: 5000, stdio: 'pipe',
  }));
});

test('清理豁免拒绝嵌套头、换行和长空白恶意输入', () => {
  const source = declaration(bytecodeFile, 'function expectedSigtermCleanupLine(');
  const expected = vm.runInNewContext(`(${source})`);
  assert.equal(expected('[1:2:ERROR:test.cc(3)] Received signal 15'), true);
  assert.equal(expected('GPU process exited unexpectedly: exit_code=15'), true);
  for (const text of ['[[header]] Received signal 15', 'Received signal 15\u2028x',
    'Received signal 11', 'FATAL Received signal 15']) assert.equal(expected(text), false);
  const count = load(bytecodeFile, 'function fatalSignalCount(', { expectedSigtermCleanupLine: expected });
  assert.equal(count('[[header]] Received signal 15', { cleanup: true, controlledTerminationRequested: true }), 1);
  const code = `const expected = (${source}); if (expected('Received signal 15 ' + ' '.repeat(150000) + '\\u2028x')) process.exit(1);`;
  assert.doesNotThrow(() => execFileSync(process.execPath, ['-e', code], { timeout: 5000, stdio: 'pipe' }));
});

function fixtureClass(globals) {
  return load(agentFile, 'class AgentFixtureServer ', {
    resolve, dirname, randomUUID, FIXTURE_VERSION: 1, mkdir, writeFile, assert,
    sanitizedRequest: (request) => ({ url: request.url }),
    createServer: () => ({ close: (done) => done() }), ...globals,
  });
}

test('请求日志串行写入，关闭前等待全部写入且保留完整 JSON', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'aegis-codacy-log-'));
  let active = 0;
  let maximum = 0;
  const Fixture = fixtureClass({ writeFile: async (...args) => {
    active += 1; maximum = Math.max(maximum, active);
    try { await delay(5); await writeFile(...args); } finally { active -= 1; }
  } });
  const file = join(directory, 'report.json');
  const fixture = new Fixture({ logFile: file });
  try {
    for (let index = 0; index < 12; index += 1) fixture.record({ url: `/request/${index}` });
    await fixture.close();
    assert.equal(maximum, 1);
    assert.equal(active, 0);
    assert.equal(JSON.parse(await readFile(file, 'utf8')).requests.length, 12);
  } finally { await delay(20); await rm(directory, { recursive: true, force: true }); }
});

test('请求日志失败被保留并在关闭时报告，服务仍会关闭', async () => {
  const original = new Error('模拟磁盘不可写');
  let closed = false;
  const Fixture = fixtureClass({ mkdir: async () => {}, writeFile: async () => { throw original; },
    createServer: () => ({ close: (done) => { closed = true; done(); } }),
  });
  const fixture = new Fixture({ logFile: '/fixture/report.json' });
  fixture.record({ url: '/failed' });
  await assert.rejects(fixture.close(), (error) => error === original);
  assert.equal(closed, true);
});

test('真实回环 HTTP 请求完成后，关闭服务可读回全部请求日志', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'aegis-codacy-http-'));
  const file = join(directory, 'requests.json');
  const Fixture = fixtureClass({ createServer });
  const fixture = new Fixture({ logFile: file });
  fixture.handle = async (request, response) => { fixture.record(request); response.end('ok'); };
  try {
    const origin = await fixture.start();
    await Promise.all(Array.from({ length: 8 }, async (_, index) => {
      const response = await globalThis.fetch(`${origin}/request/${index}`);
      assert.equal(await response.text(), 'ok');
    }));
    await fixture.close();
    const report = JSON.parse(await readFile(file, 'utf8'));
    assert.equal(report.requests.length, 8);
    assert.equal(new Set(report.requests.map((request) => request.url)).size, 8);
    assert.equal(fixture.server.listening, false);
  } finally {
    if (fixture.server.listening) await fixture.close();
    await rm(directory, { recursive: true, force: true });
  }
});
