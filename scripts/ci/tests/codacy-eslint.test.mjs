import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { TextDecoder, TextEncoder } from 'node:util';
import vm from 'node:vm';
import test from 'node:test';
import { Linter } from 'eslint';
import securityNode from 'eslint-plugin-security-node';
import tseslint from 'typescript-eslint';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const config = [{
  files: ['**/*.{mjs,js,cjs,jsx,ts,tsx}'],
  languageOptions: { ecmaVersion: 2022, sourceType: 'module' },
  plugins: { 'security-node': securityNode },
  rules: { 'security-node/detect-unhandled-async-errors': 'error' },
}, {
  files: ['**/*.{ts,tsx}'],
  languageOptions: { parser: tseslint.parser },
}];

test('固定的 Codacy 安全规则仍能复现上游空 catch 节点异常', () => {
  const source = 'async function example() { try { await work(); } finally { clean(); } }';
  assert.throws(() => new Linter().verify(source, config, { filename: 'control.mjs' }), /type/);
});

test('全部 JavaScript 和 TypeScript 文件均可完成 Codacy 安全规则扫描', () => {
  const files = execFileSync('git', ['ls-files', '-z'], {
    cwd: root, encoding: 'utf8',
  }).split('\0').filter((file) => /\.(?:[cm]?js|jsx|tsx?)$/u.test(file) && !file.endsWith('.min.js'));
  assert.ok(files.length > 250, '必须扫描完整仓库，不能只检查修复样例');
  assert.ok(files.some((file) => file.endsWith('/local_ai/research.js')));
  assert.ok(files.some((file) => file.endsWith('/local_ai/worker.js')));
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

test('本机翻译存储在读写成功和失败时均关闭数据库且保留结果', async () => {
  for (const name of ['readFiles', 'writeFiles']) {
    for (const failure of [false, true]) {
      let closed = 0;
      const bytes = {};
      const transaction = {};
      const request = { result: bytes };
      const db = {
        close() { closed += 1; },
        transaction() {
          Promise.resolve().then(() => {
            if (name === 'readFiles') request[failure ? 'onerror' : 'onsuccess']();
            else transaction[failure ? 'onerror' : 'oncomplete']();
          });
          return Object.assign(transaction, { objectStore: () => ({
            get: () => request, put: () => {}, delete: () => {},
          }) });
        },
      };
      const operation = loadFunction('apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/worker.js', name, {
        openStore: async () => db,
      });
      const result = operation([{ decompressedHash: 'hash' }], [bytes]);
      if (failure) await assert.rejects(result, name === 'readFiles' ? /storage_unavailable/ : /storage_full/);
      else if (name === 'readFiles') assert.equal((await result)[0], bytes);
      else assert.equal(await result, undefined);
      assert.equal(closed, 1, `${name}:${failure}`);
    }
  }
});

// 运行实际生产函数，并注入外部依赖，避免启动浏览器或访问模型服务。
function loadFunction(file, name, globals) {
  const source = readFileSync(new URL(file, `file://${root}`), 'utf8');
  const start = source.indexOf(`async function ${name}(`);
  const end = source.indexOf('\n}', start);
  assert.ok(start >= 0 && end > start, `找不到完整函数 ${file}:${name}`);
  // VM 中仅替换模块加载入口，业务与清理逻辑均取自产品文件。
  const body = source.slice(start, end + 2)
    .replaceAll('import.meta.url', JSON.stringify(new URL(file, `file://${root}`).href))
    .replace(/await import\('([^']+)'\)/gu, (_, specifier) => `await importForTest(${JSON.stringify(specifier)})`);
  return vm.runInNewContext(`(${body})`, globals);
}

test('本机翻译在成功和翻译失败后均释放模型与服务', async () => {
  for (const failure of [false, true]) {
    const events = [];
    const original = new Error('翻译失败');
    class BergamotTranslatorWorker {
      service = { delete: () => events.push('service.delete') };
      async initialize() {}
      loadTranslationModel() {}
      translate() {
        if (failure) throw original;
        return [{ target: { text: '译文' } }];
      }
      freeTranslationModel() { events.push('model.free'); }
    }
    const execute = loadFunction('apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/worker.js', 'execute', {
      TextEncoder, manifest: async () => [], verified: async () => [],
      splitText: (text) => [text], progress: () => {},
      importForTest: async (specifier) => {
        assert.equal(specifier, './bergamot/worker/translator-worker.js');
        return { BergamotTranslatorWorker };
      },
    });
    const result = execute({ op: 'translate', direction: 'en-zh', paragraphs: ['hello'] });
    if (failure) await assert.rejects(result, (error) => error === original);
    else assert.deepEqual(JSON.parse(JSON.stringify(await result)), { translations: ['译文'], language: 'zh-CN' });
    assert.deepEqual(events, ['model.free', 'service.delete']);
  }
});

test('实验推理在成功和失败后释放会话，成功时继续返回分析结果', async () => {
  for (const failure of [false, true]) {
    let released = 0;
    const original = new Error('推理失败');
    const manifest = { phishlang: { bundled: true, onnx_sha256: 'hash' } };
    const analyze = loadFunction('apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/research.js', 'analyze', {
      TextEncoder, TextDecoder, URL,
      fetchBytes: async (path) => new TextEncoder().encode(path.endsWith('research_manifest.json') ? JSON.stringify(manifest) : 'hello'),
      sha: async () => 'hash', tokenize: () => [10],
      importForTest: async (specifier) => {
        assert.equal(specifier, './vendor/ort.js');
        return {
          env: { wasm: {} }, Tensor: class {},
          InferenceSession: { create: async () => ({
            run: async () => {
              if (failure) throw original;
              return { logits: { data: [0, 1], dispose() {} } };
            },
            release: async () => { released += 1; },
          }) },
        };
      },
    });
    const result = analyze({ paragraphs: ['hello'], minim: false, phishlang: true, goal: '阅读' }, () => {});
    if (failure) await assert.rejects(result, (error) => error === original);
    else {
      const value = await result;
      assert.equal(value.phishlang.windows, 1);
      assert.equal(value.phishlang.tokens, 1);
      assert.equal(value.phishlang.flagged, true);
    }
    assert.equal(released, 1);
  }
});

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

test('下载验收仅接受有效的本机 DevTools 端口', async () => {
  for (const port of ['1', '65535', '0', '65536', '-1', '1@remote.test', 'NaN', 'Infinity']) {
    let ticks = 0;
    const devToolsPort = loadFunction('apps/browser/scripts/verify-download-runtime.mjs', 'devToolsPort', {
      join, assert, VerificationError: Error, POLL_MS: 1,
      performance: { now: () => ticks++ },
      readFile: async () => port, delay: async () => {},
    });
    const result = devToolsPort('/fixture', { exitCode: null }, 2);
    if (port === '1' || port === '65535') assert.equal(await result, Number(port));
    else await assert.rejects(result, /等待 DevToolsActivePort 超时/);
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
