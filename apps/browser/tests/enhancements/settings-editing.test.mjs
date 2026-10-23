import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {JSDOM} from 'jsdom';
const ts = createRequire(new URL('../../../../packages/core/package.json', import.meta.url))('typescript');
const root = new URL('../../overlay/chrome/browser/resources/settings/aegis_page/', import.meta.url);
const source = fs.readFileSync(new URL('aegis_page.ts', root), 'utf8');
const tree = ts.createSourceFile('page.ts', source, ts.ScriptTarget.Latest, true);
const cls = tree.statements.find(node => ts.isClassDeclaration(node));
const names = ['checkedRoot_','element_','message_','status_','input_','button_','source_','initializeReading_','previewReading_',
  'saveReading_','addMarkdownSite_','renderMarkdownSites_','initializeRules_','ruleScope_','editRule_','saveRule_','renderRules_'];
const methods = cls.members.filter(node => names.includes(node.name?.getText(tree)));
assert.equal(methods.length, names.length);
const code = ts.transpileModule('class Harness {' + methods.map(node => node.getText(tree)).join('\n') + '}\nglobalThis.Harness=Harness;', {compilerOptions: {target: ts.ScriptTarget.ES2022}}).outputText;
const flush = () => new Promise(resolve => setImmediate(resolve));
function harness(state = {}) {
  const html = fs.readFileSync(new URL('aegis_page.html', root), 'utf8').replace(/<template\b[^>]*>/g, '<div>').replaceAll('</template>', '</div>');
  const dom = new JSDOM(html, {runScripts:'outside-only',url:'https://fixture.invalid'}), w = dom.window;
  w.defaultReading = {theme:'system',family:'sans',font:17,spacing:180,width:820};
  w.confirm = () => true;
  w.eval(code);
  const h = new w.Harness();
  Object.assign(h, {shadowRoot:w.document, state_:structuredClone(state), translate_:s=>s, readingSave_:Promise.resolve(), readingSequence_:0, formDirty_:false, readingDirty_:false});
  const calls = []; let reject=false, saved=structuredClone(state);
  h.request_ = async request => {
    calls.push(structuredClone(request)); if(reject) throw Error('配置已在另一处修改');
    if(request.op === 'reading-preferences') saved.readingPreferences=structuredClone(request.preferences);
    if(request.op === 'markdown-site') (saved.markdownSites ||= {})[request.origin]=request.enabled;
    if(request.op === 'markdown-site-remove') delete saved.markdownSites[request.origin];
    if(request.op === 'site-save') saved.sites=[...(saved.sites || []).filter(rule=>rule.origin!==request.rule.origin),structuredClone(request.rule)];
    return structuredClone(saved);
  };
  return {w,dom,h,calls,el:id=>w.document.getElementById(id),reject:()=>{reject=true;}};
}
test('阅读外观快速修改串行提交，非法后续输入不能被旧保存回包覆盖', async () => {
  const {dom,h,el} = harness(); h.initializeReading_();
  const writes=[]; h.request_=request=>new Promise(resolve=>writes.push({request,resolve}));
  el('reading-font').value='18'; void h.saveReading_(); await flush();
  el('reading-font').value='19'; void h.saveReading_();
  el('reading-font').value='99'; await h.saveReading_();
  assert.equal(writes.length,1); assert.equal(writes[0].request.expected,null);
  writes[0].resolve({readingPreferences:writes[0].request.preferences}); await flush();
  assert.equal(writes.length,2); assert.equal(writes[1].request.expected.font,18);
  writes[1].resolve({readingPreferences:writes[1].request.preferences}); await flush();
  assert.equal(el('reading-font').value,'99'); assert.match(el('reading-status').textContent,/尚未保存/);
  assert.equal(h.readingDirty_,true);
  dom.window.close();
});
test('Markdown 来源标准化、停用项回读、重新开启、真实移除及失败恢复', async () => {
  const {dom,w,h,el,calls,reject} = harness({markdownSites:{'https://example.com':false}}); h.initializeReading_();
  assert.equal(el('markdown-sites').querySelector('input').checked,false);
  el('markdown-origin').value='https://example.com/article?lang=zh'; await h.addMarkdownSite_();
  assert.equal(calls.at(-1).origin,'https://example.com'); assert.equal(calls.at(-1).expected,false);
  assert.equal(el('markdown-sites').querySelectorAll('.managed-row').length,1);
  const toggle=el('markdown-sites').querySelector('input'); toggle.checked=false; toggle.dispatchEvent(new w.Event('change')); await flush();
  assert.equal(h.state_.markdownSites['https://example.com'],false);
  el('markdown-sites').querySelector('button').click(); await flush();
  assert.equal(Object.hasOwn(h.state_.markdownSites,'https://example.com'),false);
  el('markdown-origin').value='https://user:secret@example.com/path'; await h.addMarkdownSite_();
  assert.match(el('markdown-error').textContent,/账号密码/);
  assert.equal(calls.length,3);
  el('markdown-origin').value='https://other.example/path'; reject(); await h.addMarkdownSite_();
  assert.equal(el('markdown-origin').value,'https://other.example/path'); assert.equal(el('markdown-origin').disabled,false);
  assert.match(el('markdown-error').textContent,/另一处修改/); dom.window.close();
});
test('网站规则继承说明、独立来源保存和重复项编辑不覆盖旧规则', async () => {
  const parent={origin:'https://example.com',menu:true,copy:false,debug:false,subdomains:true,disabled:false};
  const {dom,h,el,calls}=harness({sites:[parent]}); h.initializeRules_(); h.editRule_(null);
  el('rule-origin').value='https://sub.example.com/path'; h.ruleScope_();
  assert.match(el('rule-scope').textContent,/继承自：https:\/\/example.com/);
  assert.equal(el('rule-inherited').hidden,false);
  el('rule-copy').checked=true; await h.saveRule_();
  assert.equal(calls.at(-1).rule.origin,'https://sub.example.com'); assert.equal(calls.at(-1).expected,null);
  assert.equal(h.state_.sites.length,2); assert.equal(h.state_.sites[0].copy,false);
  h.editRule_(null); el('rule-origin').value='https://example.com/other'; await h.saveRule_();
  assert.equal(calls.length,1); assert.match(el('rule-error').textContent,/已存在/);
  assert.equal(el('rule-origin').readOnly,true); assert.equal(el('rule-tab').disabled,true); dom.window.close();
});
