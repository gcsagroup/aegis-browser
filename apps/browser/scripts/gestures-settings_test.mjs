// 在真实 DOM 中操作手势表单和指针事件，验证保存边界、取消与并发草稿。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import {JSDOM} from 'jsdom';
const base = resolve(dirname(fileURLToPath(import.meta.url)), '../overlay/chrome/browser/resources/aegis/');
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const source = readFileSync(resolve(base, 'gestures.ts'), 'utf8').split("if (document.getElementById('practice'))")[0];
const code = ts.transpileModule(source, {compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS}}).outputText;
const defaults = {enabled: true, showTrail: true, threshold: 24, bindings: {L: 'back'}, disabledSites: []};
const actions = [{id: 'back', label: '后退', pdfOnly: false}, {id: 'forward', label: '前进', pdfOnly: false}, {id: 'close_tab', label: '关闭标签页', pdfOnly: false}];
const flush = () => new Promise(resolve => setImmediate(resolve));
async function harness(failedRead = false, useShadow = false) {
  const dom = new JSDOM(readFileSync(resolve(base, 'gestures.html'), 'utf8'));
  const {window} = dom, {document} = window;
  let saved = structuredClone(defaults), pending = null, hold = false;
  const calls = [], regions = [], dirty = [], exports = {};
  const snapshot = () => ({settings: structuredClone(saved), defaults: structuredClone(defaults), actions});
  const send = async (method, next, expected) => {
    if (method === 'aegisGetGestureSettings') { if (failedRead) throw Error('读取失败'); return snapshot(); }
    calls.push({next: structuredClone(next), expected: structuredClone(expected)});
    if (JSON.stringify(expected) !== JSON.stringify(saved)) throw Error('配置已在另一页面修改');
    if (hold) return new Promise((resolve, reject) => { pending = {resolve: () => {saved = next; resolve(snapshot());}, reject}; });
    saved = next; return snapshot();
  };
  const practice = document.getElementById('practice');
  practice.setPointerCapture = () => {};
  practice.getBoundingClientRect = () => ({left: 0, top: 0, width: 700, height: 300, right: 700, bottom: 300});
  vm.runInNewContext(code, {exports, document, window, Error, structuredClone,
    Option: window.Option, ShadowRoot: window.ShadowRoot, CustomEvent: window.CustomEvent,
    AbortController: window.AbortController, queueMicrotask: globalThis.queueMicrotask, confirm: () => true, URL,
    innerWidth: 1000, innerHeight: 800, requestAnimationFrame: callback => callback(),
    ResizeObserver: class {observe() {} disconnect() {}}, chrome: {send: (...args) => regions.push(args)},
    require: () => ({sendWithPromise: send}),
  });
  let view = document;
  if (useShadow) {
    const nodes = [...document.body.children], host = document.createElement('div');
    document.body.append(host); view = host.attachShadow({mode: 'open'}); view.append(...nodes);
    host.addEventListener('aegis-form-dirty', event => dirty.push(event.detail));
  }
  const cleanup = exports.initializeGestures(view); await flush();
  return {window, document: view, calls, regions, dirty, cleanup, get saved() {return saved;},
    get pending() {return pending;}, hold: () => {hold = true;}, goodRead: () => {failedRead = false;},
    el: id => view.getElementById(id),
  };
}
const h = await harness();
const event = (node, type, init = {}) => node.dispatchEvent(new h.window.Event(type, {bubbles: true, cancelable: true, ...init}));
const click = node => node.click();
const button = (root, name) => [...root.querySelectorAll('button')].find(node => node.textContent === name);
const binding = h.document.querySelector('[data-pattern="L"]');
click(button(binding, '编辑')); const select = binding.querySelector('select'); select.value = 'forward'; event(select, 'change');
click(h.document.querySelector('[data-direction="U"]')); click(h.document.querySelector('[data-direction="D"]'));
assert.equal(h.el('practiceAction').value, ''); assert.equal(h.el('savePractice').disabled, true, '新增方向不预选破坏性动作');
h.el('practiceAction').value = 'close_tab'; event(h.el('practiceAction'), 'change'); click(h.el('savePractice')); await flush();
assert.match(h.el('practiceResult').textContent, /已绑定/);
assert.equal(h.calls.length, 1); assert.equal(h.saved.bindings.UD, 'close_tab');
assert.equal(h.saved.bindings.L, 'back', '新增手势不能偷偷保存另一行草稿');
assert.equal(h.document.querySelector('[data-pattern="L"] select').value, 'forward', '保存回包保留另一行编辑');
assert.deepEqual(Object.keys(h.saved.bindings), ['L', 'UD']);
const selected = h.el('practiceAction');
h.window.dispatchEvent(new h.window.KeyboardEvent('keydown', {key: 'Escape'}));
assert.equal(h.el('practice-editor').hidden, true); assert.equal(h.el('savePractice').disabled, true);
// 真实右键绘制路径只产生编辑结果，不发出浏览器动作或保存请求。
const pointer = (type, x, y) => h.el('practice').dispatchEvent(new h.window.MouseEvent(type, {button: 2, buttons: type === 'pointerup' ? 0 : 2, clientX: x, clientY: y, bubbles: true, cancelable: true}));
pointer('pointerdown', 120, 150); pointer('pointermove', 40, 150); pointer('pointerup', 40, 150);
assert.match(h.el('practicePattern').textContent, /←/); assert.equal(h.el('practiceAction').value, 'back');
assert.equal(h.calls.length, 1); assert(h.regions.every(call => call[0] === 'aegisGesturePracticeRegion'));
h.window.dispatchEvent(new h.window.Event('blur')); assert.equal(h.el('savePractice').disabled, true);
pointer('pointerdown', 120, 150); pointer('pointerup', 124, 150); assert.equal(h.el('savePractice').disabled, true);
// 保存等待期间其他组的新输入不被回包覆盖；失败后保留重试入口。
h.hold(); click(h.document.querySelector('[data-direction="R"]')); selected.value = 'forward'; event(selected, 'change'); click(h.el('savePractice')); await flush();
assert.equal(h.el('practiceAction').disabled, true); click(h.el('savePractice')); assert.equal(h.calls.length, 2);
h.pending.reject(Error('保存失败')); await flush();
assert.equal(h.el('practiceAction').value, 'forward'); assert.match(h.el('practice-status').textContent, /保存失败/);
assert.equal(h.el('savePractice').disabled, false); click(h.el('savePractice')); await flush(); h.pending.resolve(); await flush();
assert.equal(h.saved.bindings.R, 'forward');
h.cleanup();
const failed = await harness(true);
assert.equal(failed.el('enabled').disabled, true); assert.equal(failed.el('reloadSettings').hidden, false);
assert.equal(failed.el('reloadSettings').disabled, false, '读取失败后必须能点击重试');
failed.goodRead(); failed.el('reloadSettings').click(); await flush();
assert.equal(failed.el('enabled').disabled, false); failed.cleanup();

