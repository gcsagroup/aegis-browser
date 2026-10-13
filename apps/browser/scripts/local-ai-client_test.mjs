// 取消后旧 Worker 的排队消息不能影响下一次任务和超时回收。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const source = readFileSync(new URL('../overlay/chrome/browser/resources/aegis_agent/local_ai_client.ts', import.meta.url), 'utf8');
const compiled = ts.transpileModule(source, {compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS}}).outputText;
const workers = [], timers = new Map();
let serial = 0;
class Worker {
  constructor(url, options) {
    assert.equal(url, './local_ai/worker.js'); assert.equal(options.type, 'module');
    workers.push(this);
  }
  terminate() { this.terminated = true; }
  postMessage(request) { this.request = request; }
}
const exports = {};
vm.runInNewContext(compiled, {exports, Worker, window: {
  setTimeout: callback => { const id = ++serial; timers.set(id, callback); return id; },
  clearTimeout: id => timers.delete(id),
}, require: () => ({getTrustedScriptURL: strings => strings[0]})});
const client = new exports.LocalAiClient();
const first = client.run({op: 'download'}, () => {});
client.cancel();
await assert.rejects(first, /cancelled/);
assert.equal(workers[0].terminated, true);
assert.equal(timers.size, 0);
const progress = [];
const second = client.run({op: 'status'}, text => progress.push(text));
workers[0].onmessage({data: {result: {ready: true}}});
assert.equal(timers.size, 1, '旧消息不能清理新任务的超时');
workers[1].onmessage({data: {progress: 'download:50'}});
assert.deepEqual(progress, ['download:50']);
workers[1].onmessage({data: {result: {ready: false}}});
assert.equal((await second).ready, false);
assert.equal(timers.size, 0);
assert.equal(workers[1].terminated, true);
const third = client.run({op: 'translate'}, () => {});
timers.values().next().value();
await assert.rejects(third, /runtime_timeout/);
assert.equal(workers[2].terminated, true);
assert.equal(timers.size, 0);
console.log('本机 Worker 回归通过：主动取消、旧消息隔离、正常回收与超时终止。');
