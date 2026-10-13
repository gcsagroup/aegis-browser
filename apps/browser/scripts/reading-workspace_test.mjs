// 在真实 DOM 中执行阅读模块，覆盖惰性文本、授权、搜索、保存冲突与编辑保留。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
import {JSDOM} from 'jsdom';
const root = fileURLToPath(new URL('../../../', import.meta.url));
const ts = createRequire(root + '/packages/core/package.json')('typescript');
const base = root + '/apps/browser/overlay/chrome/browser/resources/aegis_agent/';
const dom = new JSDOM(readFileSync(base + 'agent.html', 'utf8'));
const {document} = dom.window;
const code = ts.transpileModule(readFileSync(base + 'reading_workspace.ts', 'utf8'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS},
}).outputText;
const exports = {};
const localCalls = [];
let localReply = {ready: false};
class LocalAiClient {
  async run(request) { localCalls.push(request); return localReply; }
  cancel() {}
}
vm.runInNewContext(code, {exports, document, window: dom.window,
  require: name => name.includes('local_ai_client') ? {LocalAiClient} : {loadTimeData: {getString: name => name}}});
const fixture = {id: 'a', url: 'https://fixture.invalid/article', title: '<img src=x onerror=alert(1)>',
  kind: 'web', page: 0, text: '原文与唯一关键词', note: '批注', quote: '原文', group: '项目甲',
  paragraphs: ['原文与唯一关键词'], translation: ['unique translation'], language: 'en', archived: false, created: '1'};
assert.equal(exports.matchesReading(fixture, 'UNIQUE TRANSLATION'), true);
assert.equal(exports.matchesReading(fixture, '唯一关键词'), true);
assert.equal(exports.matchesReading(fixture, '不存在'), false);
const warnings = (source, target) => Array.from(exports.translationWarnings(source, target));
assert.deepEqual(warnings('金额为人民币1,234.56元。', 'The amount is RMB 1,234.36.'), ['NumberWarning']);
assert.deepEqual(warnings('价格为85元。', 'The price is $85.'), ['UnitWarning']);
assert.deepEqual(warnings('Keep 12.5 MB.', '保留12.50 MB。'), []);
assert.deepEqual(warnings('2026-10-13: 30%', '2026年10月13日：30%'), []);
assert.deepEqual(warnings('The date is 03/04/2026.', '日期为03/04/2026。'), ['DateWarning']);
assert.deepEqual(warnings('The rate is 59.94 fps.', '速率为59.94帧率。'), ['UnitWarning']);
assert.deepEqual(warnings('100 MB/s', '100 Mb/s'), ['UnitWarning']);
assert.deepEqual(warnings('12 cm, 0.05 mm, 250 mL', '12厘米、0.05毫米、250毫升'), []);
assert.deepEqual(warnings('温度为−5°C。', 'The temperature is 5°C.'), ['NumberWarning']);
assert.deepEqual(warnings('Count: 2', 'Count: two'), ['NumberWarning'], '保守提示可以覆盖数字改写，不宣称一定误译');
assert.deepEqual(warnings('The amount is 999999999999999999.01.', '金额为999999999999999999.02。'), ['NumberWarning']);
assert.deepEqual(warnings('The file is not saved.', '文件尚未保存。'), []);
const calls = [];
let reply = {records: [fixture], revision: 'rev1', tabs: [{id: 7, title: fixture.title, url: fixture.url}]};
let error = '';
const proxy = {handler: {readingCommand: async request => {
  calls.push(JSON.parse(request));
  return {result: JSON.stringify(reply), error};
}}};
const workspace = new exports.ReadingWorkspace(proxy);
const el = id => document.getElementById('reading-' + id);
const event = (node, type) => node.dispatchEvent(new dom.window.Event(type));
const flush = () => new Promise(resolve => setImmediate(resolve));
await workspace.refresh();
assert.equal(el('tabs').querySelector('img'), null);
assert.equal(el('tabs').querySelector('span').textContent.includes(fixture.title), true);
assert.equal(el('capture').disabled, true);
const checkbox = el('tabs').querySelector('input'); checkbox.checked = true; event(checkbox, 'change');
assert.equal(el('capture').disabled, false);
assert.equal(el('split').disabled, true);
el('group').value = '项目甲'; event(el('group'), 'input');
assert.equal(el('stash').disabled, false);
const details = el('records').querySelector('details'); details.open = true; event(details, 'toggle');
assert.equal(details.querySelector('mark').textContent, '原文');
assert.equal(details.querySelector('img'), null);
el('search').value = '不存在'; event(el('search'), 'input');
assert.equal(el('records').querySelectorAll('details').length, 0);
reply = {draft: {...fixture, translation: []}, canTranslate: true,
  destination: 'http://127.0.0.1:8000/v1', model: 'fixture-model'};
