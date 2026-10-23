import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import vm from 'node:vm';
import {JSDOM} from 'jsdom';
const ts = createRequire(new URL('../../../../packages/core/package.json', import.meta.url))('typescript');
const root = new URL('../../overlay/chrome/browser/resources/', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
const compile = source => ts.transpileModule(source, {compilerOptions: {target: ts.ScriptTarget.ES2022}}).outputText;

// 迁移清单独立列出既有控件；新增分类不得以简化旧表单代替完整迁移。
const legacyGroups = {
  privacy: ['tracker', 'phish', 'fingerprint', 'fp-probe', 'miner-guard', 'link-sanitize', 'cookie-janitor', 'cname-uncloak', 'bounce-tracking', 'policy-worker', 'filter-auto', 'filter-update'],
  ai: ['privacy-ai', 'model-provider', 'model-endpoint', 'model-api-key', 'model-select', 'model-custom', 'model-load', 'model-save', 'model-key-clear', 'summarize', 'browser-agent', 'browser-agent-open'],
  downloads: [],
  tools: ['ai-control'],
};
function legacy() {
  const dom = new JSDOM(read('aegis/aegis.html'), {url: 'https://aegis.invalid/', runScripts: 'outside-only'});
  dom.window.document.documentElement.lang = 'zh-CN';
  const w = dom.window;
  const calls = [];
  const saved = {profileAvailable: true, enabled: true, trackerBlocking: false, phishInterstitial: true, fingerprintGuard: true, minerGuard: false, linkSanitize: true, cookieJanitor: false, cnameUncloak: true, bounceTracking: false, policyWorker: true, privacyAi: true, browserAgentAvailable: true, browserAgentEnabled: false, aiControl: false, aiControlAvailable: true, filterListAutoUpdate: false, filterListHostCount: 123, modelProvider: 'remote-openai', modelBaseUrl: 'https://model.invalid/v1', modelName: 'saved-model', modelApiKeyConfigured: true, recentEvents: []};
  w.getRequiredElement = id => w.document.getElementById(id);
  w.addWebUiListener = () => {};
  w.embeddedSettings = false;
  w.sendWithPromise = async (op, ...args) => {
    calls.push([op, ...args]);
    if (op === 'setModuleEnabled') saved[args[0]] = args[1];
    return {...saved};
  };
  const tree = ts.createSourceFile('aegis.ts', read('aegis/aegis.ts').split('// 复用完整设置控件；')[0], ts.ScriptTarget.Latest, true);
  const source = tree.statements.filter(node => !ts.isImportDeclaration(node)).map(node => node.getText(tree)).join('\n').split('// 复用完整设置控件；')[0];
  w.eval(compile(source));
  return {dom, w, calls, saved};
}

test('完整迁移防护、摘要、工具和下载控件，没有重复 ID 或丢失旧设置', () => {
  const dom = new JSDOM(read('aegis/aegis.html'));
  const doc = dom.window.document;
  const ids = [...doc.querySelectorAll('[id]')].map(el => el.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const [group, controls] of Object.entries(legacyGroups)) {
    for (const id of controls) assert(doc.getElementById(id), `${group} 遗漏 ${id}`);
  }
  assert(doc.querySelector('#downloads aegis-download-panel'));
  assert(doc.querySelector('.privacy #privacy-ai'));
  const agent = new JSDOM(read('aegis_agent/agent.html'));
  for (const id of ['model-provider','model-base-url','model-name','model-api-key','model-options','model-routing-mode','model-quality-score','model-latency-score','model-cost','model-efforts','model-profile-default','model-profile-basic','model-profile-strong','model-input-price','model-cache-price','model-output-price','model-supports-tools','model-supports-long-context','model-supports-strong-reasoning','model-pool','typesafe-enabled','typesafe-api-key','clear-typesafe-key-button','reading-language-packs','reading-minim','reading-phishlang']) {
    const el = agent.window.document.getElementById(id);
    assert(el?.closest('#model-details, #reading-ai-settings, #typesafe-details, #reading-research-settings'), `助手设置遗漏 ${id}`);
  }
  dom.window.close(); agent.window.close();
});

test('打开旧配置只读取状态，混合开关、模型地址和密钥状态不被默认值覆盖', async () => {
  const {dom, w, calls, saved} = legacy();
  const before = JSON.stringify(saved);
  await w.init();
  assert.deepEqual(calls, [['getStatus']]);
  assert.equal(JSON.stringify(saved), before);
  assert.equal(w.document.getElementById('tracker').checked, false);
  assert.equal(w.document.getElementById('phish').checked, true);
  assert.equal(w.document.getElementById('filter-auto').checked, false);
  assert.equal(w.document.getElementById('model-endpoint').value, saved.modelBaseUrl);
  assert.equal(w.document.getElementById('model-custom').value, saved.modelName);
  assert.equal(w.document.getElementById('model-api-key').value, '');
  dom.window.close();
});

test('仅修改选中的开关，不覆盖其他开关、模型或授权状态', async () => {
  const {dom, w, calls, saved} = legacy();
  const before = {...saved};
  await w.init();
  const toggle = w.document.getElementById('tracker');
  toggle.checked = true; toggle.dispatchEvent(new w.Event('change'));
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls, [['getStatus'], ['setModuleEnabled', 'trackerBlocking', true]]);
  assert.deepEqual(saved, {...before, trackerBlocking: true});
  dom.window.close();
});

