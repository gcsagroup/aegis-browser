// 在真实 DOM 中切换移动设置分组，验证旧控件身份、未保存内容和明确的打开动作。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import {fileURLToPath} from 'node:url';
import {JSDOM} from 'jsdom';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const ts = createRequire(root + '/packages/core/package.json')('typescript');
const resources = root + '/apps/browser/overlay/chrome/browser/resources/';
function fixture(folder, filename, url) {
  const dom = new JSDOM(readFileSync(resources + folder + '/' + filename, 'utf8'), {url});
  dom.window.document.documentElement.lang = 'zh-CN';
  dom.window.scrollTo = () => {};
  const exports = {};
  const source = ts.transpileModule(readFileSync(resources + folder + '/mobile_settings.ts', 'utf8'), {
    compilerOptions: {target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS},
  }).outputText;
  vm.runInNewContext(source, {exports, document: dom.window.document, window: dom.window,
    location: dom.window.location, URLSearchParams});
  return {dom, document: dom.window.document, exports};
}

const page = fixture('aegis', 'aegis.html', 'https://settings.test/');
const {dom, document} = page;
const originalToggle = document.getElementById('tracker');
const originalField = document.getElementById('model-endpoint');
originalToggle.checked = true;
originalField.value = 'https://draft.invalid/v1';
const calls = [];
page.exports.initializeMobileSettings(async section => calls.push(section));
assert.equal(document.querySelectorAll('.mobile-settings-nav a').length, 8);
assert.equal(document.querySelectorAll('.mobile-settings-content:not([hidden])').length, 0);
assert.equal(document.querySelector('.page-header h1').textContent, 'Aegis 设置');
assert.equal(document.querySelector('.ai-control').hidden, true);
assert.match(document.querySelector('#mobile-tools').textContent, /此功能适用于桌面版/,
    '不支持的功能应显示平台说明，不能留下空白子页');
assert.match(document.querySelector('.downloads > .meta').textContent, /暂不支持种子或磁力链接/);
function visit(id) {
  dom.window.history.replaceState(null, '', '#' + id);
  dom.window.dispatchEvent(new dom.window.HashChangeEvent('hashchange'));
}
for (const group of ['privacy', 'enhancements', 'reading', 'gestures', 'ai', 'downloads', 'tools', 'experiments']) {
  visit(group);
  const visible = document.querySelectorAll('.mobile-settings-content:not([hidden])');
  assert.equal(visible.length, 1);
  assert.equal(visible[0].id, 'mobile-' + group);
  assert.equal(document.activeElement, document.querySelector('.page-header h1'));
}
assert.equal(document.getElementById('tracker'), originalToggle);
assert.equal(originalToggle.checked, true);
assert.equal(document.getElementById('model-endpoint'), originalField);
assert.equal(originalField.value, 'https://draft.invalid/v1', '切换分类不得重建或重置未保存表单');
assert.deepEqual(calls, [], '分类导航不得自动启动助手或模型');
visit('reading');
document.querySelector('#mobile-reading button').click();
assert.deepEqual(calls, ['reading']);
visit('fp-probe');
assert.equal(document.querySelector('.mobile-settings-content:not([hidden])').id, 'mobile-privacy');
visit('unknown');
assert.equal(document.querySelector('.mobile-settings-nav').hidden, false);
page.exports.initializeMobileSettings(async () => {});
assert.equal(document.querySelectorAll('.mobile-settings-nav').length, 1);

for (const section of ['reading', 'experiments']) {
  const agent = fixture('aegis_agent', 'agent.html', 'https://agent.test/?mobileSettings=' + section);
  let refreshes = 0;
  let workspaceOpens = 0;
  let settingsOpens = 0;
  const original = agent.document.getElementById('reading-minim');
  agent.exports.initializeMobileAgentSettings(async () => { refreshes++; },
      () => { workspaceOpens++; }, () => { settingsOpens++; });
  assert.equal(agent.document.body.dataset.mobileSettings, section);
  assert.equal(agent.document.getElementById(section === 'reading' ? 'reading-ai-settings' : 'reading-research-settings').open, true);
  assert.equal(agent.document.getElementById('reading-minim'), original);
  assert.equal(refreshes, 0, '交给原有展开事件回读，不重复请求配置');
  assert.equal(workspaceOpens, 0, '设置页不自动打开工作区');
  assert.equal(agent.document.getElementById('goal').hasAttribute('autofocus'), false);
  assert.equal(settingsOpens, 0, '设置导航只能由用户明确触发');
  const back = agent.document.querySelector('.mobile-settings-back');
  assert.equal(back.getAttribute('href'), 'chrome://aegis/');
  const click = new agent.dom.window.MouseEvent('click', {bubbles: true, cancelable: true});
  back.dispatchEvent(click);
  assert.equal(click.defaultPrevented, true, '阻止不受信任页面直接跳转 chrome://');
  assert.equal(settingsOpens, 1, '点击必须实际调用原生设置入口');
}
// Android 旧版把实验选项放在翻译卡片内；迁移分组必须保留这些控件。
const legacy = fixture('aegis_agent', 'agent.html', 'https://agent.test/?mobileSettings=experiments');
const research = legacy.document.getElementById('reading-research-settings');
const heading = legacy.document.createElement('h3');
heading.textContent = '实验模型';
const local = legacy.document.getElementById('reading-ai-settings');
local.append(heading);
while (research.children.length > 1) local.append(research.children[1]);
research.remove();
legacy.exports.initializeMobileAgentSettings(async () => {}, () => {}, () => {});
assert.equal(legacy.document.getElementById('reading-minim').closest('details').id, 'reading-research-settings');

console.log('PASS mobile settings: eight categories, preserved drafts, explicit actions, legacy links and agent subpages');
