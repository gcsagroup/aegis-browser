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

test('Provider bounded preserves values, rejection identity, cancellation and cleanup', async () => {
  const scenarios = ['success', 'error', 'non-error', 'thenable-throw', 'already-aborted',
    'abort', 'foreign-abort', 'deadline-timer', 'deadline-after-value'];
  for (const scenario of scenarios) {
    const events = [];
    const value = {};
    const token = {};
    class ProviderError extends Error {}
    const original = scenario === 'non-error' ? { code: 'opaque-rejection' }
      : scenario === 'already-aborted' || scenario === 'abort'
        ? new ProviderError('CANCELLED') : new Error('original');
    let listener, expire, now = 0;
    const signal = {
      aborted: scenario === 'already-aborted',
      reason: scenario === 'already-aborted' ? original : undefined,
      addEventListener(type, callback, options) {
        assert.equal(type, 'abort'); assert.equal(options.once, true);
        listener = callback; events.push('listen');
      },
      removeEventListener(type, callback) {
        assert.equal(type, 'abort'); assert.equal(callback, listener); events.push('unlisten');
      },
    };
    const bounded = loadFunction('prototypes/access-provider-service/authority.mjs', 'bounded', {
      ProviderError, performance: { now: () => now },
      setTimeout(callback, delay) {
        assert.equal(delay, 10); expire = callback; events.push('timer'); return token;
      },
      clearTimeout(actual) { assert.equal(actual, token); events.push('clear'); },
    });
    const input = scenario === 'success' || scenario === 'deadline-after-value' ? Promise.resolve(value)
      : scenario === 'error' || scenario === 'non-error' ? Promise.reject(original)
        : scenario === 'thenable-throw' ? { get then() { throw original; } } : new Promise(() => {});
    const result = bounded(input, { signal, deadline: 10 });
    assert.deepEqual(events, ['listen', 'timer'], scenario);
    if (scenario === 'abort' || scenario === 'foreign-abort') {
      signal.aborted = true; signal.reason = original; listener();
    }
    if (scenario === 'deadline-timer') { now = 10; expire(); }
    if (scenario === 'deadline-after-value') now = 10;
    if (scenario === 'success') assert.equal(await result, value);
    else await assert.rejects(result, (error) => {
      if (['foreign-abort', 'deadline-timer', 'deadline-after-value'].includes(scenario)) {
        assert.ok(error instanceof ProviderError); assert.equal(error.message, 'DEADLINE_EXCEEDED');
      } else assert.equal(error, original, scenario);
      return true;
    });
    assert.deepEqual(events, ['listen', 'timer', 'clear', 'unlisten'], scenario);
  }
});

test('Provider owned client preserves return, error identity and lease cleanup ordering', async () => {
  for (const scenario of ['success', 'prepare-throw', 'prepare-reject', 'checkout-reject',
    'work-throw', 'work-reject', 'work-non-error', 'abort-after-work', 'deadline-after-work']) {
    const events = [];
    const original = scenario === 'work-non-error' ? { code: 'opaque-rejection' } : new Error(scenario);
    const value = {};
    const prepared = {};
    const context = { signal: { aborted: false }, deadline: 10 };
    let now = 0, releases = 0, releaseEffects = 0, ended = 0, checks = 0;
    const lease = {
      release() { releases += 1; if (releaseEffects === 0) { releaseEffects += 1; events.push('release'); } },
    };
    class Scope {
      constructor(actual) { assert.equal(actual, context); this.context = actual; }
      wait(promise) { return promise; }
      check() {
        checks += 1;
        if (context.signal.aborted || now >= context.deadline) throw original;
      }
      end() { ended += 1; events.push('end'); }
    }
    const poolSink = () => {};
    const pool = {
      on(event, handler) { assert.equal(event, 'error'); assert.equal(handler, poolSink); },
      end() {}, connect() {},
    };
    const withOwnedPgClient = loadFunction('prototypes/access-provider-service/store.mjs', 'withOwnedPgClient', {
      Scope, AbortController: globalThis.AbortController, poolSink,
      reject(code) { throw new Error(code); },
      checkout: async (actualPool) => {
        assert.equal(actualPool, pool);
        if (scenario === 'checkout-reject') throw original;
        return lease;
      },
    });
    const prepare = (actual) => {
      assert.equal(actual, context);
      if (scenario === 'prepare-throw') throw original;
      if (scenario === 'prepare-reject') return Promise.reject(original);
      return prepared;
    };
    const work = (actualLease, scope, actualPrepared) => {
      assert.equal(actualLease, lease); assert.equal(scope.context, context); assert.equal(actualPrepared, prepared);
      if (scenario === 'work-throw') throw original;
      if (scenario === 'work-reject' || scenario === 'work-non-error') return Promise.reject(original);
      if (scenario === 'abort-after-work') context.signal.aborted = true;
      if (scenario === 'deadline-after-work') now = 10;
      return value;
    };
    const result = withOwnedPgClient(pool, context, prepare, work);
    if (scenario === 'success') assert.equal(await result, value);
    else await assert.rejects(result, (error) => error === original);
    const noLease = scenario.startsWith('prepare-') || scenario === 'checkout-reject';
    assert.equal(ended, 1, scenario);
    assert.equal(releaseEffects, noLease ? 0 : 1, scenario);
    // Success and the final admission check call release again in finally; the owned lease is idempotent.
    assert.equal(releases, noLease ? 0 : ['success', 'abort-after-work', 'deadline-after-work'].includes(scenario) ? 2 : 1, scenario);
    assert.deepEqual(events, noLease ? ['end'] : ['release', 'end'], scenario);
    assert.equal(checks, noLease ? 1 : ['success', 'abort-after-work', 'deadline-after-work'].includes(scenario) ? 3 : 2, scenario);
  }
});

