import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';

// 同时支持地区码与脚本码；WebUI 默认 language 只有基础语言，不能用于简繁体分流。
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const source = readFileSync(new URL('../overlay/chrome/browser/resources/settings/downloads_page/downloads_page.ts', import.meta.url), 'utf8');
const tree = ts.createSourceFile('downloads_page.ts', source, ts.ScriptTarget.Latest, true);
let initializer;
function visit(node) {
  if (ts.isPropertyAssignment(node) && node.name.getText(tree) === 'aegisStrings_') {
    initializer = node.initializer.properties.find(n => n.name?.getText(tree) === 'value').initializer.getText(tree);
  }
  ts.forEachChild(node, visit);
}
visit(tree);
assert(initializer);
function copy(lang) {
  return JSON.stringify(vm.runInNewContext(`(${initializer})()`, {document:{documentElement:{lang}}}));
}
assert.equal(copy('zh-Hant'), copy('zh-TW'));
assert.equal(copy('zh-HK'), copy('zh-TW'));
assert.equal(copy('zh-Hans'), copy('zh-CN'));
assert.notEqual(copy('zh-Hant'), copy('zh-Hans'));
assert.notEqual(copy('en-US'), copy('zh-Hant'));
console.log('PASS: HTML 语言别名与地区码一致，共 5 项断言');
const summarySource = readFileSync(new URL('../overlay/chrome/browser/resources/aegis/aegis.ts', import.meta.url), 'utf8');
const summaryTree = ts.createSourceFile('aegis.ts', summarySource, ts.ScriptTarget.Latest, true);
const helperNames = ['localeCode', 'modelApiFormatLabel', 'summaryErrorLabel', 'siteFromUrl'];
const helpers = summaryTree.statements.filter(n => ts.isFunctionDeclaration(n) && helperNames.includes(n.name?.text));
assert.equal(helpers.length, helperNames.length);
const helperCode = ts.transpileModule(helpers.map(n => n.getText(summaryTree)).join('\n'), {compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
function summaryCopy(lang) {
  return JSON.stringify(vm.runInNewContext(`${helperCode};[localeCode(),modelApiFormatLabel('openai'),summaryErrorLabel('model request timed out', true),siteFromUrl('invalid URL')];`, {document:{documentElement:{lang}}, URL}));
}
assert.equal(summaryCopy('zh-Hant'), summaryCopy('zh-TW'));
assert.equal(summaryCopy('zh-HK'), summaryCopy('zh-TW'));
assert.equal(summaryCopy('zh-Hans'), summaryCopy('zh-CN'));
assert.notEqual(summaryCopy('zh-Hant'), summaryCopy('zh-Hans'));
console.log('PASS: 摘要语言、协议名、错误与空页面说明别名一致，共 4 项断言');

// 从实际 C++ 注入与 HTML 模板还原语言桥接，再运行真实动态文案函数。
// 默认字段在初始化后补入；繁体不能被其基础语言 zh 覆盖。
const controller = readFileSync(new URL('../overlay/chrome/browser/ui/webui/aegis/aegis_ui.cc', import.meta.url), 'utf8');
const html = readFileSync(new URL('../overlay/chrome/browser/resources/aegis/aegis.html', import.meta.url), 'utf8');
const localeField = controller.match(/AddString\("([^"\n]+)", g_browser_process->GetApplicationLocale\(\)\)/)?.[1];
const htmlField = html.match(/lang="\$i18n\{([^}]+)\}"/)?.[1];
assert(localeField && htmlField);
for (const appLocale of ['zh-CN', 'zh-TW', 'en-US']) {
  const localized = {[localeField]:appLocale, language:appLocale.split('-')[0]};
  assert.equal(copy(localized[htmlField]), copy(appLocale));
}
console.log('PASS: 真实模板语言桥接在默认字段补入后仍保留地区，共 3 项断言');
