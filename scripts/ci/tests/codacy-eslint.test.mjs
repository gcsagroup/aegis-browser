import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';
import test from 'node:test';
import { Linter } from 'eslint';
import securityNode from 'eslint-plugin-security-node';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const config = [{
  files: ['**/*.mjs'],
  languageOptions: { ecmaVersion: 2022, sourceType: 'module' },
  plugins: { 'security-node': securityNode },
  rules: { 'security-node/detect-unhandled-async-errors': 'error' },
}];

test('固定的 Codacy 安全规则仍能复现上游空 catch 节点异常', () => {
  const source = 'async function example() { try { await work(); } finally { clean(); } }';
  assert.throws(() => new Linter().verify(source, config, { filename: 'control.mjs' }), /type/);
});

test('所有受版本控制的 MJS 文件均可完成 Codacy 安全规则扫描', () => {
  const files = execFileSync('git', ['ls-files', '-z', '--', '*.mjs'], {
    cwd: root, encoding: 'utf8',
  }).split('\0').filter(Boolean);
  assert.ok(files.length > 100, '必须扫描完整仓库，不能只检查修复样例');
  const linter = new Linter();
  for (const file of files) {
    let messages;
    assert.doesNotThrow(() => {
      messages = linter.verify(readFileSync(new URL(file, `file://${root}`), 'utf8'), config, { filename: file });
    }, file);
    // 该回归守住扫描器完整性；普通规则诊断继续由 Codacy 的质量门评估。
    assert.deepEqual(messages.filter((message) => message.fatal), [], file);
  }
});

// 运行实际生产函数，并注入外部依赖，避免启动浏览器或访问模型服务。
function loadFunction(file, name, globals) {
  const source = readFileSync(new URL(file, `file://${root}`), 'utf8');
  const start = source.indexOf(`async function ${name}(`);
  const end = source.indexOf('\n}', start);
  assert.ok(start >= 0 && end > start, `找不到完整函数 ${file}:${name}`);
  return vm.runInNewContext(`(${source.slice(start, end + 2)})`, globals);
}

test('真实超时包装保留返回值、原始错误、超时错误并各清理一次计时器', async () => {
  for (const scenario of ['success', 'failure', 'timeout']) {
    let expire;
    let cleared = 0;
    const token = {};
    const original = new Error('业务错误');
    const withTimeout = loadFunction('apps/browser/scripts/verify-cdp-runtime.mjs', 'withTimeout', {
      VerificationError: Error,
      setTimeout(callback) { expire = callback; return token; },
      clearTimeout(timer) { assert.equal(timer, token); cleared += 1; },
    });
    const input = scenario === 'success' ? Promise.resolve(token)
      : scenario === 'failure' ? Promise.reject(original) : new Promise(() => {});
    const result = withTimeout(input, 10, '验证');
    if (scenario === 'timeout') expire();
    if (scenario === 'success') assert.equal(await result, token);
    else await assert.rejects(result, scenario === 'failure' ? (error) => error === original : /验证超时/);
    assert.equal(cleared, 1, scenario);
  }
});

test('真实 Stagehand worker 在成功、业务失败和清理失败时保留清理顺序及异常', async () => {
  for (const scenario of ['success', 'launch-failure', 'create-failure', 'operation-failure', 'cleanup-failure']) {
    const events = [];
    const original = new Error('业务错误');
    const cleanup = new Error('清理错误');
    const page = {
      goto: async () => {}, snapshot: async () => ({ formattedTree: '结果' }),
      url: async () => 'http://fixture.test/', title: async () => '夹具',
    };
    const browser = {
      context: { pages: async () => [page] },
      close: async () => { events.push('browser.close'); },
    };
    const stagehand = {
      act: async () => {
        if (scenario === 'operation-failure' || scenario === 'cleanup-failure') throw original;
        return '完成';
      },
      close: async () => {
        events.push('stagehand.close');
        if (scenario === 'cleanup-failure') throw cleanup;
      },
    };
    const main = loadFunction('prototypes/browser-agent-v2/src/p2-stagehand-agent-worker.mjs', 'main', {
      fs: { readFileSync: () => JSON.stringify({ model: { local: true, provider: 'openai' }, scenarioId: 'E2' }) },
      process: { argv: [], stdout: { write: () => events.push('result') } },
      createLocalOpenAiStagehandModel: () => ({ client: {}, calls: [] }),
      localBrowser: { launch: async () => {
        if (scenario === 'launch-failure') throw original;
        return browser;
      } },
      Stagehand: { create: async () => {
        if (scenario === 'create-failure') throw original;
        return stagehand;
      } },
    });
    if (scenario === 'success') {
      assert.equal(await main(), undefined);
      assert.deepEqual(events, ['result', 'stagehand.close', 'browser.close']);
    } else {
      await assert.rejects(main(), (error) => error === (scenario === 'cleanup-failure' ? cleanup : original));
      const expected = scenario === 'launch-failure' ? [] : scenario === 'create-failure'
        ? ['browser.close'] : scenario === 'cleanup-failure' ? ['stagehand.close'] : ['stagehand.close', 'browser.close'];
      assert.deepEqual(events, expected, scenario);
    }
  }
});
