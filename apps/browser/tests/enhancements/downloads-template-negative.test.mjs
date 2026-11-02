import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {JSDOM} from 'jsdom';
import {downloadBindings, assertDownloadDispatch} from './downloads-template-bindings.mjs';
const ts = createRequire(new URL('../../../../packages/core/package.json', import.meta.url))('typescript');
const source = fs.readFileSync(new URL('../../overlay/chrome/browser/resources/settings/downloads_page/downloads_page.html.ts', import.meta.url), 'utf8');
test('wrong receiver, binding, missing and extra callbacks are rejected', () => {
  assert.equal(downloadBindings(ts, source).length, 10);
  for (const [name, changed] of [
    ['receiver', source.replace('this.onAegisRetryClick_', 'other.onAegisRetryClick_')],
    ['eager call', source.replace('this.onAegisRetryClick_', 'this.onAegisRetryClick_()')],
    ['inline arrow', source.replace('this.onAegisRetryClick_', '() => this.onAegisRetryClick_()')],
    ['missing', source.replace('@click="${this.onAegisRetryClick_}"', '')],
    ['extra', source.replace('@click="${this.onAegisRetryClick_}"', '@click="${this.onAegisRetryClick_}" @click="${this.onAegisRetryClick_}"')],
    ['wrong target', source.replace('this.onAegisRetryClick_', 'this.onUnknown_')],
    ['wrong control', source.replace('<cr-toggle id="aegisReduceOnMetered"', '<cr-input id="aegisReduceOnMetered"')],
    ['wrong control id', source.replace('id="aegisReduceOnMetered"', 'id="aegisUnknown"')],
    ['wrong event', source.replace('@click="${this.onAegisRetryClick_}"', '@change="${this.onAegisRetryClick_}"')],
  ]) assert.throws(() => downloadBindings(ts, changed), undefined, name);
});
test('dispatch rejects control receiver, missing event and incorrect control', () => {
  const dom = new JSDOM();
  try {
    const control = dom.window.document.createElement('select');
    control.append(new dom.window.Option('custom', 'custom'));
    const owner = {};
    let event, calls;
    control.addEventListener('change', actual => {
      event = actual;
      calls = [{owner, event, target: event.currentTarget, value: event.currentTarget.value}];
      assertDownloadDispatch(owner, control, event, calls);
    });
    control.dispatchEvent(new dom.window.Event('change'));
    assert.throws(() => assertDownloadDispatch(owner, control, event, [{...calls[0], owner: control}]));
    assert.throws(() => assertDownloadDispatch(owner, control, event, [{...calls[0], event: undefined}]));
    assert.throws(() => assertDownloadDispatch(owner, control, event, [{...calls[0], target: owner}]));
    assert.throws(() => assertDownloadDispatch(owner, control, event, []));
    assert.throws(() => assertDownloadDispatch(owner, control, event, [...calls, ...calls]));
  } finally { dom.window.close(); }
});


test('real id cannot be replaced by lookalike attributes or quoted text', t => {
  const original = 'id="aegisReduceOnMetered"';
  for (const [name, replacement] of [
    ['data-id only', 'data-id="aegisReduceOnMetered"'],
    ['aria-id only', 'aria-id="aegisReduceOnMetered"'],
    ['prefixed id only', 'other-id="aegisReduceOnMetered"'],
    ['missing id', ''],
    ['empty id', 'id=""'],
    ['boolean id', 'id'],
    ['double-quoted fake id in another value', `title='id="aegisReduceOnMetered"'`],
    ['single-quoted fake id in another value', `title="id='aegisReduceOnMetered'"`],
    ['fake tag and id inside quoted value', `title='<cr-toggle id="aegisReduceOnMetered">'`],
    ['data-id plus quoted fake id', `data-id="aegisReduceOnMetered" title=' id="aegisReduceOnMetered"'`],
    ['wrong real id plus matching data-id', 'data-id="aegisReduceOnMetered" id="aegisWrong"'],
  ]) {
    const changed = source.replace(original, replacement);
    assert.notEqual(changed, source, name);
    assert.throws(() => downloadBindings(ts, changed), undefined, name);
    t.diagnostic(name);
  }
});

