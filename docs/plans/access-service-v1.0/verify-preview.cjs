// Documentation preview checks only; no network or product runtime validation.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { JSDOM, VirtualConsole } = require('jsdom');

// Run with Node >=20 and jsdom 26.1.0 available via NODE_PATH or local resolution.
const file = require('node:path').join(__dirname, 'interaction-example.html');
const errors = [];
const virtualConsole = new VirtualConsole();
virtualConsole.on('jsdomError', error => errors.push(error.message));
const dom = new JSDOM(fs.readFileSync(file, 'utf8'), { runScripts: 'dangerously', virtualConsole });
const document = dom.window.document;
const root = document.getElementById('aegis-user-experience');
const checks = [];
const visible = element => !!element && !element.closest('[hidden]');
const action = name => [...root.querySelectorAll(`[data-ag-action="${name}"]`)].find(visible);
const change = (name, value) => {
  const select = document.querySelector(`[data-preview-state="${name}"]`);
  select.value = value;
  select.dispatchEvent(new dom.window.Event('change', { bubbles: true }));
};
const waitForOperation = () => new Promise(resolve => setTimeout(resolve, 950));
const enabled = () => action('site-proxy').getAttribute('aria-checked') === 'true';

(async () => {
  assert.equal(document.doctype.name, 'html');
  assert.equal(document.documentElement.lang, 'zh-CN');
  assert.equal(document.querySelectorAll('[data-preview-state]').length, 5);
  assert.equal(document.querySelectorAll('script[src], link[href], iframe, img[src]').length, 0);
  assert.equal(dom.window.Tweak, undefined);
  assert.ok(document.querySelector('meta[name="viewport"]'));
  checks.push('Standalone document initializes without host or external resources');

  for (const edition of ['beta', 'release', 'dev', 'alpha']) {
    change('edition', edition);
    assert.ok(root.querySelector('[data-ag="preview-label"]').textContent.toLowerCase().includes(edition));
    assert.ok(action('site-proxy'));
    assert.equal(!!action('toggle-debug'), edition === 'dev' || edition === 'alpha');
    assert.equal([...root.querySelectorAll('select')].filter(visible).length, 0);
    if (edition === 'dev' || edition === 'alpha') {
      action('toggle-debug').click();
      assert.ok(action('allow'));
      assert.ok(action('subscription'));
      assert.equal(root.querySelector('[data-ag="dev"]').hidden, false);
      action('toggle-debug').click();
    }
  }
  checks.push('Four native channel choices expose the correct simple and debug views');

  change('edition', 'beta');
  change('view', 'bubble');
  assert.ok(action('site-proxy'));
  assert.equal(action('allow'), undefined);
  action('site-proxy').click();
  assert.equal(action('site-proxy').getAttribute('aria-busy'), 'true');
  await waitForOperation();
  assert.equal(enabled(), true);
  change('status', 'offline');
  assert.equal(enabled(), true);
  action('site-proxy').click();
  assert.equal(enabled(), false);
  checks.push('Bubble toggle commits, preserves selection during outage, and disables locally');

  change('status', 'ready');
  action('site-proxy').click();
  action('site-proxy').click();
  await waitForOperation();
  assert.equal(enabled(), false);
  checks.push('Cancelled preparation cannot re-enable the website after its timer finishes');

  action('site-proxy').click();
  change('status', 'offline');
  await waitForOperation();
  assert.equal(enabled(), false);
  assert.match([...root.querySelectorAll('[data-site-status]')].find(visible).textContent, /未能开启/);
  checks.push('Failed preparation keeps the prior choice and reports failure');

  change('view', 'management');
  change('edition', 'alpha');
  action('toggle-debug').click();
  const subscription = root.querySelector('input[type="url"]');
  subscription.value = 'https://changed.example/sub';
  subscription.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
  action('save-dev').click();
  change('edition', 'dev');
  action('toggle-debug').click();
  assert.equal(subscription.value, 'https://subscription.example/sub');
  assert.equal(action('save-dev').disabled, true);
  checks.push('Changing preview channels resets fictional debug settings');

  change('edition', 'release');
  change('quotaMode', 'unlimited');
  change('usageScale', 'tiny');
  assert.equal(root.querySelector('[data-ag="meter"]').hidden, true);
  assert.equal(root.querySelector('[data-ag="used"]').textContent, '<0.01 MB');
  assert.equal(action('toggle-debug'), undefined);
  assert.equal(action('subscription'), undefined);
  checks.push('Independent quota and usage controls work without exposing Release debug controls');

  const resetAlpha = () => {
    change('edition', 'beta'); change('edition', 'alpha');
    change('view', 'management'); change('status', 'ready');
  };
  const targetAction = (name, id = 'main') => root.querySelector(`[data-target-action="${name}"][data-id="${id}"]`).click();
  const targetMode = () => root.querySelector('[data-target-mode="main"]').textContent;
  const siteStatus = () => [...root.querySelectorAll('[data-site-status]')].find(visible).textContent;

  resetAlpha();
  action('site-proxy').click(); await waitForOperation();
  action('toggle-debug').click();
  assert.match(targetMode(), /^PROXY/);
  assert.match(root.querySelector('[data-target="main"] label').textContent, /HTTPS.*精确目标/);
  targetAction('block');
  action('toggle-debug').click();
  assert.equal(enabled(), true);
  assert.equal(action('site-proxy').disabled, false);
  assert.match(siteStatus(), /独立设置限制/);
  change('status', 'offline'); action('site-proxy').click();
  assert.equal(enabled(), false);
  action('toggle-debug').click(); assert.match(targetMode(), /^REJECT/);
  checks.push('Exact BLOCK preserves the enabled website choice and allows offline group disable');

  resetAlpha();
  action('site-proxy').click(); await waitForOperation(); action('site-proxy').click();
  action('toggle-debug').click(); targetAction('allow'); await waitForOperation();
  assert.match(targetMode(), /^PROXY/);
  action('toggle-debug').click(); assert.equal(enabled(), false);
  assert.match(siteStatus(), /独立设置限制/);
  checks.push('Exact ALLOW leaves a committed disabled website group unchanged and reports its override');

  resetAlpha();
  action('site-proxy').click(); await waitForOperation();
  action('toggle-debug').click(); targetAction('block');
  change('status', 'offline'); targetAction('delete');
  assert.match(targetMode(), /^REJECT/);
  change('status', 'ready'); targetAction('delete');
  assert.match(targetMode(), /^PROXY.*继承网站选择/);
  action('toggle-debug').click(); assert.equal(enabled(), true);
  assert.doesNotMatch(siteStatus(), /独立设置限制/);
  checks.push('Deleting an override safely restores the current group inheritance instead of default DIRECT');

  resetAlpha();
  action('site-proxy').click(); await waitForOperation();
  action('toggle-debug').click(); targetAction('block');
  action('toggle-debug').click(); action('site-proxy').click();
  action('toggle-debug').click(); action('undo').click();
  assert.match(targetMode(), /^REJECT/);
  action('toggle-debug').click(); assert.equal(enabled(), true);
  checks.push('Undoing a website change preserves separately owned exact BLOCK rules');

  resetAlpha();
  action('toggle-debug').click(); targetAction('allow'); targetAction('block');
  await waitForOperation(); assert.match(targetMode(), /^REJECT/);
  action('toggle-debug').click();
  assert.equal(action('site-proxy'), undefined);
  assert.match(siteStatus(), /网站设置暂不可用/);
  checks.push('Late exact ALLOW cannot overwrite BLOCK or invent a complete website choice');

  resetAlpha();
  action('site-proxy').click();
  action('toggle-debug').click(); targetAction('block');
  await waitForOperation(); assert.match(targetMode(), /^REJECT/);
  action('toggle-debug').click(); assert.equal(enabled(), true);
  assert.match(siteStatus(), /独立设置限制/);
  checks.push('Website preparation can commit its own group while preserving a later exact BLOCK');

  assert.deepEqual(errors, []);
  const result = {
    status: 'PASS',
    scope: 'Offline DOM interaction checks for the documentation preview only; not browser rendering, product channel security, protocol routing, or network acceptance',
    source: require('node:path').basename(file),
    checks,
  };
  console.log(JSON.stringify(result, null, 2));
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => dom.window.close());
