import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import { TextDecoder, TextEncoder } from 'node:util';
import vm from 'node:vm';
import test from 'node:test';
import { Linter } from 'eslint';
import securityNode from 'eslint-plugin-security-node';
import tseslint from 'typescript-eslint';
import { routePacks } from '../../../apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/catalog.js';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const config = [{
  files: ['**/*.{mjs,js,cjs,jsx,ts,tsx}'],
  languageOptions: { ecmaVersion: 2022, sourceType: 'module' },
  plugins: { 'security-node': securityNode },
  rules: securityNode.configs.recommended.rules,
}, {
  files: ['**/*.{ts,tsx}'],
  languageOptions: { parser: tseslint.parser },
}];

test('固定的 Codacy 安全规则仍能复现上游空 catch 节点异常', () => {
  const source = 'async function example() { try { await work(); } finally { clean(); } }';
  assert.throws(() => new Linter().verify(source, config, { filename: 'control.mjs' }), /type/);
});

test('固定的事件规则仍能复现表达式回调和函数引用的节点异常', () => {
  for (const callback of ['error => errors.push(error)', 'reject']) {
    const source = `const myEmitter = new EventEmitter(); myEmitter.on('error', ${callback});`;
    assert.throws(() => new Linter().verify(source, config, { filename: 'event-control.mjs' }), /length|loc/);
  }
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
  for (const name of ['readEntries', 'savePack']) {
    for (const failure of ['none', 'error', 'sync', ...(name === 'savePack' ? ['abort'] : [])]) {
      let closed = 0;
      const bytes = {};
      const transaction = {};
      const request = { result: bytes };
      const original = new Error('事务创建失败');
      const pack = { id: 'en-zh', version: 'fixture', rows: [{ decompressedHash: 'hash' }] };
      const db = {
        close() { closed += 1; },
        transaction() {
          if (failure === 'sync') throw original;
          Promise.resolve().then(() => {
            if (name === 'readEntries') request[failure === 'error' ? 'onerror' : 'onsuccess']();
            else transaction[failure === 'abort' ? 'onabort' : failure === 'error' ? 'onerror' : 'oncomplete']();
          });
          return Object.assign(transaction, { objectStore: () => ({
            get: () => request, put: () => {}, delete: () => {},
          }) });
        },
      };
      const operation = loadFunction('apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/worker.js', name, {
        openStore: async () => db,
        manifest: async () => [], languagePacks: () => [pack], readEntries: async () => [],
      });
      const result = name === 'readEntries' ? operation('files', ['hash']) : operation(pack, [bytes]);
      if (failure === 'sync') await assert.rejects(result, error => error === original);
      else if (failure !== 'none') await assert.rejects(result, name === 'readEntries' ? /storage_unavailable/ : /storage_full/);
      else if (name === 'readEntries') assert.equal((await result)[0], bytes);
      else assert.equal(await result, undefined);
      assert.equal(closed, 1, `${name}:${failure}`);
    }
  }
});

test('脚本保存成功、异步拒绝和同步异常均恢复表单，失败保留原始错误', async () => {
  for (const scenario of ['success', 'reject', 'throw']) {
    const original = new Error('保存失败');
    const inputs = { source: { value: 'fixture' }, world: { value: 'isolated' }, frames: { checked: false } };
    const saved = { scripts: [{ id: 'script-1', source: 'fixture', metadata: { name: 'fixture' } }] };
    let resolveRequest, rejectRequest, rendered = 0;
    const pending = new Promise((resolve, reject) => { resolveRequest = resolve; rejectRequest = reject; });
    const globals = {
      editBusy: false, record: null, $: id => inputs[id], uiText: text => text,
      check: () => ({ name: 'fixture' }), edit() {}, notify() {},
      render: value => { assert.equal(value, saved); rendered += 1; },
      request: () => { if (scenario === 'throw') throw original; return pending; },
    };
    const save = loadFunction('apps/browser/overlay/chrome/browser/resources/aegis/enhancements.js', 'save', globals);
    const result = save();
    assert.equal(globals.editBusy, true);
    assert.ok(Object.values(inputs).every(input => input.disabled));
    if (scenario === 'success') resolveRequest(saved);
    if (scenario === 'reject') rejectRequest(original);
    if (scenario === 'success') await result;
    else await assert.rejects(result, error => error === original);
    assert.equal(globals.editBusy, false);
    assert.ok(Object.values(inputs).every(input => !input.disabled));
    assert.equal(rendered, scenario === 'success' ? 1 : 0);
  }
});

