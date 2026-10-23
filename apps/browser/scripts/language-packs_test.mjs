// 执行语言包管理器的真实 DOM；状态失败、队列取消和正文翻译互不影响。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import {JSDOM} from 'jsdom';
import * as catalog from '../overlay/chrome/browser/resources/aegis_agent/local_ai/catalog.js';
const base = new URL('../overlay/chrome/browser/resources/aegis_agent/', import.meta.url);
const manifest = JSON.parse(readFileSync(new URL('local_ai/translation_manifest.json', base)));
const packs = catalog.languagePacks(manifest), routes = catalog.translationRoutes(packs);
assert.equal(packs.length, 14); assert.equal(routes.length, 24);
for (const withheld of ['ja-zh', 'zh-de']) assert.equal(routes.some(route => route.id === withheld), false, '未通过质量检查的中转方向不开放');
assert.equal(routes.find(route => route.id === 'zh-fr').packs.join(','), 'zh-en,en-fr');
assert.equal(catalog.detectSource('日本語の文章です。'), 'ja');
assert.equal(catalog.detectSource('한국어 문장입니다.'), 'ko');
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const compiled = ts.transpileModule(readFileSync(new URL('language_packs.ts', base), 'utf8'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS},
}).outputText;
const dom = new JSDOM('<main id="packs"></main><select id="direction"></select>', {url: 'https://fixture.invalid'});
const {window} = dom, {document} = window;
window.HTMLElement.prototype.scrollIntoView = () => {};
window.confirm = () => true;
const calls = [], clients = [], channels = [];
let readFailure = true, operation = null, locale = 'zh-CN';
const installed = new Map(packs.map(pack => [pack.id, {id: pack.id, ready: false, update: false}]));
class Client {
  constructor() { clients.push(this); }
  run(request, progress) {
    calls.push(request);
    if (request.op === 'statuses') return readFailure ? Promise.reject(Error('storage_unavailable')) : Promise.resolve({statuses: [...installed.values()]});
    return new Promise((resolve, reject) => { this.reject = reject; operation = {request, progress, resolve, reject}; });
  }
  cancel() { this.reject?.(Error('cancelled')); }
}
class Channel {
  constructor() { channels.push(this); }
  postMessage() {} close() {}
}
const exports = {};
vm.runInNewContext(compiled, {exports, Error, document, window, localStorage: window.localStorage,
  BroadcastChannel: Channel, fetch: async () => ({ok: true, json: async () => manifest}),
  require: name => name.includes('catalog') ? catalog : name.includes('local_ai_client') ? {LocalAiClient: Client} : {loadTimeData: {getString: key => { assert.equal(key, 'aegisLocale'); return locale; }}},
});
// Chromium 的默认 language 只返回 zh，专用 locale 必须保留地区。
for (const [current, expected] of [['zh-CN', '简体'], ['zh-TW', '繁體'], ['zh-Hant', '繁體'], ['zh-HK', '繁體'], ['en-US', 'English']]) {
  locale = current; assert.equal(exports.packText('简体', 'English', '繁體'), expected);
}
locale = 'zh-CN';
const root = document.getElementById('packs'), manager = new exports.LanguagePacks(root);
const flush = () => new Promise(resolve => setImmediate(resolve));
const button = (text, area = root) => [...area.querySelectorAll('button')].find(node => node.textContent === text);
const row = id => root.querySelector(`[data-pack="${id}"]`);
await manager.loaded;
assert.equal(root.querySelectorAll('.language-pack-row').length, 14);
assert.equal(button('下载', row('en-fr')).disabled, true, '安装状态失败不能当未安装');
assert.equal(button('移除', row('en-fr')).disabled, true);
assert.match(root.textContent, /安装状态未确认/);
readFailure = false; button('重试').click(); await flush();
assert.equal(button('下载', row('en-fr')).disabled, false);
button('选择双向', row('en-fr')).click();
assert.equal(root.querySelectorAll('input:checked').length, 2);
button('下载所选语言包').click(); await flush();
assert.equal(operation.request.direction, 'en-fr');
const progressNode = row('en-fr').querySelector('[role="status"]');
operation.progress('download:42');
assert.equal(row('en-fr').querySelector('[role="status"]'), progressNode, '进度不重建 DOM 或打断焦点');
assert.match(progressNode.textContent, /42%/);
button('取消剩余下载').click(); await flush();
assert.equal(calls.filter(call => call.op === 'download').length, 1, '取消不继续下一个包');
assert.match(row('en-fr').textContent, /已取消/);
button('重试下载', row('en-fr')).click(); await flush();
operation.resolve({ready: true}); await flush();
assert.match(row('en-fr').textContent, /可用/);
assert.equal(button('移除', row('en-fr')).disabled, false);
button('移除', row('en-fr')).click(); await flush();
assert.equal(operation.request.op, 'remove'); operation.reject(Error('storage_unavailable')); await flush();
assert.match(row('en-fr').textContent, /移除失败/);
assert.equal(button('移除', row('en-fr')).disabled, false, '删除失败保留可用状态');
installed.set('en-fr', {id: 'en-fr', ready: true, update: true});
channels[0].onmessage(); await flush();
button('更新', row('en-fr')).click(); await flush(); operation.reject(Error('download_failed')); await flush();
assert.match(row('en-fr').textContent, /原有版本保留/);
assert.equal(button('移除', row('en-fr')).disabled, false);
await manager.showRoute('zh-fr');
assert.equal(root.querySelectorAll('input:checked').length, 2);
const select = document.getElementById('direction'); await manager.fillDirections(select, '한국어 문장입니다.');
assert.equal(select.value, 'ko-zh');
assert.equal(select.options.length, 24);
assert.notEqual(clients[0], clients[1], '安装与读取状态使用独立任务实例');
console.log('语言目录和真实 DOM 回归通过：24 个方向、读取失败重试、双向队列、取消、更新回退、移除失败与方向定位。');