test('伪装跟踪开关显示保存值，主跟踪器关闭时不会误显示配置丢失', async () => {
  const {dom, w, saved} = legacy();
  saved.trackerBlocking = false;
  saved.cnameUncloak = false;
  saved.cnameUncloakConfigured = true;
  await w.init();
  assert.equal(w.document.getElementById('tracker').checked, false);
  assert.equal(w.document.getElementById('cname-uncloak').checked, true);
  dom.window.close();
});

test('分类页错误显示在当前可见区域，不藏到摘要表单里', () => {
  const {dom, w} = legacy();
  for (const section of ['privacy', 'downloads', 'tools']) {
    w.document.body.dataset.settings = section;
    w.showResult('当前配置不可用');
    const result = w.document.getElementById('settings-result');
    assert.equal(result.hidden, false);
    assert.equal(result.textContent, '当前配置不可用');
    assert.equal(w.document.getElementById('privacy-result').hidden, true);
  }
  w.document.body.dataset.settings = 'ai';
  w.showResult('摘要已完成');
  assert.equal(w.document.getElementById('privacy-result').textContent, '摘要已完成');
  dom.window.close();
});

test('设置侧栏只有一个入口，八个分类及原来的四个设置地址均可到达', () => {
  const menu = new JSDOM(read('settings/settings_menu/settings_menu.html'));
  assert.deepEqual([...menu.window.document.querySelectorAll('a[href^="/aegis"]')].map(el => el.getAttribute('href')), ['/aegis']);
  const html = read('settings/aegis_page/aegis_page.html');
  const route = read('settings/route.ts');
  for (const page of ['Privacy','Enhancements','Reading','Gestures','Ai','Downloads','Tools','Experiments']) {
    assert(html.includes(`href="/aegis${page}"`));
    assert(route.includes(`createSection('/aegis${page}'`));
  }
  assert(!read('settings/privacy_page/privacy_page.html').includes('aegisLinkRow'));
  assert(!read('settings/privacy_page/privacy_page.ts').includes('onAegisSettingsClick_'));
  assert(!html.includes('settings:code'));
  assert(!html.includes('settings:appearance'));
  menu.window.close();
});

test('脚本管理器独立打开并保留目标与脚本定位参数', async () => {
  const source = read('aegis/enhancements.js').split('if (document.getElementById("enhancement-root"))')[1];
  let initialized = 0;
  const run = new Function('document', 'initializeEnhancements', `return (async () => { if (document.getElementById("enhancement-root"))${source} })();`);
  await run({getElementById: () => ({})}, async () => { initialized++; });
  assert.equal(initialized, 1);
  assert(!source.includes('location.replace'));
  assert(read('aegis/enhancements.js').includes('new URLSearchParams(location.hash.slice(1)).get("tab")'));
  assert(read('aegis/enhancements.js').includes('get("script")'));
});