test('Provider migration preserves outcomes, abort forwarding and awaited cleanup', async () => {
  for (const scenario of ['success', 'validate-throw', 'owner-throw', 'read-throw',
    'owned-reject', 'owned-non-error', 'already-aborted', 'abort', 'expired-budget', 'close-reject']) {
    const events = [];
    const value = {};
    const original = scenario === 'owned-non-error' ? { code: 'opaque-rejection' } : new Error(scenario);
    const owner = {};
    let now = 0, relay, controller, closeCalls = 0, closeBudget, closeResolve, closeEntered;
    const closeStarted = new Promise(resolve => { closeEntered = resolve; });
    const signal = {
      aborted: scenario === 'already-aborted', reason: original,
      addEventListener(type, callback, options) {
        assert.equal(type, 'abort'); assert.equal(options.once, true); relay = callback; events.push('listen');
      },
      removeEventListener(type, callback) {
        assert.equal(type, 'abort'); assert.equal(callback, relay); events.push('unlisten');
      },
    };
    class Controller {
      signal = { aborted: false, reason: undefined };
      constructor() { controller = this; }
      abort(reason) {
        events.push('abort');
        if (!this.signal.aborted) { this.signal.aborted = true; this.signal.reason = reason; }
      }
    }
    const pool = { on() {}, connect() {}, end() {} };
    const migrate = loadFunction('prototypes/access-provider-service/migrate.mjs', 'migrate', {
      URL, AbortController: Controller, performance: { now: () => now },
      validateTrust() { if (scenario === 'validate-throw') throw original; return {}; },
      reject(code) { throw new Error(code); },
      readFile() { if (scenario === 'read-throw') throw original; return Promise.resolve('inert SQL fixture'); },
      withOwnedPgClient: async (actualPool, context, prepare, work) => {
        assert.equal(actualPool, pool); assert.equal(context.deadline, 4000); assert.equal(context.signal, controller.signal);
        assert.equal(typeof work, 'function');
        if (scenario === 'abort') { signal.aborted = true; relay(); }
        if (context.signal.aborted) throw context.signal.reason;
        assert.equal(await prepare(context), 'inert SQL fixture');
        if (scenario === 'owned-reject' || scenario === 'owned-non-error') throw original;
        if (scenario === 'expired-budget') now = 6000;
        return value;
      },
      closeOwnedPool(actualPool, budget) {
        assert.equal(actualPool, pool); closeCalls += 1; closeBudget = budget; events.push('close'); closeEntered();
        if (scenario === 'close-reject') return Promise.reject(original);
        return new Promise(resolve => { closeResolve = resolve; });
      },
    });
    const result = migrate({
      pool, trust: {}, owner, signal,
      verifyOwner: async (actualOwner, operation, context) => {
        assert.equal(actualOwner, owner); assert.equal(operation, 'create-fresh-schema');
        assert.equal(context.signal, controller.signal);
        if (scenario === 'owner-throw') throw original;
      },
    });
    let settled = false;
    const observed = result.then(value => { settled = true; return { value }; },
      error => { settled = true; return { error }; });
    if (scenario !== 'validate-throw') {
      await closeStarted;
      if (scenario !== 'close-reject') {
        assert.equal(settled, false, scenario); closeResolve();
      }
    }
    const outcome = await observed;
    if (scenario === 'success' || scenario === 'expired-budget') assert.equal(outcome.value, value);
    else assert.equal(outcome.error, original, scenario);
    const relayed = scenario === 'already-aborted' || scenario === 'abort';
    assert.deepEqual(events, ['listen', ...(relayed ? ['abort'] : []), 'abort', 'unlisten',
      ...(scenario === 'validate-throw' ? [] : ['close'])], scenario);
    assert.equal(closeCalls, scenario === 'validate-throw' ? 0 : 1, scenario);
    if (closeCalls) assert.equal(closeBudget, scenario === 'expired-budget' ? 0 : 5000, scenario);
    assert.equal(controller.signal.aborted, true);
    if (relayed) assert.equal(controller.signal.reason, original);
  }
});


