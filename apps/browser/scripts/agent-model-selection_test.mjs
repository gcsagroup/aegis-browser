import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';

// 运行真实产品函数与事件绑定；该测试不替代 macOS 侧栏实机验收。
const ts = createRequire(new URL('../../../packages/core/package.json', import.meta.url))('typescript');
const root = new URL('../overlay/chrome/browser/resources/aegis_agent/', import.meta.url);
const source = readFileSync(new URL('agent.ts', root), 'utf8');
const html = readFileSync(new URL('agent.html', root), 'utf8');
assert.match(html, /<select id="model-options" hidden>/);
assert(!html.includes('<datalist') && !html.includes('list="model-options"'));
const tree = ts.createSourceFile('agent.ts', source, ts.ScriptTarget.Latest, true);
const names = ['option', 'renderModel', 'resetDetectedModels', 'selectDetectedModel',
  'syncDetectedModel', 'detectModels', 'friendlyModelError', 'bindActions',
  'saveModel', 'showModelSaveError'];
const functions = tree.statements.filter(node => ts.isFunctionDeclaration(node) && names.includes(node.name?.text));
assert.equal(functions.length, names.length);
const code = ts.transpileModule(functions.map(node => node.getText(tree)).join('\n'), {
  compilerOptions: {target: ts.ScriptTarget.ES2022},
}).outputText;
const models = ['Huihui-Qwen3.5-9B-abliterated-mlx-4bit',
  'Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit',
  'Qwen3.8-27B-direct-A-best15-MLX-4bit', 'Qwen3.8-27B-heretic-dflash', 'MarkItDown'];
function harness(name = models[1]) {
  const fields = new Map();
  const field = id => {
    if (!fields.has(id)) fields.set(id, {
      children: [], listeners: new Map(), _value: '', hidden: true,
      get value() { return this._value; },
      set value(value) {
        this._value = id === 'model-options' && !this.children.some(o => o.value === value) ? '' : value;
      },
      append(...options) { this.children.push(...options); },
      replaceChildren(...options) { this.children = options; this._value = ''; },
      addEventListener(event, callback) { this.listeners.set(event, callback); },
    });
    return fields.get(id);
  };
  let response = {ok: true, models};
  let modelRequests = 0;
  const saved = [];
  const snapshot = {modelConfigured: true, modelProvider: 'openai',
    modelBaseUrl: 'http://127.0.0.1:8000/v1', modelName: name, lastError: ''};
  const context = vm.createContext({element: field, snapshot, modelBusy: false,
    modelFormInitialized: false, loadTimeData: {getString: key => key},
    document: {createElement: () => ({})}, proxy: {handler: {
      listModels: async () => {
        modelRequests++;
        if (response instanceof Error) throw response;
        return typeof response === 'function' ? response() : response;
      },
      configureModel: async (...args) => {
        saved.push(args);
        return {snapshot: {...snapshot, modelName: args[2]}};
      },
    }},
  });
  vm.runInContext(code, context);
  context.render = next => { context.snapshot = next; context.renderModel(next); };
  context.render(snapshot);
  context.bindActions();
  const fire = (id, event) => field(id).listeners.get(event)();
  return {field, context, saved, fire, respond: value => { response = value; },
    requests: () => modelRequests};
}
let passed = 0;
async function check(label, fn) { await fn(); passed++; console.log('PASS: ' + label); }
await check('显示已保存配置不主动请求模型服务，也不生成检测成功提示', async () => {
  const h = harness();
  h.context.render({...h.context.snapshot, modelBaseUrl: 'http://127.0.0.1:1/v1'});
  assert.equal(h.requests(), 0);
  assert.equal(h.field('model-state').textContent, `modelReady · ${models[1]}`);
  assert(!h.field('model-feedback').textContent);
  h.respond({ok: false, error: 'connection failed', models: []});
  await h.fire('detect-models-button', 'click');
  assert.equal(h.requests(), 1);
  assert(!h.field('model-feedback').textContent.includes('modelDetected'));
});
await check('已保存的长模型名不筛掉其他候选，完整展示服务返回的五项', async () => {
  const h = harness();
  await h.fire('detect-models-button', 'click');
  assert.deepEqual(h.field('model-options').children.map(o => o.value), models);
  assert.equal(h.field('model-options').value, models[1]);
  assert.equal(h.field('model-options').hidden, false);
  assert.equal(h.field('model-options-label').hidden, false);
});
await check('真实选择事件写入模型名，保存调用使用所选项', async () => {
  const h = harness();
  await h.fire('detect-models-button', 'click');
  h.field('model-options').value = models[3];
  h.fire('model-options', 'change');
  assert.equal(h.field('model-name').value, models[3]);
  h.context.render(h.context.snapshot);
  assert.equal(h.field('model-name').value, models[3]);
  await h.fire('save-model-button', 'click');
  assert.equal(h.saved[0][2], models[3]);
  assert.equal(h.field('model-feedback').textContent, 'modelSaved');
});
await check('手动输入不被检测覆盖，匹配项同步、非列表名称允许保存', async () => {
  const h = harness('custom/model');
  await h.fire('detect-models-button', 'click');
  assert.equal(h.field('model-name').value, 'custom/model');
  assert.equal(h.field('model-options').value, '');
  h.field('model-name').value = models[4];
  h.fire('model-name', 'input');
  assert.equal(h.field('model-options').value, models[4]);
  h.field('model-name').value = 'custom/model';
  h.fire('model-name', 'input');
  await h.fire('save-model-button', 'click');
  assert.equal(h.saved[0][2], 'custom/model');
});
await check('首次无模型名时预选第一项', async () => {
  const h = harness('');
  await h.fire('detect-models-button', 'click');
  assert.equal(h.field('model-name').value, models[0]);
  assert.equal(h.field('model-options').value, models[0]);
});
for (const [id, event] of [['model-provider', 'change'], ['model-base-url', 'input'], ['model-api-key', 'input']]) {
  await check('连接变更清除旧候选：' + id, async () => {
    const h = harness();
    await h.fire('detect-models-button', 'click');
    h.fire(id, event);
    assert.equal(h.field('model-options').children.length, 0);
    assert.equal(h.field('model-options').hidden, true);
    assert.equal(h.field('model-options-label').hidden, true);
  });
}
for (const [label, response, expected] of [
  ['空列表', {ok: true, models: []}, 'detectModels: 0'],
  ['服务失败', {ok: false, error: 'failed'}, 'modelConnectionError'],
  ['传输异常', new Error('disconnected'), 'modelConnectionError'],
]) {
  await check(label + '不保留旧候选或卡住按钮', async () => {
    const h = harness();
    await h.fire('detect-models-button', 'click');
    h.respond(response);
    await h.fire('detect-models-button', 'click');
    assert.equal(h.field('model-options').hidden, true);
    assert.equal(h.field('model-name').value, models[1]);
    assert.equal(h.field('model-feedback').textContent, expected);
    assert.equal(h.field('detect-models-button').disabled, false);
    assert.equal(h.field('model-options').disabled, false);
  });
}
await check('检测期间禁用选择，响应完成后恢复', async () => {
  const h = harness();
  let done;
  h.respond(() => new Promise(resolve => { done = resolve; }));
  const pending = h.fire('detect-models-button', 'click');
  assert.equal(h.field('model-options').disabled, true);
  done({ok: true, models});
  await pending;
  assert.equal(h.field('model-options').disabled, false);
});
console.log(`模型选择回归 ${passed}/${passed}，另含 HTML 结构检查；非实机验收。`);
