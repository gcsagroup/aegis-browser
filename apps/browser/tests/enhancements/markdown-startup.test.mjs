import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {JSDOM} from 'jsdom';

const root = new URL('../../overlay/chrome/browser/resources/aegis/', import.meta.url);
const read = path => fs.readFileSync(new URL(path, root), 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));

function harness() {
  const parent = new JSDOM(read('markdown.html'), {
    url: 'chrome://aegis/markdown.html', runScripts: 'outside-only',
  });
  const child = new JSDOM(read('enhancements_shared/viewer.html'), {
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
    queueMicrotask(() => c.dispatchEvent(new c.MessageEvent('message', {
      source: p, origin: 'chrome://aegis', data,
    })));
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
    startChild() {
      for (const script of ['vendor/markdown-it.min.js', 'vendor/task-lists.min.js',
        'vendor/highlight.min.js', 'vendor/purify.min.js', 'i18n.js', 'core.js', 'viewer.js'])
        c.eval(read('enhancements_shared/' + script));
    },
    async startParent() {
      p.eval(read('enhancements_shared/i18n.js'));
      p.eval(read('enhancements_shared/core.js'));
      const code = read('markdown.js').replace(/^import .*;\n/gm, '');
      await p.eval(`(async () => { ${code}\n })()`);
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
    assert.equal(h.messages.at(-1).type, 'ready');
  } finally { h.close(); }
});