function providerFixtureFunction(file, name, globals) {
  const source = readFileSync(new URL(file, `file://${root}`), 'utf8');
  let range;
  const capture = {
    meta: { schema: [] },
    create() {
      return { FunctionDeclaration(node) { if (node.id?.name === name) { assert.equal(range, undefined); range = node.range; } } };
    },
  };
  const diagnostics = new Linter().verify(source, [{
    files: ['**/*.mjs'], languageOptions: { ecmaVersion: 2022, sourceType: 'module' },
    plugins: { capture: { rules: { function: capture } } }, rules: { 'capture/function': 'error' },
  }], { filename: file });
  assert.equal(diagnostics.some(message => message.fatal), false);
  assert.ok(range, name);
  return vm.runInNewContext('(' + source.slice(...range) + ')', globals);
}

function providerFixtureError(code) {
  return Object.assign(new Error(code), { code });
}

test('Provider fixture until preserves cancellation, rejection identity and timer cleanup', async () => {
  for (const scenario of ['success', 'reject', 'non-error', 'thenable-throw', 'already-aborted', 'abort', 'foreign-abort', 'deadline']) {
    const events = [], value = {}, timer = {};
    class ProviderError extends Error {}
    const original = scenario === 'non-error' ? {} : ['already-aborted', 'abort'].includes(scenario)
      ? new ProviderError('CANCELLED') : new Error(scenario);
    let abort, expire, now = 0;
    const signal = {
      aborted: scenario === 'already-aborted', reason: original,
      addEventListener(type, callback, options) { assert.equal(type, 'abort'); assert.equal(options.once, true); abort = callback; events.push('listen'); },
      removeEventListener(type, callback) { assert.equal(type, 'abort'); assert.equal(callback, abort); events.push('unlisten'); },
    };
    const until = providerFixtureFunction('prototypes/access-provider-service/test/fixtures.mjs', 'until', {
      ProviderError, performance: { now: () => now },
      setTimeout(callback, delay) { assert.equal(delay, 10); expire = callback; events.push('timer'); return timer; },
      clearTimeout(actual) { assert.equal(actual, timer); events.push('clear'); },
    });
    const promise = scenario === 'success' ? Promise.resolve(value)
      : ['reject', 'non-error'].includes(scenario) ? Promise.reject(original)
        : scenario === 'thenable-throw' ? { get then() { throw original; } } : new Promise(() => {});
    const result = until(promise, { signal, deadline: 10 });
    assert.deepEqual(events, ['listen', 'timer']);
    if (['abort', 'foreign-abort'].includes(scenario)) { signal.aborted = true; abort(); }
    if (scenario === 'deadline') { now = 10; expire(); }
    if (scenario === 'success') assert.equal(await result, value);
    else await assert.rejects(result, error => {
      if (['foreign-abort', 'deadline'].includes(scenario)) {
        assert.ok(error instanceof ProviderError); assert.equal(error.message, 'DEADLINE_EXCEEDED');
      } else assert.equal(error, original);
      return true;
    });
    assert.deepEqual(events, ['listen', 'timer', 'clear', 'unlisten'], scenario);
  }
});

test('Provider fixture checkedToolHash preserves stream and synchronous failures and destroys once', async () => {
  for (const scenario of ['success', 'check-throw', 'check-non-error', 'stream-reject', 'update-throw', 'digest-throw', 'destroy-throw']) {
    const original = scenario === 'check-non-error' ? {} : new Error(scenario);
    const events = []; let checks = 0;
    const stream = {
      async *[Symbol.asyncIterator]() {
        try { yield 'a'; if (scenario === 'stream-reject') throw original; yield 'b'; }
        finally { events.push('iterator-end'); }
      },
      destroy() { events.push('destroy'); if (scenario === 'destroy-throw') throw original; },
    };
    const hash = {
      update(chunk) { events.push(chunk); if (scenario === 'update-throw') throw original; return this; },
      digest(format) { assert.equal(format, 'hex'); if (scenario === 'digest-throw') throw original; return 'exact-digest'; },
    };
    const checked = providerFixtureFunction('prototypes/access-provider-service/test/owner/owner.mjs', 'checkedToolHash', {
      createReadStream(filename) { assert.equal(filename, '/inert/tool'); return stream; },
      createHash(algorithm) { assert.equal(algorithm, 'sha256'); return hash; },
    });
    const result = checked('/inert/tool', () => {
      checks += 1; if (scenario.startsWith('check-')) throw original;
    });
    if (scenario === 'success') assert.equal(await result, 'exact-digest');
    else await assert.rejects(result, error => error === original);
    assert.equal(events.filter(event => event === 'destroy').length, 1);
    assert.deepEqual(events.slice(-2), ['iterator-end', 'destroy']);
    assert.equal(checks, ['success', 'digest-throw', 'destroy-throw'].includes(scenario) ? 3 : 1);
  }
});

