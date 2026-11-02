// Run the production client and Worker dispatcher against owned browser-API
// doubles. This is a JavaScript contract test, not native Worker/IndexedDB proof.
import assert from 'node:assert/strict';
import {stripTypeScriptTypes} from 'node:module';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';
import vm from 'node:vm';

export async function checkPublicLocalAiClient({root, analyze}) {
  const read = name => readFileSync(new URL(name, root), 'utf8');
  const trustedImport = "import {getTrustedScriptURL} from '//resources/js/static_types.js';";
  const source = read('../local_ai_client.ts');
  assert.ok(source.includes(trustedImport), 'test must load the production client import');
  // Node strips type syntax only. The run/cancel/message/timeout logic remains
  // the actual production class; no test PublicClient replaces it.
  const clientJS = stripTypeScriptTypes(source.replace(trustedImport, ''))
      .replace('export class LocalAiClient', 'class LocalAiClient');
  const worker = read('worker.js');
  assert.ok(worker.includes("await import('./research.js')"),
      'research must use the production Worker dispatcher');
  const workerJS = worker
      .replace("import {decompress} from './vendor/fzstd.js';", '')
      .replace("import {languagePacks, routePacks} from './catalog.js';", '')
      .replaceAll('import.meta.url', JSON.stringify(root.href))
      .replace("await import('./research.js')", '({analyze: fixtureAnalyze})')
      .replace(/^export \{[^\n]+\};?$/gm, '').replaceAll('export ', '');
  const catalogJS = read('catalog.js').replaceAll('export ', '');
  const translationRows = JSON.parse(read('translation_manifest.json'));
  async function scenario(fault = '') {
    const requests = [], workers = [], timers = new Set();
    let opened = 0, closed = 0;
    const indexedDB = {open(name, version) {
      assert.equal(name, 'aegis-local-translation-v1'); assert.equal(version, 2);
      const request = {};
      queueMicrotask(() => {
        ++opened;
        request.result = {transaction(store) {
          assert.ok(['files', 'packs'].includes(store));
          return {objectStore(actual) {
            assert.equal(actual, store);
            return {get() {
              const result = {};
              queueMicrotask(() => result.onsuccess());
              return result; // Empty installed store: actual installed() decides status.
            }};
          }};
        }, close() { ++closed; }};
        request.onsuccess();
      });
      return request;
    }};
    class WorkerFixture {
      constructor(url, options) {
        assert.equal(url, './local_ai/worker.js'); assert.equal(options.type, 'module');
        workers.push(this); this.terminated = false;
        const self = {postMessage: data => {
          // Inject only at the owned platform boundary, after real execute().
          if (fault === 'status-ready' && this.request.op === 'status') data = {result: {ready: true}};
          if (fault === 'research-resolves' && this.request.op === 'research') data = {result: {}};
          if (fault === 'wrong-research-error' && this.request.op === 'research') data = {error: 'runtime_unavailable'};
          if (fault === 'missing-result') data = {};
          this.onmessage({data});
        }};
        this.context = vm.createContext({self, indexedDB, fixtureAnalyze: analyze,
          console, TextEncoder, TextDecoder, URL, crypto: webcrypto,
          fetch: async url => {
            assert.equal(new URL(url).pathname.split('/').at(-1), 'translation_manifest.json',
                'status can only read the real translation manifest');
            return {json: async () => translationRows};
          }});
        vm.runInContext(catalogJS + '\n' + workerJS, this.context);
      }
      postMessage(request) {
        this.request = request; requests.push(JSON.parse(JSON.stringify(request)));
        queueMicrotask(() => { void this.context.self.onmessage({data: request}); });
      }
      terminate() { this.terminated = true; }
    }
    const browser = vm.createContext({Worker: WorkerFixture, crypto: webcrypto,
      getTrustedScriptURL: parts => parts[0],
      window: {setTimeout: (fn, ms) => { const id = setTimeout(fn, ms); timers.add(id); return id; },
        clearTimeout: id => { clearTimeout(id); timers.delete(id); }}});
    const Client = vm.runInContext(clientJS + '\nLocalAiClient;', browser);
    const client = new Client();
    try {
      const status = async () => {
        const value = await client.run({op: 'status', direction: 'en-zh'}, () => assert.fail('unexpected progress'));
        assert.equal(value.ready, false, 'public status must stay unavailable');
        assert.equal(value.update, false, 'empty installed store has no update');
      };
      await status();
      for (const [minim, phishlang] of [[true, false], [false, true], [true, true]]) {
        await assert.rejects(client.run({op: 'research', paragraphs: ['普通正文'],
          minim, phishlang, goal: '阅读'}, () => assert.fail('cannot start inference')),
        /research_model_not_distributed/);
      }
      await status();
      assert.deepEqual(requests.map(r => r.op), ['status', 'research', 'research', 'research', 'status']);
      assert.deepEqual(requests.filter(r => r.op === 'research').map(r => [r.minim, r.phishlang]),
          [[true, false], [false, true], [true, true]]);
      assert.equal(workers.length, 5, 'every actual client task owns a new Worker');
      assert.ok(opened > 0, 'status must traverse actual Worker installed-store reads');
    } catch (error) {
      throw error;
    } finally {
      client.cancel();
      assert.equal(timers.size, 0, 'production finish/cancel must clear every task timer');
      assert.ok(workers.every(value => value.terminated), 'production client must terminate every Worker');
      assert.equal(closed, opened, 'all owned storage connections must close');
    }
  }
  await scenario();
  return async () => {
    await assert.rejects(scenario('status-ready'), /public status must stay unavailable/);
    await assert.rejects(scenario('research-resolves'), /Missing expected rejection/);
    await assert.rejects(scenario('wrong-research-error'), /runtime_unavailable/);
    await assert.rejects(scenario('missing-result'), /invalid_result/);
  };
}
