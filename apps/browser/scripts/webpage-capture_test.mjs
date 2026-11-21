// 执行实际截图与 OCR 页面逻辑；这些边界测试不能替代候选 App 的实机验收。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import {JSDOM} from 'jsdom';

const resources = new URL('../overlay/chrome/browser/resources/aegis/', import.meta.url);
const captureSource = readFileSync(new URL('capture.js', resources), 'utf8')
  .replace(/^import .*;\n/m, '')
  .replace("startPreview().catch(() => status('unavailable'));", '');

function capture() {
  const dom = new JSDOM(readFileSync(new URL('capture.html', resources), 'utf8'));
  const {document} = dom.window;
  const source = document.getElementById('source');
  Object.defineProperties(source, {naturalWidth: {value: 100, configurable: true},
    naturalHeight: {value: 80, configurable: true}});
  source.getBoundingClientRect = () => ({left: 10, top: 20, width: 50, height: 40});
  const draws = [], requests = [];
  dom.window.HTMLCanvasElement.prototype.getContext = () => ({drawImage: (...args) => draws.push(args.slice(1))});
  dom.window.HTMLCanvasElement.prototype.toBlob = function(callback) {
    callback(new Blob(['pixels'], {type: 'image/png'}));
  };
  const dialog = document.getElementById('confirmation');
  dialog.showModal = () => { dialog.open = true; };
  dialog.close = () => { dialog.open = false; dialog.onclose?.(); };
  const context = vm.createContext({document, window: dom.window, navigator: {language: 'zh-CN'},
    Blob, URL, ResizeObserver: class { observe() {} },
    sendWithPromise: async (...args) => { requests.push(args); return {ok: true, text: '确认后的结果'}; }});
  vm.runInContext(captureSource, context);
  return {context, document, source, draws, requests};
}

test('裁剪使用原图坐标，缩放和反向拖动不改变像素范围', async () => {
  const page = capture();
  vm.runInContext('selection = {left: .25, top: .25, right: .75, bottom: .75}', page.context);
  assert.equal((await page.context.capturePNG()).type, 'image/png');
  assert.deepEqual(page.draws, [[25, 20, 50, 40, 0, 0, 50, 40]]);
  assert.deepEqual(Array.from(page.context.position({clientX: -10, clientY: 100})), [0, 1]);
});

test('空选区和过大 OCR 输入不创建像素副本', async () => {
  const page = capture();
  vm.runInContext('selection = {left: 0, top: 0, right: 0, bottom: 1}', page.context);
  assert.equal(await page.context.capturePNG(true), null);
  vm.runInContext('selection = undefined', page.context);
  Object.defineProperty(page.source, 'naturalWidth', {value: 8193});
  assert.equal(await page.context.capturePNG(true), null);
  Object.defineProperties(page.source, {naturalWidth: {value: 4000}, naturalHeight: {value: 4000}});
  assert.equal(await page.context.capturePNG(true), null);
  assert.equal(page.draws.length, 0);
});

test('服务器识别拒绝合成点击和取消后的旧图片', async () => {
  const page = capture();
  page.context.addEvents();
  vm.runInContext('requestImage = "fixture-pixels"', page.context);
  const send = page.document.getElementById('send');
  await send.onclick({preventDefault() {}, isTrusted: false});
  assert.deepEqual(page.requests, []);
  page.document.getElementById('confirmation').close();
  await send.onclick({preventDefault() {}, isTrusted: true});
  assert.deepEqual(page.requests, []);
});

test('已确认上传只发本次图片，异步完成后恢复控件', async () => {
  const page = capture();
  page.context.addEvents();
  vm.runInContext('requestImage = "fixture-pixels"', page.context);
  await page.document.getElementById('send').onclick({preventDefault() {}, isTrusted: true});
  assert.deepEqual(page.requests, [['aegisCaptureRemoteOCRRequiringGesture', 'fixture-pixels']]);
  assert.equal(page.document.getElementById('text').value, '确认后的结果');
  assert.equal(page.document.getElementById('server').disabled, false);
  await page.document.getElementById('send').onclick({preventDefault() {}, isTrusted: true});
  assert.equal(page.requests.length, 1);
});

function offline({fail = false} = {}) {
  const messages = [], workers = [], events = new Map();
  let terminated = 0;
  const parent = {postMessage: (...args) => messages.push(args)};
  const window = {addEventListener: (name, fn) => events.set(name, fn), removeEventListener: name => events.delete(name)};
  const context = vm.createContext({parent, window, Blob, URL,
    location: {href: 'chrome-untrusted://aegis-ocr/'},
    Tesseract: {createWorker: async (...args) => {
      workers.push(args);
      return {recognize: async () => { if (fail) throw new Error('fixture'); return {data: {text: ' 中文\nEnglish '}}; },
        terminate: async () => { terminated++; }};
    }}});
  vm.runInContext(readFileSync(new URL('offline_ocr.js', resources), 'utf8'), context);
  return {context, parent, messages, workers, events, terminated: () => terminated};
}

test('离线 OCR 拒绝错误来源、窗口、格式和超大输入', async () => {
  const page = offline();
  const image = new Blob(['pixels'], {type: 'image/png'});
  const valid = {origin: 'chrome://aegis-capture', source: page.parent, data: {image}};
  for (const event of [{...valid, origin: 'https://attacker.invalid'}, {...valid, source: {}},
    {...valid, data: {image: new Blob(['x'], {type: 'image/jpeg'})}},
    {...valid, data: {image: new Blob([], {type: 'image/png'})}},
    {...valid, data: {image: new Blob([new Uint8Array(8 * 1024 * 1024 + 1)], {type: 'image/png'})}}]) {
    await page.context.recognize(event);
  }
  assert.equal(page.workers.length, 0);
  assert.equal(page.messages.length, 1); // 只有初始化 ready，无识别结果。
});

test('离线 OCR 只载入随包资源，完成后释放 worker', async () => {
  const page = offline();
  await page.context.recognize({origin: 'chrome://aegis-capture', source: page.parent,
    data: {image: new Blob(['pixels'], {type: 'image/png'}), traditional: true}});
  assert.deepEqual(Array.from(page.workers[0][0]), ['chi_tra', 'eng', 'chi_sim']);
  const options = page.workers[0][2];
  for (const name of ['workerPath', 'corePath', 'langPath']) assert.ok(options[name].startsWith('chrome-untrusted://aegis-ocr/ocr_assets/'));
  assert.equal(options.workerBlobURL, false);
  assert.equal(page.messages.at(-1)[0].text, '中文\nEnglish');
  assert.equal(page.messages.at(-1)[1], 'chrome://aegis-capture');
  assert.equal(page.terminated(), 1);
  assert.equal(page.events.has('message'), false);
});

test('离线识别失败返回明确空结果并释放 worker', async () => {
  const page = offline({fail: true});
  await page.context.recognize({origin: 'chrome://aegis-capture', source: page.parent,
    data: {image: new Blob(['pixels'], {type: 'image/png'})}});
  assert.equal(page.messages.at(-1)[0].text, null);
  assert.equal(page.terminated(), 1);
});
