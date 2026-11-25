import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {runInContext} from 'node:vm';
import {JSDOM} from 'jsdom';

const root = new URL('../../overlay/chrome/browser/resources/aegis/', import.meta.url);
function readResource(name) {
  const resource = new URL(name, root);
  assert.ok(resource.href.startsWith(root.href), 'Test resource must be inside the Aegis overlay');
  // The tests select checked-in resources relative to this module's overlay.
  return fs.readFileSync(resource, 'utf8'); // nosemgrep: javascript_pathtraversal_rule-non-literal-fs-filename
}

const parentHTML = readResource('markdown.html');
const childHTML = readResource('enhancements_shared/viewer.html');
const parentScript = readResource('markdown.js').replace(/^import .*;\n/gm, '');
const sharedScripts = [
  readResource('enhancements_shared/i18n.js'),
  readResource('enhancements_shared/core.js'),
];
const childScripts = [
  readResource('enhancements_shared/vendor/markdown-it.min.js'),
  readResource('enhancements_shared/vendor/task-lists.min.js'),
  readResource('enhancements_shared/vendor/highlight.min.js'),
  readResource('enhancements_shared/vendor/purify.min.js'),
  ...sharedScripts,
  readResource('enhancements_shared/viewer.js'),
];
const tick = () => new Promise(resolve => setImmediate(resolve));

function harness({holdReadyRequest = false} = {}) {
  let pendingReadyRequest;
  const parent = new JSDOM(parentHTML, {
    url: 'chrome://aegis/markdown.html', runScripts: 'outside-only',
  });
  const child = new JSDOM(childHTML, {
    url: 'chrome-untrusted://aegis-markdown/viewer.html', runScripts: 'outside-only',
  });
  const p = parent.window, c = child.window;
  const messages = [], requests = [];
  Object.defineProperty(p.document.getElementById('reader'), 'contentWindow', {value: c});
  Object.defineProperty(c, 'parent', {value: p});
  p.postMessage = (data, target) => {
    assert.equal(target, 'chrome://aegis');
    messages.push(data);
    queueMicrotask(() => p.dispatchEvent(new p.MessageEvent('message', {
      source: c, origin: 'chrome-untrusted://aegis-markdown', data,
    })));
  };
  c.postMessage = (data, target) => {
    assert.equal(target, 'chrome-untrusted://aegis-markdown');
    const deliver = () => c.dispatchEvent(new c.MessageEvent('message', {
      source: p, origin: 'chrome://aegis', data,
    }));
    if (holdReadyRequest && data.type === 'ready-request') pendingReadyRequest = deliver;
    else queueMicrotask(deliver);
  };
  for (const w of [p, c]) {
    w.TextEncoder = TextEncoder;
    w.matchMedia = () => ({matches: false});
    w.HTMLElement.prototype.scrollIntoView = () => {};
    Object.defineProperty(w.navigator, 'language', {value: 'zh-CN'});
  }
  p.loadTimeData = {getString: () => 'zh-CN'};
  p.sendWithPromise = async (_, request) => {
    requests.push(request.op);
    if (request.op === 'state') return {tabs: []};
    if (request.op === 'take-markdown') return {
      title: 'first.md', text: '# 首次打开\n<script>window.unsafe=1</script>',
      baseURL: 'file:///first.md', local: true,
    };
    return {};
  };
  return {
    p, c, messages, requests,
    deliverReadyRequest() { pendingReadyRequest(); },
    startChild() {
      const context = child.getInternalVMContext();
      for (const script of childScripts) runInContext(script, context);
    },
    async startParent() {
      const context = parent.getInternalVMContext();
      for (const script of sharedScripts) runInContext(script, context);
      // Run the checked-in entry point with the mocked Chrome imports above.
      await runInContext(`(async () => { ${parentScript}\n })()`, context, {filename: 'markdown.js'});
    },
    close() { p.close(); c.close(); },
  };
}

for (const first of ['child', 'parent']) {
  test(`Markdown first load survives ${first} initializing first`, async () => {
    const h = harness();
    try {
      if (first === 'child') {
        h.startChild();
        await tick(); // The initial ready notification precedes the parent listener.
        await h.startParent();
      } else {
        await h.startParent();
        await tick(); // The readiness request precedes the child listener.
        h.startChild();
      }
      await tick();
      assert.equal(h.c.document.querySelector('#document h1')?.textContent, '首次打开');
      assert.equal(h.requests.filter(op => op === 'take-markdown').length, 1);
      assert.equal(h.c.unsafe, undefined);
      assert.equal(h.c.document.querySelector('#document script'), null);
    } finally { h.close(); }
  });
}

test('Markdown readiness handshake rejects another origin or window', async () => {
  const h = harness();
  try {
    h.startChild();
    await tick();
    const before = h.messages.length;
    for (const event of [
      {source: h.p, origin: 'https://untrusted.invalid'},
      {source: h.c, origin: 'chrome://aegis'},
    ]) h.c.dispatchEvent(new h.c.MessageEvent('message', {
      ...event, data: {type: 'ready-request'},
    }));
    await tick();
    assert.equal(h.messages.length, before);
    h.c.dispatchEvent(new h.c.MessageEvent('message', {
      source: h.p, origin: 'chrome://aegis', data: {type: 'ready-request'},
    }));
    await tick();
    assert.equal(h.messages.length, before + 1);
    assert.equal(h.messages.at(-1).type, 'ready-response');
  } finally { h.close(); }
});

test('a delayed readiness reply preserves the open Markdown view', async () => {
  const h = harness({holdReadyRequest: true});
  try {
    await h.startParent();
    h.startChild();
    await tick();
    const rendered = h.messages.filter(message => message.type === 'images').length;
    assert.equal(rendered, 1);
    const source = h.c.document.getElementById('source');
    h.c.document.getElementById('source-toggle').click();
    assert.equal(source.hidden, false);
    h.deliverReadyRequest();
    await tick();
    assert.equal(source.hidden, false);
    assert.equal(h.messages.filter(message => message.type === 'images').length, rendered);
  } finally { h.close(); }
});