test('设置模式显示完整助手配置，移除隐藏任务输入焦点，侧栏只保留统一入口', () => {
  const tree = ts.createSourceFile('agent.ts', read('aegis_agent/agent.ts'), ts.ScriptTarget.Latest, true);
  const fn = tree.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.text === 'initializeSettingsPresentation');
  assert(fn);
  for (const settingsSection of ['', 'ai', 'experiments', 'reading']) {
    const settingsMode = settingsSection !== '';
    const dom = new JSDOM(read('aegis_agent/agent.html'), {url: 'https://agent.invalid/', runScripts: 'outside-only'});
    const w = dom.window; const messages = [];
    w.settingsMode = settingsMode;
    w.settingsSection = settingsSection;
    w.element = id => w.document.getElementById(id);
    w.loadTimeData = {getBoolean: () => false, getString: () => 'Aegis 功能设置'};
    w.ResizeObserver = class {observe() {}};
    w.postMessage = (...args) => messages.push(args);
    w.eval(compile(fn.getText(tree)));
    w.initializeSettingsPresentation();
    const style = w.document.createElement('style');
    const css = read('aegis_agent/agent.css');
    // 提取完整规则区段；后续中文注释不得被截成未闭合注释。
    style.textContent = css.slice(css.indexOf('/* 桌面全局配置集中到设置中心'), css.indexOf('body.initializing main')) +
        css.slice(css.indexOf('#reading-view label:'), css.indexOf('#reading-tabs span'));
    w.document.head.append(style);
    assert.equal(w.getComputedStyle(w.element('reading-minim')).width, '16px');
    assert.equal(w.getComputedStyle(w.element('reading-minim').closest('label')).display, 'flex');
    for (const id of ['model-details','reading-ai-settings','typesafe-details','reading-research-settings']) {
      const expected = settingsSection === 'experiments' ? id === 'reading-research-settings' : settingsSection === 'reading' ? id === 'reading-ai-settings' : settingsSection === 'ai' && ['model-details', 'typesafe-details'].includes(id);
      assert.equal(w.getComputedStyle(w.element(id)).display !== 'none', expected, `${settingsSection}: ${id}`);
      assert.equal(w.element(id).open, expected);
    }
    assert.equal(w.document.body.classList.contains('settings-only'), settingsMode);
    assert.equal(w.document.body.classList.contains('central-settings'), !settingsMode);
    assert.equal(w.element('aegis-settings-link').hidden, settingsMode);
    if (settingsMode) {
      assert(!w.element('goal').hasAttribute('autofocus'));
      assert.equal(messages.length, 1);
      assert.equal(messages[0][0].type, 'aegis-settings-height');
      assert.equal(messages[0][1], 'chrome://settings');
      assert.deepEqual(Object.keys(messages[0][0]).sort(), ['height','type']);
    } else assert.equal(messages.length, 0);
    dom.window.close();
  }
});