// 运行实际生产函数，并注入外部依赖，避免启动浏览器或访问模型服务。
function loadFunction(file, name, globals) {
  const source = readFileSync(new URL(file, `file://${root}`), 'utf8');
  const signature = source.includes(`async function ${name}(`) ? `async function ${name}(` : `function ${name}(`;
  const start = source.indexOf(signature);
  const end = source.indexOf('\n}', start);
  assert.ok(start >= 0 && end > start, `找不到完整函数 ${file}:${name}`);
  // VM 中仅替换模块加载入口，业务与清理逻辑均取自产品文件。
  const body = source.slice(start, end + 2)
    .replaceAll('import.meta.url', JSON.stringify(new URL(file, `file://${root}`).href))
    .replace(/await import\('([^']+)'\)/gu, (_, specifier) => `await importForTest(${JSON.stringify(specifier)})`);
  return vm.runInNewContext(`(${body})`, globals);
}

test('stderr 管道的四个错误监听仍逐一保留原始错误', async () => {
  const child = new EventEmitter();
  const streams = Array.from({ length: 4 }, () => new EventEmitter());
  [child.stdin, child.stdout] = streams;
  child.stdio = [child.stdin, child.stdout, null, streams[2], streams[3]];
  const start = loadFunction('apps/browser/scripts/verify-bytecode-shadow-runtime.mjs', 'startStderrPipeHolder', {
    spawn: () => child, STDERR_HOLDER_SCRIPT: '', process: { env: {} }, assert, VerificationError: Error,
  });
  const state = start();
  const errors = streams.map((stream, index) => {
    const error = new Error(`管道 ${index}`);
    stream.emit('error', error);
    return error;
  });
  assert.deepEqual(Array.from(state.streamErrors), errors);
  child.emit('close', 0, null);
  assert.equal((await state.closePromise).exitCode, 0);
});

test('本机翻译在成功和翻译失败后均释放模型与服务', async () => {
  const worker = 'apps/browser/overlay/chrome/browser/resources/aegis_agent/local_ai/worker.js';
  const rows = JSON.parse(readFileSync(new URL(worker.replace('worker.js', 'translation_manifest.json'), `file://${root}`), 'utf8'));
  const splitText = loadFunction(worker, 'splitText', {});
  const translateWithMarkers = loadFunction(worker, 'translateWithMarkers', { splitText });
  const translateParagraph = loadFunction(worker, 'translateParagraph', { translateWithMarkers });
  for (const direction of ['en-zh', 'zh-fr']) {
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
        freeTranslationModel(pair) { events.push(`model.free:${pair.from}-${pair.to}`); }
      }
      const execute = loadFunction(worker, 'execute', {
        TextEncoder, manifest: async () => rows, routePacks,
        installed: async pack => ({ rows: pack.rows, files: pack.rows.map(() => ({})) }),
        translateParagraph, progress: () => {},
        importForTest: async (specifier) => {
          assert.equal(specifier, './bergamot/worker/translator-worker.js');
          return { BergamotTranslatorWorker };
        },
      });
      const result = execute({ op: 'translate', direction, paragraphs: ['hello'] });
      if (failure) await assert.rejects(result, (error) => error === original);
      else assert.deepEqual(JSON.parse(JSON.stringify(await result)), { translations: ['译文'], language: direction === 'en-zh' ? 'zh-CN' : 'fr' });
      assert.deepEqual(events, [...routePacks(rows, direction).map(pack => `model.free:${pack.from}-${pack.to}`), 'service.delete']);
    }
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

test('CDP 发送边界拒绝非回环地址和重定向，真实回环请求可完成', async () => {
  let calls = 0;
  let redirect = false;
  const server = createServer((request, response) => {
    calls += 1;
    assert.equal(request.method, 'PUT');
    assert.equal(request.url, '/json/new');
    if (redirect) response.writeHead(302, { location: 'http://example.test/forbidden' });
    else response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ id: 'local-target' }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const createTarget = loadFunction('apps/browser/scripts/verify-download-runtime.mjs', 'createLocalCdpTarget', {
    URL, assert, VerificationError: Error, fetch: globalThis.fetch,
  });
  try {
    for (const url of ['http://example.test/json/new', 'http://127.0.0.1.example.test/json/new',
      'https://127.0.0.1/json/new', 'http://user:password@127.0.0.1/json/new',
      'http://127.0.0.1/other', 'http://127.0.0.1/json/new?url=outside']) {
      await assert.rejects(createTarget(url), /CDP 请求/);
    }
    assert.equal(calls, 0);
    const url = `http://127.0.0.1:${server.address().port}/json/new`;
    assert.deepEqual(await createTarget(url), { id: 'local-target' });
    redirect = true;
    await assert.rejects(createTarget(url), /fetch failed/);
    assert.equal(calls, 2);
  } finally {
    await new Promise((resolve) => server.close(resolve));
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
