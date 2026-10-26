import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {JSDOM} from 'jsdom';
const root = new URL('../../overlay/chrome/browser/resources/aegis/', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
function viewer() {
  const dom = new JSDOM(read('enhancements_shared/viewer.html'), {url: 'https://viewer.invalid/', runScripts: 'outside-only'});
  const w = dom.window;
  w.TextEncoder = TextEncoder;
  w.matchMedia = () => ({matches: false});
  Object.defineProperty(w.navigator, 'language', {value: 'zh-CN'});
  w.HTMLElement.prototype.scrollIntoView = () => {};
  for (const script of ['vendor/markdown-it.min.js', 'vendor/task-lists.min.js', 'vendor/highlight.min.js', 'vendor/purify.min.js', 'i18n.js', 'viewer.js'])
    w.eval(read('enhancements_shared/' + script));
  return dom;
}
test('阅读外观不授予图片权限，换文档撤销图片授权与旧源码状态', () => {
  const dom = viewer(), w = dom.window, doc = w.document;
  const payload = {title: '安全文档', text: '# 标题\n![外图](https://example.com/p.png)\n<script>window.leaked=true</script>', baseURL: 'https://example.com/a.md'};
  assert.equal(w.AegisMarkdown.load(payload), true);
  assert.equal(doc.querySelector('article img').getAttribute('src'), '');
  w.AegisMarkdown.configure({embedded: true, preferences: {theme: 'dark', font: 19, width: 1100, family: 'serif', spacing: 210}});
  assert.equal(doc.body.className, 'embedded');
  assert.equal(doc.documentElement.style.getPropertyValue('--font'), '19px');
  assert.equal(doc.querySelector('article img').getAttribute('src'), '');
  assert.equal(w.leaked, undefined);
  assert.equal(doc.querySelector('article script'), null);
  w.AegisMarkdown.command('remote-images');
  assert.equal(doc.querySelector('article img').getAttribute('src'), 'https://example.com/p.png');
  w.AegisMarkdown.command('source-toggle');
  assert.equal(doc.getElementById('source').hidden, false);
  w.AegisMarkdown.load({...payload, title: '另一份文档'});
  assert.equal(doc.getElementById('source').hidden, true);
  assert.equal(doc.querySelector('article img').getAttribute('src'), '');
  assert.equal(doc.getElementById('remote-images').textContent, '加载外部图片');
  dom.window.close();
});
test('阅读器拒绝非受信来源命令，并按需展开查找和目录', () => {
  const dom = viewer(), w = dom.window, doc = w.document;
  w.AegisMarkdown.load({title: '原文', text: '# 原文'});
  w.dispatchEvent(new w.MessageEvent('message', {source: w, origin: 'https://evil.invalid', data: {type: 'load', value: {text: '# 替换'}}}));
  assert.equal(w.AegisMarkdown.text(), '# 原文');
  assert.equal(doc.getElementById('findbar').hidden, true);
  w.AegisMarkdown.command('find-toggle');
  assert.equal(doc.getElementById('findbar').hidden, false);
  assert.equal(doc.activeElement.id, 'query');
  w.AegisMarkdown.command('outline-toggle');
  assert.equal(doc.getElementById('outline').hidden, true);
  w.AegisMarkdown.command('arbitrary-handler');
  assert.equal(w.AegisMarkdown.text(), '# 原文');
  dom.window.close();
});
async function manager(locale = 'zh-CN', enabled = false) {
  const dom = new JSDOM(read('enhancements.html'), {url: 'https://settings.invalid/#tab=second&script=script-1', runScripts: 'outside-only'});
  const w = dom.window;
  w.TextEncoder = TextEncoder;
  w.confirm = () => true;
  Object.defineProperty(w.navigator, 'language', {value: 'zh-CN'});
  w.loadTimeData = {getString: () => locale};
  w.eval(read('enhancements_shared/i18n.js'));
  w.eval(read('enhancements_shared/core.js'));
  w.eval(read('enhancements_shared/vendor/acorn.js'));
  const source = w.AegisEnhancementsCore.template('https://second.test/');
  const script = {id: 'script-1', revision: 1, source, metadata: w.AegisEnhancementsCore.parse(source), enabled, world: 'isolated', allFrames: false};
  const state = {sites: [], scripts: [script], tabs: [{id: 'first', url: 'https://first.test/', document: 'old'}, {id: 'second', url: 'https://second.test/', document: 'new', statuses: {'script-1': {status: 'completed', trial: true}}, menus: [{id: 'menu-1', script: 'script-1', label: '<img src=x>切换'}]}]};
  const requests = [];
  w.sendWithPromise = async (_, request) => { requests.push(request); return state; };
  const code = read('enhancements.js').replace(/^import .*;\n/gm, '').replace('export async function initializeEnhancements', 'globalThis.initializeEnhancements = async function').split('if (document.getElementById("enhancement-root"))')[0];
  w.eval(code);
  await w.initializeEnhancements(w.document);
  return {dom, requests};
}
test('从盾牌深链接到准确标签及脚本，命令保留文档标识且按脚本分组', async () => {
  const {dom, requests} = await manager(), w = dom.window, doc = w.document;
  assert.equal(doc.getElementById('tabs').value, 'second');
  assert.equal(doc.getElementById('editor').hidden, false);
  assert.equal(doc.getElementById('manager').hidden, true);
  assert.match(doc.getElementById('runtime').textContent, /试运行 · 已执行/);
  assert.equal(doc.querySelector('#runtime img'), null);
  doc.querySelector('#runtime button').click();
  await new Promise(resolve => setImmediate(resolve));
  const request = requests.find(value => value.op === 'menu');
  assert.equal(request.tab, 'second');
  assert.equal(request.document, 'new');
  assert.equal(request.id, 'menu-1');
  dom.window.close();
});

test('三语切换只改变阅读控件，保留文档标题、正文、源码和图片授权边界', () => {
  const dom = viewer(), w = dom.window, doc = w.document;
  w.AegisMarkdown.load({title: '阅读库', text: '# 阅读库\n复制原文'});
  w.AegisMarkdown.configure({embedded: true, locale: 'en'});
  assert.equal(doc.getElementById('outline-toggle').textContent, 'Outline');
  assert.equal(doc.getElementById('query').placeholder, 'Find in document');
  assert.equal(doc.getElementById('title').textContent, '阅读库');
  assert.match(doc.getElementById('document').textContent, /复制原文/);
  assert.equal(w.AegisMarkdown.text(), '# 阅读库\n复制原文');
  w.AegisMarkdown.configure({embedded: true, locale: 'zh-Hant'});
  assert.equal(doc.getElementById('copy-source').textContent, '複製原文');
  w.AegisMarkdown.command('find-toggle');
  doc.getElementById('query').value = '复制'; doc.getElementById('find').click();
  assert.equal(doc.getElementById('image-permissions').hidden, true);
  dom.window.close();
});

test('脚本管理界面跟随应用语言，保留脚本名称与源码', async () => {
  const {dom} = await manager('en', true), doc = dom.window.document;
  assert.match(doc.getElementById('scripts').textContent, /Enabled/);
  assert.match(doc.getElementById('scripts').textContent, /Disable/);
  assert.doesNotMatch(doc.getElementById('scripts').textContent, /已启用|停用/);
  assert.match(doc.getElementById('source').value, /我的网页增强/);
  dom.window.close();
});
