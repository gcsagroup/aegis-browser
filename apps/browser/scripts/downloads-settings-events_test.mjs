import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import vm from 'node:vm';

// Run against owned macOS-preprocessed inputs with the caller's pinned tools.
// Real Lit + jsdom exercise event binding; Chromium controls/proxy are fixtures.
const options = Object.fromEntries(process.argv.slice(2).map(arg => {
  const separator = arg.indexOf('=');
  assert.ok(separator > 2, `Expected --name=path: ${arg}`);
  return [arg.slice(2, separator), arg.slice(separator + 1)];
}));
for (const name of ['source-dir', 'typescript', 'jsdom', 'lit']) {
  assert.ok(options[name], `Missing --${name}`);
}
const require = createRequire(import.meta.url);
const ts = require(options.typescript);
const {JSDOM} = require(options.jsdom);
const dom = new JSDOM('<!doctype html><html lang="en"><body></body></html>', {
  url: 'https://settings.invalid/',
});
for (const name of ['window', 'document', 'HTMLElement', 'HTMLSelectElement',
  'Document', 'DocumentFragment', 'Node', 'Event', 'CustomEvent', 'customElements',
  'ShadowRoot', 'CSSStyleSheet']) {
  globalThis[name] = dom.window[name];
}
const {html, render} = await import(pathToFileURL(options.lit).href);
const initial = {
  parallelMode: 0, reduceOnMetered: true, reduceOnBattery: true,
  torrentDhtEnabled: true, torrentPexEnabled: true,
  torrentDownloadLimitKib: 0, torrentUploadLimitKib: 256,
};
let stored = {...initial};
let rejectSave = false;
let rejectRead = false;
const writes = [];
let reads = 0;
let selections = 0;
let resets = 0;
const proxy = {
  selectDownloadLocation() { selections++; },
  resetAutoOpenFileTypes() { resets++; },
  getAegisDownloadSettings() {
    reads++;
    return rejectRead ? Promise.reject(Error('read fixture')) :
      Promise.resolve({...stored});
  },
  async setAegisDownloadSettings(next, expected) {
    writes.push({next: {...next}, expected: {...expected}});
    if (rejectSave) throw Error('save fixture');
    assert.deepEqual({...expected}, stored);
    stored = {...next};
    return {...stored};
  },
};
class CrLitElementFixture extends dom.window.HTMLElement {}
const imports = {
  'chrome://resources/lit/v3_0/lit.rollup.js': {html, CrLitElement: CrLitElementFixture},
  'chrome://resources/cr_elements/web_ui_listener_mixin_lit.js': {
    WebUiListenerMixinLit: base => base,
  },
  '../settings.js': {PrefServiceObserverMixinLit: base => base},
  '../i18n_setup.js': {loadTimeData: {getBoolean: () => true}},
  './downloads_browser_proxy.js': {DownloadsBrowserProxyImpl: {getInstance: () => proxy}},
  './downloads_page.css.js': {getCss: () => []},
};
function load(filename) {
  const source = readFileSync(join(options['source-dir'], filename), 'utf8');
  const result = ts.transpileModule(source, {
    fileName: filename,
    compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS},
    reportDiagnostics: true,
  });
  assert.equal(result.diagnostics?.length ?? 0, 0);
  const exports = {};
  vm.runInNewContext(result.outputText, {
    exports, require: specifier => imports[specifier] ?? {},
    document, customElements, HTMLSelectElement, console,
  }, {filename});
  return exports;
}
imports['./downloads_page.html.js'] = load('downloads_page.html.ts');
const {SettingsDownloadsPageElement} = load('downloads_page.ts');
const calls = [];
for (const name of ['onChangeDownloadsPathClick_', 'onClearAutoOpenFileTypesClick_',
  'onAegisRetryClick_', 'onAegisParallelModeChange_', 'onAegisToggleChange_',
  'onAegisLimitModeChange_', 'onAegisLimitChange_']) {
  const original = SettingsDownloadsPageElement.prototype[name];
  assert.equal(typeof original, 'function');
  SettingsDownloadsPageElement.prototype[name] = function(event) {
    calls.push({name, receiver: this, event, target: event?.target,
      currentTarget: event?.currentTarget});
    return original.call(this, event);
  };
}
const page = new SettingsDownloadsPageElement();
page.autoOpenDownloads_ = true;
page.aegisOnly = true;
const container = document.createElement('div');
const redraw = () => render(page.render(), container, {host: page});
redraw();
const control = selector => {
  const element = container.querySelector(selector);
  assert.ok(element, selector);
  return element;
};
function dispatch(selector, name, eventName, changes = {}, nested = false) {
  const element = control(selector);
  Object.assign(element, changes);
  const target = nested ? element.appendChild(document.createElement('span')) : element;
  const event = new dom.window.Event(eventName, {bubbles: true});
  const before = calls.length;
  target.dispatchEvent(event);
  assert.equal(calls.length, before + 1);
  const call = calls.at(-1);
  assert.equal(call.name, name);
  assert.equal(call.receiver, page, 'Lit must supply the component as this');
  assert.equal(call.event, event, 'original Event identity must survive binding');
  assert.equal(call.target, target);
  assert.equal(call.currentTarget, element);
}
async function settle() {
  await page.aegisSaveChain_;
  for (let i = 0; i < 8; i++) await Promise.resolve();
  redraw();
}
const retry = 'cr-button:not([id])';
dispatch('#changeDownloadsPath', 'onChangeDownloadsPathClick_', 'click');
dispatch('#resetAutoOpenFileTypes', 'onClearAutoOpenFileTypesClick_', 'click');
assert.equal(selections, 1);
assert.equal(resets, 1);
dispatch(retry, 'onAegisRetryClick_', 'click');
await settle();
assert.equal(page.aegisSettingsReady_, true);
assert.equal(reads, 1);
dispatch('select:not([id])', 'onAegisParallelModeChange_', 'change', {value: '6'});
await settle();
assert.equal(stored.parallelMode, 6);
for (const [id, key] of [
  ['aegisReduceOnMetered', 'reduceOnMetered'],
  ['aegisReduceOnBattery', 'reduceOnBattery'],
  ['aegisTorrentDhtEnabled', 'torrentDhtEnabled'],
  ['aegisTorrentPexEnabled', 'torrentPexEnabled'],
]) {
  dispatch(`#${id}`, 'onAegisToggleChange_', 'change', {checked: false}, true);
  await settle();
  assert.equal(stored[key], false, 'toggle must read currentTarget, not bubbled target');
}
for (const [kind, key, other, value] of [
  ['Download', 'torrentDownloadLimitKib', 'torrentUploadLimitKib', '123'],
  ['Upload', 'torrentUploadLimitKib', 'torrentDownloadLimitKib', '456'],
]) {
  const untouched = stored[other];
  dispatch(`#aegis${kind}Mode`, 'onAegisLimitModeChange_', 'change', {value: 'custom'});
  await settle();
  assert.equal(stored[key], 256);
  assert.equal(stored[other], untouched);
  const input = `#aegisTorrent${kind}Limit`;
  const writeCount = writes.length;
  for (const invalid of ['', '0', '1.5', '1000001']) {
    dispatch(input, 'onAegisLimitChange_', 'change', {value: invalid});
    await settle();
    assert.equal(control(input).invalid, true);
    assert.equal(writes.length, writeCount, 'invalid limit must not save');
  }
  dispatch(input, 'onAegisLimitChange_', 'change', {value});
  await settle();
  assert.equal(control(input).invalid, false);
  assert.equal(stored[key], Number(value));
  assert.equal(stored[other], untouched);
  dispatch(`#aegis${kind}Mode`, 'onAegisLimitModeChange_', 'change', {value: 'unlimited'});
  await settle();
  assert.equal(stored[key], 0);
}
// Rapid selection changes must retain serialized writes and latest selection.
dispatch('select:not([id])', 'onAegisParallelModeChange_', 'change', {value: '1'});
dispatch('select:not([id])', 'onAegisParallelModeChange_', 'change', {value: '3'});
await settle();
assert.equal(stored.parallelMode, 3);
assert.equal(page.aegisSaveStatus_, page.aegisStrings_.saved);
const beforeFailure = {...stored};
rejectSave = true;
rejectRead = true;
dispatch('select:not([id])', 'onAegisParallelModeChange_', 'change', {value: '6'});
await settle();
assert.deepEqual(stored, beforeFailure);
assert.equal(page.aegisSettingsReady_, false);
assert.equal(page.aegisSaveStatus_, page.aegisStrings_.failed);
assert.equal(control(retry).hidden, false);
rejectRead = false;
rejectSave = false;
dispatch(retry, 'onAegisRetryClick_', 'click');
await settle();
assert.equal(page.aegisSettingsReady_, true);
assert.equal(page.aegisParallelMode_, beforeFailure.parallelMode);
dispatch('select:not([id])', 'onAegisParallelModeChange_', 'change', {value: '1'});
await settle();
assert.equal(stored.parallelMode, 1);
assert.equal(page.aegisSaveStatus_, page.aegisStrings_.saved);
console.log(JSON.stringify({status: 'PASS', eventDispatches: calls.length,
  writes: writes.length, reads, coverage: ['three click bindings', 'select',
    'four toggles with bubbled target', 'Download and Upload mode/input',
    'invalid input', 'rapid selection', 'save/read failure', 'retry recovery'],
  nativeAcceptance: false}));
dom.window.close();