test('Provider fixture health preserves query outcomes and awaited pool cleanup', async () => {
  for (const scenario of ['success', 'query-throw', 'query-reject', 'query-non-error', 'invalid-health', 'release-throw', 'end-reject']) {
    const original = scenario === 'query-non-error' ? {} : providerFixtureError(scenario);
    const events = []; let finishEnd, enterEnd;
    const endStarted = new Promise(resolve => { enterEnd = resolve; });
    const row = { role: 'b1_app', database: 'b1', version: '170011', fsync: 'on',
      synchronous_commit: 'on', full_page_writes: 'on', superuser: false, database_ddl: false, schema_ddl: false };
    if (scenario === 'invalid-health') row.fsync = 'off';
    const client = {
      on(type, handler) { assert.equal(type, 'error'); assert.equal(typeof handler, 'function'); },
      query(sql) {
        assert.match(sql, /server_version_num/u);
        if (scenario === 'query-throw') throw original;
        return scenario.startsWith('query-') ? Promise.reject(original) : Promise.resolve({ rows: [row] });
      },
      release() { events.push('release'); if (scenario === 'release-throw') throw original; },
    };
    const pool = {
      connect: async () => client,
      end() {
        events.push('end'); enterEnd();
        return scenario === 'end-reject' ? Promise.reject(original) : new Promise(resolve => { finishEnd = resolve; });
      },
    };
    const health = providerFixtureFunction('prototypes/access-provider-service/test/pg-harness.mjs', 'health', {
      admission: async operation => { assert.equal(operation, 'verify-health'); },
      pool: () => pool, pools: { delete(actual) { assert.equal(actual, pool); events.push('delete'); } },
      reject(code) { assert.equal(code, 'SQL_NOT_ADMITTED'); throw original; },
    });
    let settled = false;
    const observed = health().then(value => { settled = true; return { value }; }, error => { settled = true; return { error }; });
    if (scenario !== 'release-throw') {
      await endStarted;
      if (scenario !== 'end-reject') { assert.equal(settled, false); finishEnd(); }
    }
    const result = await observed;
    if (scenario === 'success') assert.deepEqual({ ...result.value }, {
      version: '170011', fsync: 'on', synchronous_commit: 'on', full_page_writes: 'on',
    });
    else assert.equal(result.error, original);
    assert.deepEqual(events, scenario === 'release-throw' ? ['release']
      : scenario === 'end-reject' ? ['release', 'end'] : ['release', 'end', 'delete']);
  }
});

test('Provider fixture finishRuntime preserves primary throws and cleanup ordering', async () => {
  for (const scenario of ['success', 'resources-throw', 'resources-non-error', 'harness-throw', 'owner-reject', 'resource-incomplete']) {
    class OwnerError extends Error { constructor(code) { super(code); this.code = code; } }
    const original = scenario === 'resources-non-error' ? {} : new OwnerError('ORIGINAL');
    const cleanup = { status: 'STOPPED_RETAINED' }, events = [], incomplete = { status: 'RETAINED', name: 'resources' };
    const runtime = {
      resources: { closeCase(options) {
        assert.equal(options.deadline, 1990); events.push('resources');
        if (scenario.startsWith('resources-')) throw original;
      } },
      harness: { close() { events.push('harness'); if (scenario === 'harness-throw') throw original; } },
      owner: { cleanup: async options => {
        assert.equal(options.deadline, 10000); events.push('owner');
        if (scenario === 'owner-reject') throw original;
        return cleanup;
      } },
    };
    const finish = providerFixtureFunction('prototypes/access-provider-service/test/owner/runner.mjs', 'finishRuntime', {
      OwnerError, CAPS: { cleanupMs: 10000 }, performance: { now: () => 0 },
      settleClosures: async (entries, deadline) => {
        assert.equal(deadline, 2000); assert.equal(entries.length, 1);
        await entries[0].close();
        return [scenario === 'resource-incomplete' && entries[0].name === 'resources' ? incomplete : { status: 'CLOSED' }];
      },
      ownedRace: async (work, options) => { assert.equal(options.deadline, 10000); return work(); },
    });
    const result = finish(runtime);
    if (scenario === 'success') assert.equal(await result, cleanup);
    else await assert.rejects(result, error => {
      if (['owner-reject', 'resource-incomplete'].includes(scenario)) {
        assert.ok(error instanceof OwnerError); assert.equal(error.code, 'OWNER_CLEANUP_INCOMPLETE');
        if (scenario === 'owner-reject') assert.equal(error.cleanup.code, 'ORIGINAL');
        else { assert.equal(error.cleanup, cleanup); assert.equal(error.failures[0], incomplete); }
      } else assert.equal(error, original);
      return true;
    });
    assert.deepEqual(events, ['resources', 'harness', 'owner']);
  }
});

