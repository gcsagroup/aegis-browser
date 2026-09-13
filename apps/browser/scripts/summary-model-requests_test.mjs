import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';

// 执行真实初始化和按钮绑定，验证打开页面或切换模块不会请求模型服务。
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const source = readFileSync(new URL('../overlay/chrome/browser/resources/aegis/aegis.ts', import.meta.url), 'utf8');
const tree = ts.createSourceFile('aegis.ts', source, ts.ScriptTarget.Latest, true);
const names = ['init', 'setModule', 'bindModelControls'];
const functions = tree.statements.filter(n => ts.isFunctionDeclaration(n) && names.includes(n.name?.text));
assert.equal(functions.length, names.length);
const code = ts.transpileModule(functions.map(n => n.getText(tree)).join('\n'), {compilerOptions: {target: ts.ScriptTarget.ES2022}}).outputText;
for (const endpoint of ['http://127.0.0.1:57212/v1', 'https://model.example.test/v1']) {
  const fields = new Map();
  const field = id => {
    if (!fields.has(id)) fields.set(id, {value: endpoint, listeners: new Map(), addEventListener(type, fn) {this.listeners.set(type, fn);}});
    return fields.get(id);
  };
  let requests = 0;
  const context = vm.createContext({
    sendWithPromise: async () => ({privacyAi: true, isAndroid: false}),
    withRendererPolicyWorkerStatus: value => value,
    applyStatus() {}, bindToggle() {}, addWebUiListener() {},
    actionButton: field, selectField: field, textField: field,
    isLocalModelEndpoint: value => value.startsWith('http://127.0.0.1'),
    loadModels: async () => {requests++;},
  });
  vm.runInContext(`${code}\nglobalThis.run = init; globalThis.toggle = setModule;`, context);
  await context.run();
  assert.equal(requests, 0, '打开页面不应请求模型列表');
  await context.toggle('privacyAi', true);
  assert.equal(requests, 0, '启用摘要开关不应请求模型列表');
  field('model-load').listeners.get('click')();
  assert.equal(requests, 1, '明确点击加载模型才应发起请求');
}
console.log('PASS: 本机与远程配置各 3 项请求边界验证（真实初始化与按钮绑定）');