event(el('capture'), 'click'); await flush();
assert.equal(calls.at(-1).tab, 7);
const button = name => [...el('draft').querySelectorAll('button')].find(b => b.textContent === 'reading' + name);
assert.equal(button('Translate').disabled, true);
assert.equal(button('Analyze').disabled, true);
assert.equal(localCalls.length, 0, '默认关闭时不加载研究模型');
el('draft-note').value = '未保存的编辑'; el('draft-group').value = '草稿项目';
const consent = el('draft').querySelector('input[type=checkbox]');
consent.checked = true; event(consent, 'change');
assert.equal(button('Translate').disabled, false);
reply = {draft: fixture}; event(button('Translate'), 'click'); await flush();
assert.equal(calls.at(-1).destination, 'http://127.0.0.1:8000/v1');
assert.equal(calls.at(-1).model, 'fixture-model');
assert.equal(el('draft-note').value, '未保存的编辑');
assert.equal(el('draft-group').value, '草稿项目');
assert.equal(el('draft').querySelector('input[type=checkbox]').checked, false);
error = 'library_changed'; event(button('Save'), 'click'); await flush();
assert.equal(calls.at(-1).revision, 'rev1');
assert.equal(calls.at(-1).note, '未保存的编辑');
assert.equal(el('draft-note').value, '未保存的编辑');
assert.equal(el('status').textContent, 'readingChanged');
assert.equal(el('refresh').disabled, false);
error = ''; reply = {draft: fixture, canTranslate: false};
event(el('capture'), 'click'); await flush();
const prohibited = el('draft').querySelector('input[type=checkbox]');
prohibited.checked = true; event(prohibited, 'change');
assert.equal(button('Translate').disabled, true);
reply = {minimEnabled: true, phishlangEnabled: false};
el('minim').checked = true; event(el('minim'), 'change'); await flush();
assert.equal(calls.at(-1).op, 'research_settings');
assert.equal(calls.at(-1).minim, true);
assert.equal(button('Analyze').disabled, false);
assert.equal(localCalls.length, 0, '开启开关本身也不执行推理');
el('draft-note').value = '离线翻译前的批注';
localReply = {translations: ['Offline translation'], language: 'en'};
reply = {draft: {...fixture, translation: ['Offline translation'], note: '离线翻译前的批注'}};
event(button('LocalTranslate'), 'click'); await flush(); await flush();
assert.equal(localCalls.at(-1).op, 'translate');
assert.equal(calls.at(-1).op, 'translate_local');
assert.equal(calls.at(-1).draft, true);
assert.equal(calls.at(-1).note, '离线翻译前的批注');
assert.equal(el('draft-note').value, '离线翻译前的批注');
assert.equal(el('draft').querySelector('.reading-pairs').textContent.includes('Offline translation'), true);
assert.equal(localCalls.some(request => request.op === 'research'), false);
// 下载管理会刷新资料列表；已保存条目里尚未提交的批注不能因此丢失。
reply = {records: [fixture], minimEnabled: true, phishlangEnabled: false};
el('search').value = ''; event(el('search'), 'input');
await workspace.refresh();
let opened = el('records').querySelector('details'); opened.open = true; event(opened, 'toggle');
const editedNote = opened.querySelectorAll('textarea')[1];
editedNote.value = '下载语言包之前尚未保存的批注'; event(editedNote, 'input');
await workspace.refresh();
opened = el('records').querySelector('details');
assert.equal(opened.querySelectorAll('textarea')[1].value, '下载语言包之前尚未保存的批注');
el('search').value = '暂时隐藏条目'; event(el('search'), 'input');
el('search').value = ''; event(el('search'), 'input');
opened = el('records').querySelector('details'); opened.open = true; event(opened, 'toggle');
assert.equal(opened.querySelectorAll('textarea')[1].value, '下载语言包之前尚未保存的批注');
const saveRecord = () => [...opened.querySelectorAll('button')].find(b => b.textContent === 'readingSave');
error = 'library_changed'; event(saveRecord(), 'click'); await flush();
await workspace.refresh();
assert.equal(opened.querySelectorAll('textarea')[1].value, '下载语言包之前尚未保存的批注');
error = ''; reply = {records: [{...fixture, note: '下载语言包之前尚未保存的批注'}]};
event(saveRecord(), 'click'); await flush();
assert.equal(calls.at(-1).note, '下载语言包之前尚未保存的批注');
reply = {records: [{...fixture, note: '另一窗口后续更新'}]};
await workspace.refresh();
opened = el('records').querySelector('details');
assert.equal(opened.querySelectorAll('textarea')[1].value, '另一窗口后续更新', '保存成功后清除编辑副本，允许读取后续更新');
reply = {records: [{...fixture, paragraphs: ['费用为人民币1,234.56元。'],
  translation: ['The fee is $1,234.36.']}]};
await workspace.refresh();
opened = el('records').querySelector('details'); opened.open = true; event(opened, 'toggle');
assert.equal(opened.querySelectorAll('.reading-translation-warning').length, 2);
assert.ok(opened.textContent.includes('readingTranslationCaution'));
assert.ok(opened.textContent.includes('费用为人民币1,234.56元。'));
assert.ok(opened.textContent.includes('The fee is $1,234.36.'), '提示不得改写译文');
dom.window.close();
console.log('阅读模块真实 DOM 回归通过：选择、文本、高亮、搜索、授权、译文、冲突、实验默认关闭和本机译文保存。');