test('Provider fixture clockSmoke preserves both cleanup boundaries and original failures', async () => {
  for (const scenario of ['success', 'observe-throw', 'observe-reject', 'observe-non-error', 'transaction-throw', 'close-reject']) {
    const original = scenario === 'observe-non-error' ? {} : new Error(scenario), events = [], value = {};
    class DatabaseError extends Error {}
    class ProviderError extends Error { constructor(code) { super(code); this.code = code; } }
    const context = {}, interval = { latest: 10 }, clock = { now: 10, observe: () => interval };
    const store = {
      observeTime(actual, sample) {
        assert.equal(actual, context); assert.equal(sample(), interval);
        if (scenario === 'observe-throw') throw original;
        return scenario.startsWith('observe-') ? Promise.reject(original) : Promise.resolve(interval);
      },
      transaction(actual, work) {
        assert.equal(actual, context); if (scenario === 'transaction-throw') throw original;
        return work({ time: async sample => { assert.equal(sample().now, 11); } });
      },
      close: async () => { events.push('store-close'); if (scenario === 'close-reject') throw original; },
    };
    const row = { highwater: '11', pending_id: null };
    const owner = {
      gate: { require: async operation => { assert.equal(operation, 'run-clock-smoke'); } },
      withClient: async (role, work) => {
        assert.equal(role, 'b1_app');
        return work({ query(sql) {
          if (sql.startsWith('UPDATE')) return Promise.reject(Object.assign(new DatabaseError(), { code: '42501' }));
          return Promise.resolve({ rows: [sql.includes('has_database_privilege') ? { db: false, schema: false } : {}] });
        } });
      },
      record(name, data) { assert.equal(name, 'migration-lock-clock-smoke'); assert.equal(data.rollbackFloor, 11); return value; },
    };
    const harness = {
      health: async () => {}, newStore: () => store,
      holdDomain: async () => ({ release: async () => { events.push('held-release'); } }),
      restartDatabase: async mode => { assert.equal(mode, 'clean'); events.push('restart'); },
    };
    const smoke = providerFixtureFunction('prototypes/access-provider-service/test/owner/fault-cases.mjs', 'clockSmoke', {
      // Spreading plain records normalizes only VM-realm object prototypes.
      assert: { ...assert, deepEqual: (a, b) => assert.deepEqual({ ...a }, { ...b }) },
      DatabaseError, ProviderError, D: () => [], context: () => context, clockRow: async () => row,
      fail(code) { throw new Error(code); },
    });
    const result = smoke({ owner, harness, bindings: { clock } });
    if (scenario === 'success') assert.equal(await result, value);
    else await assert.rejects(result, error => error === original);
    assert.deepEqual(events, scenario.startsWith('observe-') ? ['held-release']
      : scenario === 'success' ? ['held-release', 'store-close', 'restart'] : ['held-release', 'store-close']);
  }
});