test('布局通知只接受当前内部子页，拒绝伪造来源和越界尺寸', () => {
  const tree = ts.createSourceFile('settings.ts', read('settings/aegis_page/aegis_page.ts'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(node => ts.isClassDeclaration(node));
  const handler = cls.members.find(node => node.name?.getText(tree) === 'onFrameMessage_');
  const frame = {contentWindow: {}, classList: {contains: () => false}, style: {height: '320px'}};
  const owner = {shadowRoot: {querySelectorAll: () => [frame]}};
  const code = compile(`const callback = ${handler.initializer.getText(tree)}; return callback;`);
  const onMessage = new Function(code).call(owner);
  const send = patch => onMessage({source: frame.contentWindow, origin: 'chrome://aegis', data: {type: 'aegis-settings-height', height: 800}, ...patch});
  send({origin: 'https://aegis'}); assert.equal(frame.style.height, '320px');
  send({source: {}}); assert.equal(frame.style.height, '320px');
  send({data: {type: 'setModuleEnabled', height: 800}}); assert.equal(frame.style.height, '320px');
  send({}); assert.equal(frame.style.height, '800px');
  send({data: {type: 'aegis-settings-height', height: Infinity}}); assert.equal(frame.style.height, '800px');
  send({data: {type: 'aegis-settings-height', height: -100}}); assert.equal(frame.style.height, '320px');
  send({data: {type: 'aegis-settings-height', height: 1e8}}); assert.equal(frame.style.height, '24000px');
  frame.contentWindow = null;
  send({source: null}); assert.equal(frame.style.height, '24000px');
});

test('设置搜索能找到嵌入分类里的过滤列表、模型密钥、语言包与下载限速', async () => {
  const tree = ts.createSourceFile('settings.ts', read('settings/aegis_page/aegis_page.ts'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(node => ts.isClassDeclaration(node));
  const method = cls.members.find(node => node.name?.getText(tree) === 'searchContents');
  const rootMethod = cls.members.find(node => node.name?.getText(tree) === 'checkedRoot_');
  const checkedRoot = new Function(compile(`return function() ${rootMethod.body.getText(tree)};`))();
  const search = new Function('flush', compile(`return function(query: string) ${method.body.getText(tree)};`))(() => {});
  for (const [mode, terms] of Object.entries({
    privacy: ['过滤列表', '挖矿', 'fingerprint', '過濾規則'],
    ai: ['网页摘要', 'API 密钥', '模型池', 'TypeSafe'],
    reading: ['语言包', 'translation', 'Markdown'],
    experiments: ['实验功能', 'MINIM', 'PhishLang', '段落评分', '實驗模型'],
    downloads: ['限速', '磁力链接', 'DHT'],
    tools: ['工具连接', '权限', 'CDP'],
  })) {
    const owner = {mode, checkedRoot_: checkedRoot, shadowRoot: {textContent: '', querySelectorAll: () => []}};
    for (const query of terms) assert.equal((await search.call(owner, query)).matchCount, 1, `${mode}: ${query}`);
    assert.equal((await search.call(owner, '不存在的功能')).matchCount, 0);
    if (mode === 'ai') assert.equal((await search.call(owner, 'MINIM')).matchCount, 0);
  }
});

test('嵌入设置请求校验来源、接口和参数，读写返回后台结果，离页不回写', async () => {
  const tree = ts.createSourceFile('settings.ts', read('settings/aegis_page/aegis_page.ts'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(node => ts.isClassDeclaration(node));
  const handler = cls.members.find(node => node.name?.getText(tree) === 'onFrameMessage_');
  const forward = cls.members.find(node => node.name?.getText(tree) === 'forwardRequest_');
  const calls = [], replies = [];
  const frame = {isConnected: true, contentWindow: {postMessage: (...args) => replies.push(args)}, classList: {contains: () => false}, style: {}};
  const owner = {isConnected: true, shadowRoot: {querySelectorAll: () => [frame]}};
  owner.forwardRequest_ = new Function('sendWithPromise', compile(`return async function(frame, data) ${forward.body.getText(tree)};`))(async (...args) => {calls.push(args); return {trackerBlocking: args[2] ?? true};});
  const onMessage = new Function(compile(`return ${handler.initializer.getText(tree)};`)).call(owner);
  const data = {type: 'aegis-settings-request', id: 'settings-1', method: 'setModuleEnabled', args: ['trackerBlocking', false]};
  const send = patch => onMessage({source: frame.contentWindow, origin: 'chrome://aegis', data, ...patch});
  send({origin: 'https://aegis'}); send({source: {}});
  assert.equal(calls.length, 0);
  send({}); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls, [['setModuleEnabled', 'trackerBlocking', false]]);
  assert.deepEqual(replies[0], [{type: 'aegis-settings-response', id: 'settings-1', result: {trackerBlocking: false}}, 'chrome://aegis']);
  for (const bad of [{method: 'deleteProfile'}, {method: 'toString'}, {args: ['trackerBlocking', 'false']}, {id: '__proto__'}]) send({data: {...data, ...bad}});
  assert.equal(calls.length, 1);
  owner.isConnected = false;
  const before = replies.length; send({}); await new Promise(resolve => setImmediate(resolve));
  assert.equal(replies.length, before);
});

test('子页通过父框架获取并保存设置，不直接调用无效的 chrome.send', async () => {
  const tree = ts.createSourceFile('aegis.ts', read('aegis/aegis.ts'), ts.ScriptTarget.Latest, true);
  const request = tree.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.text === 'requestSettings');
  const messages = [], pending = new Map();
  const run = new Function('parent', 'window', 'settingsRequests', compile(`const embeddedSettings = true; let settingsRequestId = 0; ${request.getText(tree)} return requestSettings;`))(
    {postMessage: (...args) => messages.push(args)}, {setTimeout: () => 1}, pending);
  const promise = run('getStatus');
  assert.deepEqual(messages[0], [{type: 'aegis-settings-request', id: 'settings-1', method: 'getStatus', args: []}, 'chrome://settings']);
  pending.get('settings-1').resolve({trackerBlocking: true});
  assert.deepEqual(await promise, {trackerBlocking: true});
});

function downloadsSettings() {
  const tree = ts.createSourceFile('downloads.ts', read('settings/downloads_page/downloads_page.ts'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(node => ts.isClassDeclaration(node));
  const owner = {aegisSettingsReady_: true, aegisSaveChain_: Promise.resolve(), aegisSaveGeneration_: 0, aegisStrings_: {saving: '保存中', saved: '已保存', failed: '失败'}};
  for (const name of ['applyAegisDownloadSettings_', 'currentAegisDownloadSettings_', 'saveAegisDownloadSettings_', 'loadAegisDownloadSettings_', 'onAegisLimitChange_']) {
    const method = cls.members.find(node => node.name?.getText(tree) === name);
    owner[name] = new Function(compile(`return ${method.modifiers?.some(n => n.kind === ts.SyntaxKind.AsyncKeyword) ? 'async ' : ''}function(${method.parameters.map(n => n.getText(tree)).join(',')}) ${method.body.getText(tree)};`))();
  }
  return owner;
}

test('下载模板的全部事件回调保留组件上下文和实际事件控件', () => {
  const tree = ts.createSourceFile('downloads.html.ts', read('settings/downloads_page/downloads_page.html.ts'), ts.ScriptTarget.Latest, true);
  const callbacks = [];
  function visit(node) {
    if (ts.isArrowFunction(node) && ts.isBlock(node.body) && node.body.statements.length === 1) {
      const statement = node.body.statements[0];
      const call = ts.isExpressionStatement(statement) && statement.expression;
      if (call && ts.isCallExpression(call) && ts.isPropertyAccessExpression(call.expression) && call.expression.expression.kind === ts.SyntaxKind.ThisKeyword) {
        callbacks.push({node, method: call.expression.name.text, passesEvent: call.arguments.length === 1});
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(tree);
  assert.equal(callbacks.length, 10);
  assert.equal(new Set(callbacks.map(item => item.method)).size, 7);
  const dom = new JSDOM();
  const select = dom.window.document.createElement('select'), button = dom.window.document.createElement('button');
  select.append(new dom.window.Option('自定义', 'custom'));
  dom.window.document.body.append(select, button);
  for (const {node, method, passesEvent} of callbacks) {
    const calls = [];
    const owner = Object.fromEntries([[method, function(event) { calls.push({owner: this, target: event?.currentTarget}); }]]);
    const callback = new Function('owner', compile(`function bind() { return ${node.getText(tree)}; } return bind.call(owner);`))(owner);
    const control = dom.window.document.querySelector(passesEvent ? 'select' : 'button');
    const type = passesEvent ? 'change' : 'click';
    control.addEventListener(type, callback);
    control.dispatchEvent(new dom.window.Event(type));
    control.removeEventListener(type, callback);
    assert.deepEqual(calls, [{owner, target: passesEvent ? control : undefined}], method);
  }
  dom.window.close();
});

test('下载限速模式只接受真实选择控件，正常切换仍保存相同数值', () => {
  const tree = ts.createSourceFile('downloads.ts', read('settings/downloads_page/downloads_page.ts'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(node => ts.isClassDeclaration(node));
  const method = cls.members.find(node => node.name?.getText(tree) === 'onAegisLimitModeChange_');
  const dom = new JSDOM('', {runScripts: 'outside-only'});
  const select = dom.window.document.createElement('select'), button = dom.window.document.createElement('button');
  select.id = 'aegisDownloadMode';
  select.append(new dom.window.Option('不限速', 'unlimited'), new dom.window.Option('自定义', 'custom'));
  dom.window.document.body.append(select, button);
  // 在控件所属 DOM 环境执行真实处理器，让 instanceof 检查使用同一组构造器。
  const run = vm.runInContext(compile(`(function(event: Event) ${method.body.getText(tree)});`), dom.getInternalVMContext());
  const saved = [], owner = {aegisTorrentDownloadLimitKib_: 128, aegisTorrentUploadLimitKib_: 64,
    saveAegisDownloadSettings_() { saved.push([this.aegisTorrentDownloadLimitKib_, this.aegisTorrentUploadLimitKib_]); }};
  select.value = 'unlimited'; run.call(owner, {currentTarget: select});
  select.value = 'custom'; run.call(owner, {currentTarget: select});
  select.id = 'aegisUploadMode'; select.value = 'unlimited'; run.call(owner, {currentTarget: select});
  select.value = 'custom'; run.call(owner, {currentTarget: select});
  for (const currentTarget of [null, dom.window.document.querySelector('button')]) run.call(owner, {currentTarget});
  assert.deepEqual(saved, [[0, 64], [256, 64], [256, 0], [256, 256]]);
  dom.window.close();
});

for (const file of ['aegis/aegis.ts', 'aegis_agent/agent.ts']) {
  test(`${file} 搜索消息逐层拒绝伪造来源，合法搜索仍展开并定位`, () => {
    const tree = ts.createSourceFile('settings.ts', read(file), ts.ScriptTarget.Latest, true);
    const statement = tree.statements.find(node => ts.isExpressionStatement(node) && node.getText(tree).startsWith("window.addEventListener('message'"));
    assert(statement);
    const callbackName = statement.expression.arguments[1].getText(tree);
    const callback = tree.statements.find(node => ts.isFunctionDeclaration(node) && node.name?.getText(tree) === callbackName);
    assert(callback, '消息监听器使用真实的具名处理函数');
    const dom = new JSDOM('', {runScripts: 'outside-only'});
    const document = dom.window.document, parent = dom.window.parent;
    const previous = document.createElement('p'), details = document.createElement('details');
    const summary = document.createElement('summary'), label = document.createElement('label');
    previous.dataset.searchMatch = 'true'; previous.textContent = '旧结果';
    summary.textContent = '模型'; label.textContent = '模型密钥';
    details.append(summary, label); document.body.append(previous, details);
    let scrolled = 0;
    label.scrollIntoView = () => { ++scrolled; };
    const receive = vm.runInContext(compile(`(${callback.getText(tree)});`), dom.getInternalVMContext());
    const valid = {source: parent, origin: 'chrome://settings', data: {type: 'aegis-settings-search', query: ' 密钥 '}};
    for (const change of [{source: {}}, {origin: 'https://settings'}, {origin: 'chrome://settings.evil'},
      {data: null}, {data: {type: 'other', query: '密钥'}}, {data: {type: 'aegis-settings-search', query: 1}}]) {
      receive({...valid, ...change});
      assert.equal(document.querySelector('[data-search-match]').textContent, '旧结果');
      assert.equal(scrolled, 0);
    }
    receive(valid);
    assert.equal(document.querySelector('[data-search-match]'), label);
    assert.equal(document.querySelector('details').open, true);
    assert.equal(scrolled, 1);
    receive({...valid, data: {...valid.data, query: ''}});
    assert.equal(document.querySelector('[data-search-match]'), null);
    dom.window.close();
  });
}

const initialDownloads = () => ({parallelMode: 3, reduceOnMetered: false, reduceOnBattery: true, torrentDhtEnabled: false, torrentPexEnabled: true, torrentDownloadLimitKib: 128, torrentUploadLimitKib: 64});

test('全局下载参数串行保存并使用后台读回结果，拒绝非法限速', async () => {
  const owner = downloadsSettings();
  let stored = initialDownloads();
  const saves = [];
  owner.browserProxy_ = {getAegisDownloadSettings: async () => stored, setAegisDownloadSettings: async settings => {saves.push(settings); stored = settings; return stored;}};
  await owner.loadAegisDownloadSettings_();
  assert.deepEqual(owner.currentAegisDownloadSettings_(), stored);
  const invalid = {id: 'aegisTorrentDownloadLimit', value: '257.9'};
  owner.onAegisLimitChange_({currentTarget: invalid});
  assert.equal(invalid.invalid, true);
  assert.equal(owner.aegisTorrentDownloadLimitKib_, 128);
  owner.onAegisLimitChange_({currentTarget: {id: 'aegisTorrentDownloadLimit', value: '257'}});
  owner.onAegisLimitChange_({currentTarget: {id: 'aegisTorrentUploadLimit', value: '129'}});
  await owner.aegisSaveChain_;
  assert.equal(saves.length, 2);
  assert.equal(stored.torrentDownloadLimitKib, 257);
  assert.equal(stored.torrentUploadLimitKib, 129);
  assert.equal(stored.parallelMode, 3);
  assert.equal(owner.aegisSaveStatus_, '已保存');
  owner.browserProxy_.setAegisDownloadSettings = async () => {throw Error('拒绝保存');};
  owner.onAegisLimitChange_({currentTarget: {id: 'aegisTorrentUploadLimit', value: '999'}});
  await owner.aegisSaveChain_;
  assert.equal(owner.aegisTorrentUploadLimitKib_, 129);
  assert.equal(owner.aegisSaveStatus_, '失败');
});

for (const reloadFails of [false, true]) {
  test(`下载保存冲突作废后续排队草稿，回读${reloadFails ? '失败可重试' : '成功与后台一致'}`, async () => {
    const owner = downloadsSettings();
    let stored = initialDownloads();
    let reads = 0;
    const saves = [];
    owner.browserProxy_ = {
      getAegisDownloadSettings: async () => {
        if (++reads === 2 && reloadFails) throw Error('读取失败');
        return {...stored};
      },
      setAegisDownloadSettings: async (settings, expected) => {
        saves.push({settings, expected});
        if (saves.length === 1) {
          stored = {...stored, parallelMode: 6}; // 另一窗口先保存了新值。
          throw Error('settings_changed');
        }
        assert.deepEqual(expected, stored);
        stored = {...settings};
        return {...stored};
      },
    };
    await owner.loadAegisDownloadSettings_();
    owner.onAegisLimitChange_({currentTarget: {id: 'aegisTorrentDownloadLimit', value: '257'}});
    owner.onAegisLimitChange_({currentTarget: {id: 'aegisTorrentUploadLimit', value: '129'}});
    await owner.aegisSaveChain_;
    assert.equal(saves.length, 1, '冲突后不得继续写入已作废的排队草稿');
    assert.deepEqual(stored, {...initialDownloads(), parallelMode: 6});
    assert.equal(owner.aegisSaveStatus_, '失败');
    assert.equal(owner.aegisSettingsReady_, !reloadFails);
    if (reloadFails) {
      owner.saveAegisDownloadSettings_();
      await owner.aegisSaveChain_;
      assert.equal(saves.length, 1, '未恢复可信设置前禁止继续保存');
      await owner.loadAegisDownloadSettings_();
    }
    assert.deepEqual(owner.currentAegisDownloadSettings_(), stored);
    owner.onAegisLimitChange_({currentTarget: {id: 'aegisTorrentUploadLimit', value: '513'}});
    await owner.aegisSaveChain_;
    assert.equal(saves.length, 2);
    assert.deepEqual(stored, {...initialDownloads(), parallelMode: 6, torrentUploadLimitKib: 513});
    assert.deepEqual(owner.currentAegisDownloadSettings_(), stored);
    assert.equal(owner.aegisSaveStatus_, '已保存');
  });
}

test('新任务预览使用后台刚读取的下载默认值，不沿用页面打开时的缓存', () => {
  const path = new URL('../../overlay/ui/webui/resources/cr_components/aegis_downloads/aegis_download_panel.ts', import.meta.url);
  const tree = ts.createSourceFile('panel.ts', fs.readFileSync(path, 'utf8'), ts.ScriptTarget.Latest, true);
  const cls = tree.statements.find(node => ts.isClassDeclaration(node));
  const method = cls.members.find(node => node.name?.getText(tree) === 'setTorrentPreview_');
  const run = new Function('formatBytes', 'document', compile(`return function(preview, zh) ${method.body.getText(tree)};`))(() => '0', {documentElement: {lang: 'zh-CN'}});
  const owner = {torrentDhtDefault_: true, torrentPexDefault_: true, torrentDownloadLimitDefault_: 0, torrentUploadLimitDefault_: 256};
  run.call(owner, {ok: true, requestId: 'preview', name: '验收', defaultDhtEnabled: false, defaultPexEnabled: false, defaultDownloadLimitKib: 257, defaultUploadLimitKib: 129}, true);
  assert.equal(owner.torrentDhtDefault_, false);
  assert.equal(owner.torrentPexDefault_, false);
  assert.equal(owner.torrentDownloadLimitDefault_, 257);
  assert.equal(owner.torrentUploadLimitDefault_, 129);
  run.call(owner, {ok: true, requestId: 'second', defaultDhtEnabled: true, defaultPexEnabled: true, defaultDownloadLimitKib: 0, defaultUploadLimitKib: 256}, true);
  assert.equal(owner.torrentDownloadLimitDefault_, 0);
  assert.equal(owner.torrentUploadLimitDefault_, 256);
});
