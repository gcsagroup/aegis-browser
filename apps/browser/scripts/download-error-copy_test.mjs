import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';

// 执行真实错误处理方法；中文普通视图不泄露底层英文，诊断原文仍完整保留。
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const source = readFileSync(new URL('../overlay/chrome/browser/resources/downloads/aegis_download_panel.ts', import.meta.url), 'utf8');
const tree = ts.createSourceFile('downloads.ts', source, ts.ScriptTarget.Latest, true);
const product = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'AegisDownloadPanelElement');
const names = ['errorText_', 'formatPreviewError_'];
const methods = product.members.filter(n => names.includes(n.name?.getText(tree)));
assert.equal(methods.length, 2);
const code = ts.transpileModule(`class Panel {${methods.map(n => n.getText(tree)).join('\n')}};globalThis.panel = new Panel();`, {compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText;
for (const lang of ['en-US', 'zh-CN', 'zh-TW']) {
  const context = vm.createContext({document:{documentElement:{lang}}});
  vm.runInContext(code, context);
  for (const error of ['magnet link is invalid or too large', 'network unavailable']) {
    const visible = context.panel.formatPreviewError_(error);
    assert.equal(context.panel.errorDetails_, error);
    if (lang.startsWith('zh')) assert.notEqual(visible, error);
    else assert.equal(visible, error);
  }
}
console.log('PASS: 三语错误提示与诊断保留，共 12 项断言');