test('Provider fixture issuance acknowledgement loss preserves original failures and app cleanup', async () => {
  for (const scenario of ['success', 'prepare-throw', 'prepare-reject', 'prepare-non-error', 'receipt-reject', 'already-aborted', 'abort', 'deadline', 'retry-reject']) {
    const original = scenario === 'prepare-non-error' ? {} : new Error(scenario), events = [], value = {}, receipt = {};
    const body = {}, signal = { aborted: scenario === 'already-aborted' };
    let apps = 0, requests = 0, preparations = 0;
    const committed = { id: 'op', consumed_operation_id: 'op', result_credential_id: 'credential', body };
    const owner = {
      signal, gate: { require: async operation => { assert.equal(operation, 'run-faults'); } },
      proxy: { arm(kind) { assert.equal(kind, 'issuance'); return Promise.resolve(receipt); }, disarm() { events.push('disarm'); } },
      withClient: async (role, work) => {
        assert.equal(role, 'b1_bootstrap'); return work({ query: async () => ({ rows: [committed] }) });
      },
      record(name, data) { assert.equal(name, 'wire-issuance-ack-loss'); assert.equal(data.wire, receipt); return value; },
    };
    const harness = { restartDatabase: async mode => { assert.equal(mode, 'crash'); events.push('restart'); } };
    const run = providerFixtureFunction('prototypes/access-provider-service/test/owner/fault-cases.mjs', 'runIssuanceAckLoss', {
      assert, performance: { now: () => 0 }, D: () => [], digest: actual => { assert.equal(actual, body); return 'digest'; },
      faultApp: async () => { const index = ++apps; return { installationKey: { fingerprint: 'same' }, close: async () => { events.push('close-' + index); } }; },
      registerArgs: () => ({}),
      prepared() {
        preparations += 1;
        if (scenario === 'prepare-throw') throw original;
        return scenario.startsWith('prepare-') ? Promise.reject(original)
          : Promise.resolve({ challenge: { status: 200 }, data: { challengeId: String(preparations) } });
      },
      issue() { requests += 1; return scenario === 'retry-reject' && requests === 2 ? Promise.reject(original)
        : Promise.resolve(requests === 1 ? { status: 503 } : { status: 201, body }); },
      ownedRace: async (work, options) => {
        assert.equal(options.signal, signal); assert.equal(options.deadline, 5000);
        if (scenario === 'abort') signal.aborted = true;
        if (['receipt-reject', 'already-aborted', 'abort', 'deadline'].includes(scenario)) throw original;
        return work();
      },
      validateAckReceipt(actual, kind) { assert.equal(actual, receipt); assert.equal(kind, 'issuance'); return actual; },
    });
    const result = run({ owner, harness });
    if (scenario === 'success') assert.equal(await result, value);
    else await assert.rejects(result, error => error === original);
    assert.deepEqual(events, ['success', 'retry-reject'].includes(scenario)
      ? ['close-1', 'restart', 'disarm', 'close-2'] : ['disarm', 'close-1']);
  }
});

for (const kind of ['Observation', 'Marker']) {
  test('Provider fixture ' + kind + ' acknowledgement loss preserves both cleanup boundaries', async () => {
    for (const scenario of ['success', 'first-throw', 'race-reject', 'race-non-error', 'second-throw', 'second-close-reject']) {
      const original = scenario === 'race-non-error' ? {} : new Error(scenario);
      const events = [], value = {}, receipt = {}, disconnect = new Error('disconnect');
      const before = { highwater: '10', pending_id: null };
      const after = kind === 'Marker' ? { highwater: '10', pending_id: 'fence' } : { highwater: '11', pending_id: null };
      let stores = 0, reads = 0;
      const signal = {}, context = {}, clock = { now: 10, observe: () => ({ now: 10, uncertaintySeconds: 0 }) };
      const owner = {
        signal, gate: { require: async operation => { assert.equal(operation, 'run-faults'); } },
        proxy: { arm(actual) { assert.equal(actual, kind.toLowerCase()); return Promise.resolve(receipt); }, disarm() { events.push('disarm'); } },
        record(name, data) {
          assert.equal(name, kind === 'Marker' ? 'terminal-wire-marker-fence' : 'wire-observation-ack-loss');
          assert.equal(data.wire, receipt); assert.equal(data.samples, kind === 'Marker' ? 0 : 1); return value;
        },
      };
      const harness = {
        newStore() {
          const index = ++stores;
          return {
            observeTime(actual, sample) {
              assert.equal(actual, context);
              if (scenario === 'first-throw' && index === 1 || scenario === 'second-throw' && index === 2) throw original;
              if (index === 1 && kind === 'Observation') assert.equal(sample().now, 11);
              return Promise.reject(index === 1 ? disconnect : providerFixtureError('CLOCK_UNTRUSTED'));
            },
            close: async () => { events.push('close-' + index); if (scenario === 'second-close-reject' && index === 2) throw original; },
          };
        },
        restartDatabase: async mode => { assert.equal(mode, kind === 'Marker' ? 'crash' : 'clean'); events.push('restart'); },
      };
      const run = providerFixtureFunction('prototypes/access-provider-service/test/owner/fault-cases.mjs', 'run' + kind + 'AckLoss', {
        assert, performance: { now: () => 0 }, context: () => context,
        clockRow: async () => ++reads === 1 ? before : after,
        ownedRace: async (work, options) => {
          assert.equal(options.signal, signal); assert.equal(options.deadline, 5000);
          if (scenario.startsWith('race-')) throw original;
          return work();
        },
        validateAckReceipt(actual, actualKind) { assert.equal(actual, receipt); assert.equal(actualKind, kind.toLowerCase()); return actual; },
        isClockDisconnect: error => error === disconnect,
      });
      const result = run({ owner, harness, bindings: { clock } });
      if (scenario === 'success') assert.equal(await result, value);
      else await assert.rejects(result, error => error === original);
      assert.deepEqual(events, ['success', 'second-throw', 'second-close-reject'].includes(scenario)
        ? ['disarm', 'close-1', 'restart', 'close-2'] : ['disarm', 'close-1']);
    }
  });
}


