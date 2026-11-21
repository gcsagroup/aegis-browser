// 验证升级后的设置页仍按当前路由管理 Aegis 页面生命周期。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import test from 'node:test';
import vm from 'node:vm';

const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const directory = new URL('../overlay/chrome/browser/resources/settings/settings_main/', import.meta.url);
const source = readFileSync(new URL('settings_main.ts', directory), 'utf8');
const template = readFileSync(new URL('settings_main.html', directory), 'utf8');
const parsed = ts.createSourceFile('settings_main.ts', source, ts.ScriptTarget.Latest, true);
const element = parsed.statements.find(node => ts.isClassDeclaration(node) && node.name?.text === 'SettingsMainElement');
const method = element?.members.find(node => node.name?.getText(parsed) === 'renderAegisPlugin_');
assert.ok(method, '原生设置页必须保留独立的 Aegis 生命周期入口');
const compiled = ts.transpileModule(`class Subject { ${method.getText(parsed)} }; globalThis.Subject = Subject;`, {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText;
const context = {};
vm.runInNewContext(compiled, context);

function fixture() {
  const page = new context.Subject();
  page.inSearchMode_ = false;
  page.lastRoute_ = null;
  // 上游会缓存访问过的页面；Aegis 页面不应因此留在隐藏 DOM 中。
  page.hasSearched_ = true;
  page.renderedRoutes_ = new Set();
  const route = {contains: value => value?.section === 'ocr'};
  page.renderedRoutes_.add(route);
  return {page, route};
}

test('离开 Aegis 页面后卸载，访问记录和历史搜索不延长页面生命周期', () => {
  const {page, route} = fixture();
  assert.equal(page.renderAegisPlugin_(route), false);
  page.lastRoute_ = {section: 'ocr'};
  assert.equal(page.renderAegisPlugin_(route), true);
  page.lastRoute_ = {section: 'privacy'};
  assert.equal(page.renderAegisPlugin_(route), false);
  page.lastRoute_ = null;
  assert.equal(page.renderAegisPlugin_(route), false);
});

test('搜索期间挂载页面，退出搜索后恢复当前路由范围', () => {
  const {page, route} = fixture();
  page.inSearchMode_ = true;
  assert.equal(page.renderAegisPlugin_(route), true);
  page.lastRoute_ = {section: 'privacy'};
  page.inSearchMode_ = false;
  assert.equal(page.renderAegisPlugin_(route), false);
});

test('全部十个 Aegis 分组使用 Lit 条件渲染及相同生命周期入口', () => {
  const expected = new Map([
    ['AEGIS', 'home'], ['AEGIS_AI', 'ai'], ['AEGIS_EXPERIMENTS', 'experiments'],
    ['AEGIS_DOWNLOADS', 'downloads'], ['AEGIS_OCR', 'ocr'], ['AEGIS_TOOLS', 'tools'],
    ['AEGIS_ENHANCEMENTS', 'enhancements'], ['AEGIS_READING', 'reading'],
    ['AEGIS_GESTURES', 'gestures'], ['AEGIS_PRIVACY', 'privacy'],
  ]);
  const branches = [...template.matchAll(/this\.renderAegisPlugin_\(this\.routes_\.(AEGIS(?:_[A-Z]+)?)\) \? html`\s*<settings-aegis-page mode="([^"]+)"><\/settings-aegis-page>\s*` : ''/g)];
  assert.equal(branches.length, expected.size);
  assert.deepEqual(new Map(branches.map(match => [match[1], match[2]])), expected);
  assert.doesNotMatch(template, /this\.renderPlugin_\(this\.routes_\.AEGIS|\[\[|dom-if/);
});
