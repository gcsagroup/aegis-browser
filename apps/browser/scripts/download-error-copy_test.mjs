import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';

// 执行真实错误处理方法；中文普通视图不泄露底层英文，诊断原文仍完整保留。
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const source = readFileSync(new URL('../overlay/ui/webui/resources/cr_components/aegis_downloads/aegis_download_panel.ts', import.meta.url), 'utf8');
const tree = ts.createSourceFile('downloads.ts', source, ts.ScriptTarget.Latest, true);
const product = tree.statements.find(n => ts.isClassDeclaration(n) && n.name?.text === 'AegisDownloadPanelElement');
const names = ['errorText_', 'formatPreviewError_', 'descriptorPrompt_', 'onInspectClick_'];
const methods = product.members.filter(n => names.includes(n.name?.getText(tree)));
assert.equal(methods.length, names.length);
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
  // 运行真实预览入口：空文件和不支持的后缀都应给出本平台可执行的指引。
  for (const torrentSupported of [false, true]) {
    for (const file of [null, {name: 'unsupported.txt'}]) {
      const panel = context.panel;
      panel.profileAvailable_ = true;
      panel.torrentSupported_ = torrentSupported;
      panel.descriptor_ = () => ({files: {item: () => file}});
      panel.shadowRoot = {querySelector: () => null};
      panel.resetPreview_ = () => {};
      panel.request_ = () => { throw Error('无效输入不得调用下载后端'); };
      await panel.onInspectClick_();
      assert.match(panel.previewText_, /\.meta4/);
      assert.match(panel.previewText_, /\.metalink/);
      assert.equal(/\.torrent|Magnet|磁力/.test(panel.previewText_), torrentSupported);
      assert.equal(panel.working_, false, '输入校验后必须恢复可操作状态');
    }
  }
}
console.log('PASS: 三语错误提示、诊断保留和平台一致的下载输入校验');