function providerEventSource() {
  const file = 'prototypes/access-provider-service/test/owner/owner.mjs';
  const source = readFileSync(new URL(file, `file://${root}`), 'utf8');
  let registration, commands;
  const capture = {
    meta: { schema: [] },
    create() {
      return {
        ClassDeclaration(node) { if (node.id.name === 'Commands') commands = source.slice(...node.range); },
        CallExpression(node) {
          const callee = node.callee;
          if (callee.type === 'MemberExpression' && callee.property.name === 'on'
            && callee.object.type === 'MemberExpression' && callee.object.object.name === 'child'
            && callee.object.property.name === 'stdin' && node.arguments[0]?.value === 'error') {
            assert.equal(registration, undefined); registration = source.slice(...node.range);
          }
        },
      };
    },
  };
  const diagnostics = new Linter().verify(source, [{
    files: ['**/*.mjs'], languageOptions: { ecmaVersion: 2022, sourceType: 'module' },
    plugins: { capture: { rules: { owner: capture } } }, rules: { 'capture/owner': 'error' },
  }], { filename: file });
  assert.equal(diagnostics.some(message => message.fatal), false);
  assert.ok(registration); assert.ok(commands);
  return { registration, commands };
}

test('Provider event callback preserves registration, return values and thrown identities', async () => {
  const { registration } = providerEventSource();
  for (const scenario of ['value', 'undefined', 'error-value', 'non-error-value',
    'promise-value', 'promise-reject', 'throw-error', 'throw-non-error']) {
    const original = scenario.includes('non-error') ? { opaque: true } : new Error(scenario);
    const calls = [], registrations = [], token = {};
    const value = scenario === 'undefined' ? undefined
      : scenario === 'promise-value' ? Promise.resolve(original)
        : scenario === 'promise-reject' ? Promise.reject(original) : original;
    if (scenario === 'promise-reject') value.catch(() => {});
    let listener;
    const stdin = {
      on(type, callback) {
        assert.equal(this, stdin); assert.equal(type, 'error');
        registrations.push(type); listener = callback; return token;
      },
    };
    const stop = (...args) => {
      calls.push(args);
      if (scenario.startsWith('throw-')) throw original;
      return value;
    };
    assert.equal(vm.runInNewContext(registration, { child: { stdin }, stop }), token);
    assert.deepEqual(registrations, ['error']); assert.equal(calls.length, 0);
    const eventError = new Error('event input');
    for (const eventValue of [eventError, { opaqueEvent: true }]) {
      if (scenario.startsWith('throw-')) assert.throws(() => listener.call({ receiver: 'ignored by arrow' }, eventValue, 'extra'), error => error === original);
      else assert.equal(listener.call({ receiver: 'ignored by arrow' }, eventValue, 'extra'), value);
    }
    assert.deepEqual(calls, [['OWNER_STDIN'], ['OWNER_STDIN']]);
    if (scenario === 'promise-value') assert.equal(await value, original);
    if (scenario === 'promise-reject') await assert.rejects(value, error => error === original);
  }
});