test('real id survives unrelated attributes, quoting and attribute order', t => {
  const original = 'id="aegisReduceOnMetered"';
  for (const [name, replacement] of [
    ['data-id before real id', 'data-id="unrelated" id="aegisReduceOnMetered"'],
    ['data-id after real id', 'id="aegisReduceOnMetered" data-id="unrelated"'],
    ['aria-id before real id', 'aria-id="unrelated" id="aegisReduceOnMetered"'],
    ['single quotes', "id='aegisReduceOnMetered'"],
    ['unquoted value', 'id=aegisReduceOnMetered'],
    ['whitespace around equals', 'id \n = \t "aegisReduceOnMetered"'],
    ['quoted fake id before real id', `title='id="unrelated"' id="aegisReduceOnMetered"`],
    ['quoted tag before real id', `title='<cr-input id="unrelated">' id="aegisReduceOnMetered"`],
  ]) {
    const changed = source.replace(original, replacement);
    assert.notEqual(changed, source, name);
    const bindings = downloadBindings(ts, changed);
    assert.equal(bindings.length, 10, name);
    assert.equal(bindings[4].id, 'aegisReduceOnMetered', name);
    t.diagnostic(name);
  }
});


test('extra unquoted Lit events and invalid unquoted callbacks are rejected', t => {
  const parallel = '@change="${this.onAegisParallelModeChange_}"';
  const retry = '@click="${this.onAegisRetryClick_}"';
  for (const [name, original, replacement] of [
    ['R83 extra unquoted click on parallel-mode select', parallel, parallel + ' @click=${this.onAegisRetryClick_}'],
    ['extra unquoted event type', parallel, parallel + ' @pointerdown=${this.onAegisRetryClick_}'],
    ['extra quoted event type', parallel, parallel + ' @pointerdown="${this.onAegisRetryClick_}"'],
    ['duplicate unquoted event', retry, retry + ' @click=${this.onAegisRetryClick_}'],
    ['unquoted wrong receiver', retry, '@click=${other.onAegisRetryClick_}'],
    ['unquoted eager call', retry, '@click=${this.onAegisRetryClick_()}'],
    ['unquoted arrow', retry, '@click=${() => this.onAegisRetryClick_()}'],
    ['case-sensitive event name', retry, '@CLICK=${this.onAegisRetryClick_}'],
    ['different unquoted event name', parallel, '@input=${this.onAegisParallelModeChange_}'],
  ]) {
    const changed = source.replace(original, replacement);
    assert.notEqual(changed, source, name);
    assert.throws(() => downloadBindings(ts, changed), undefined, name);
    t.diagnostic(name);
  }
});

test('valid event quoting forms retain exact real controls and dispatch', t => {
  const retry = '@click="${this.onAegisRetryClick_}"';
  const parallel = '@change="${this.onAegisParallelModeChange_}"';
  const cases = [
    ['unquoted click', source.replace(retry, '@click=${this.onAegisRetryClick_}')],
    ['unquoted change', source.replace(parallel, '@change=${this.onAegisParallelModeChange_}')],
    ['single-quoted event', source.replace(retry, "@click='${this.onAegisRetryClick_}'")],
    ['unquoted with HTML whitespace', source.replace(retry, '@click \n = \t ${this.onAegisRetryClick_}')],
    ['all ten unquoted', source.replace(/@(click|change)="(\$\{this\.[A-Za-z0-9_]+\})"/g, '@$1=$2')],
    ['event text in ordinary attribute', source.replace(parallel, parallel + ` title=" @click='${'${this.aegisStrings_.parallel}'}'"`)],
    ['event text in HTML text', source.replace('</settings-section>', `text @click="${'${this.aegisStrings_.parallel}'}"</settings-section>`) ],
    ['event text in comment', source.replace('</settings-section>', `<!-- @click="${'${this.aegisStrings_.parallel}'}" --></settings-section>`) ],
  ];
  const expected = downloadBindings(ts, source).map(({type, method, tag, id}) => ({type, method, tag, id}));
  const dom = new JSDOM();
  try {
    for (const [name, changed] of cases) {
      assert.notEqual(changed, source, name);
      const bindings = downloadBindings(ts, changed);
      assert.deepEqual(bindings.map(({type, method, tag, id}) => ({type, method, tag, id})), expected, name);
      for (const {type, method, markup} of bindings) {
        const template = dom.window.document.createElement('template');
        template.innerHTML = markup;
        const control = template.content.firstElementChild;
        assert(control, name);
        if (control.localName === 'select') {
          if (!control.querySelector('option[value="custom"]')) control.append(new dom.window.Option('custom', 'custom'));
          control.value = 'custom';
        } else control.value = '128';
        control.id = control.id.replace('${kind}', 'Download');
        const calls = [];
        const owner = {[method]: function(event) {
          calls.push({owner: this, event, target: event.currentTarget, value: event.currentTarget.value});
        }};
        control.addEventListener(type, event => owner[method].call(owner, event));
        const event = new dom.window.Event(type);
        control.dispatchEvent(event);
        assertDownloadDispatch(owner, control, event, calls);
      }
      t.diagnostic(name);
    }
  } finally { dom.window.close(); }
});