// 两处同时编辑时，后一个提交必须使用前一个成功回包作为基线；失败不清草稿。
const queued = await harness(false, true);
const queuedEvent = node => node.dispatchEvent(new queued.window.Event('change', {bubbles: true}));
const first = queued.document.querySelector('[data-pattern="L"]');
click(button(first, '编辑'));
first.querySelector('select').value = 'forward'; queuedEvent(first.querySelector('select'));
queued.hold(); click(button(first, '保存')); await flush();
assert.deepEqual(queued.calls[0].expected.bindings, {L: 'back'});
click(queued.document.querySelector('[data-direction="U"]')); click(queued.document.querySelector('[data-direction="D"]'));
queued.el('practiceAction').value = 'close_tab'; queuedEvent(queued.el('practiceAction')); click(queued.el('savePractice')); await flush();
assert.equal(queued.calls.length, 1, '第二处保存必须排队');
queued.pending.resolve(); await flush();
assert.equal(queued.calls.length, 2);
assert.deepEqual(queued.calls[1].expected.bindings, {L: 'forward'});
assert.deepEqual(queued.calls[1].next.bindings, {L: 'forward', UD: 'close_tab'});
queued.pending.reject(Error('保存失败')); await flush();
assert.deepEqual(structuredClone(queued.saved.bindings), {L: 'forward'});
assert.equal(queued.el('practiceAction').value, 'close_tab');
assert.equal(queued.dirty.at(-1), true, '未保存动作仍触发离页保护');
click(queued.el('savePractice')); await flush(); queued.pending.resolve(); await flush();
assert.deepEqual(structuredClone(queued.saved.bindings), {L: 'forward', UD: 'close_tab'});
assert.equal(queued.dirty.at(-1), false, '成功回读后不保留过期脏状态');
const removed = queued.document.querySelector('[data-pattern="UD"]');
click(button(removed, '移除')); await flush(); queued.pending.resolve(); await flush();
assert.equal(Object.hasOwn(queued.saved.bindings, 'UD'), false);
click(queued.el('undoBinding')); await flush(); queued.pending.resolve(); await flush();
assert.deepEqual(structuredClone(queued.saved.bindings), {L: 'forward', UD: 'close_tab'});
queued.cleanup();
console.log('手势真实 DOM 回归通过：绘制、取消、分组草稿、串行基线、失败重试、撤销、脏状态和初读失败。');