test('Provider event owner stdin preserves first failure, retirement and terminal cleanup', async () => {
  const { commands: classSource } = providerEventSource();
  for (const scenario of ['success', 'stdin-error', 'abort-then-stdin', 'deadline-then-stdin',
    'stdin-then-abort', 'spawn-then-stdin', 'output-limit-then-stdin', 'synchronous-close', 'unconfirmed']) {
    class OwnerError extends Error { constructor(code) { super(code); this.code = code; } }
    const registrations = [], kills = [], events = [], completions = [], retirements = [];
    const timers = [], cleared = [], controller = new globalThis.AbortController();
    let ready, spawned = 0, removed = 0;
    const started = new Promise(resolve => { ready = resolve; });
    const realRemove = controller.signal.removeEventListener.bind(controller.signal);
    controller.signal.removeEventListener = (...args) => { removed += 1; return realRemove(...args); };
    const child = new EventEmitter();
    const originalOn = child.on;
    child.on = function (type, callback) { registrations.push('child:' + type); return originalOn.call(this, type, callback); };
    for (const name of ['stdin', 'stdout', 'stderr']) {
      const stream = new EventEmitter();
      const on = stream.on;
      stream.on = function (type, callback) { registrations.push(name + ':' + type); return on.call(this, type, callback); };
      child[name] = stream;
    }
    child.stdin.end = value => { assert.equal(value, 'inert-input'); ready(); };
    child.kill = signal => { kills.push(signal); if (scenario === 'synchronous-close') child.emit('close', 1); return true; };
    const owner = {
      signal: controller.signal,
      revalidateCommand: async (_spec, check) => { check(); },
      gate: { require: async () => {}, assertFresh() {} },
      addEvent(event) { events.push(event); },
    };
    const Commands = vm.runInNewContext('(' + classSource + ')', {
      Buffer, OwnerError, MiB: 1024 * 1024, performance: { now: () => 0 },
      spawn() { assert.fail('real spawn is forbidden'); },
      runAuthorizedCommand: async (actualOwner, action, spec, options, start) => {
        assert.equal(actualOwner, owner); assert.equal(action, 'inert-command'); assert.equal(spec.executable, '/inert/command');
        return start({ deadline: options.deadline });
      },
      remainingMilliseconds(deadline) { assert.ok(deadline > 0); return deadline; },
      refuse(code) { throw new OwnerError(code); },
      ownedRace: async (work, options) => {
        assert.equal(options.signal, controller.signal); assert.equal(options.deadline, 100);
        return work();
      },
      setTimeout(callback, delay) { const timer = { callback, delay }; timers.push(timer); return timer; },
      clearTimeout(timer) { if (timer !== undefined) cleared.push(timer); },
    });
    const commands = new Commands(owner, (executable, args, options) => {
      spawned += 1; assert.equal(executable, '/inert/command'); assert.equal(args.length, 0); assert.equal(options.shell, false);
      return child;
    }, (action, result) => { completions.push({ action, result }); },
    (action, error) => { retirements.push({ action, error }); });
    let settled = false;
    const observed = commands.run('inert-command', {
      executable: '/inert/command', args: [], env: {}, stdin: 'inert-input',
    }, { deadline: 100 }).then(value => { settled = true; return { value }; }, error => { settled = true; return { error }; });
    await started;
    assert.equal(spawned, 1); assert.equal(commands.children.size, 1);
    assert.deepEqual(registrations, ['stdout:data', 'stderr:data', 'stdin:error', 'child:error', 'child:close']);
    assert.equal(child.stdin.listenerCount('error'), 1); assert.equal(child.listenerCount('error'), 1);
    if (scenario === 'success') {
      child.stdout.emit('data', Buffer.from('out')); child.stderr.emit('data', Buffer.from('err')); child.emit('close', 0);
    } else {
      if (scenario === 'abort-then-stdin') controller.abort(new Error('abort reason'));
      if (scenario === 'deadline-then-stdin') timers[0].callback();
      if (scenario === 'spawn-then-stdin') child.emit('error', new Error('spawn reason'));
      if (scenario === 'output-limit-then-stdin') child.stdout.emit('data', Buffer.alloc(2 * 1024 * 1024 + 1));
      child.stdin.emit('error', new Error('first stdin event'));
      child.stdin.emit('error', { opaqueEvent: true });
      if (scenario === 'stdin-then-abort') controller.abort(new Error('later abort'));
      assert.deepEqual(kills, ['SIGTERM']);
      if (scenario === 'unconfirmed') {
        assert.equal(timers[1].delay, 1000); timers[1].callback();
        assert.deepEqual(kills, ['SIGTERM', 'SIGKILL']);
        assert.equal(timers[2].delay, 1000); timers[2].callback(); timers[2].callback();
        const retained = await observed;
        assert.equal(retained.error.code, 'OWNER_CHILD_STOP_UNCONFIRMED');
        assert.equal(retained.error.initiatingCode, 'OWNER_STDIN');
        assert.equal(retirements.length, 1); assert.equal(retirements[0].error, retained.error);
        assert.equal(commands.children.size, 1);
        child.emit('close', 1);
      } else if (scenario !== 'synchronous-close') {
        assert.equal(settled, false); child.emit('close', 1);
      }
    }
    const result = await observed;
    if (scenario === 'success') {
      assert.deepEqual({ ...result.value }, { stdout: 'out', stderr: 'err' });
      assert.equal(completions.length, 1); assert.equal(completions[0].result, result.value); assert.deepEqual(kills, []);
    } else {
      const expected = {
        'abort-then-stdin': 'OWNER_CANCELLED', 'deadline-then-stdin': 'OWNER_COMMAND_DEADLINE',
        'spawn-then-stdin': 'OWNER_SPAWN', 'output-limit-then-stdin': 'OWNER_OUTPUT_LIMIT',
        unconfirmed: 'OWNER_CHILD_STOP_UNCONFIRMED',
      }[scenario] ?? 'OWNER_STDIN';
      assert.ok(result.error instanceof OwnerError); assert.equal(result.error.code, expected);
      assert.equal(completions.length, 0);
    }
    assert.equal(commands.children.size, 0); assert.equal(removed, 1);
    assert.equal(events.filter(event => Object.hasOwn(event, 'exitCode')).length, 1);
    assert.equal(new Set(cleared).size, timers.length); assert.equal(cleared.length, timers.length);
    const before = { kills: kills.length, events: events.length, removed };
    child.emit('close', 1);
    assert.deepEqual({ kills: kills.length, events: events.length, removed }, before);
  }
});
