import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, readFileSync, readdirSync, rmSync} from 'node:fs';
import {createRequire} from 'node:module';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath} from 'node:url';
import vm from 'node:vm';
import test from 'node:test';
import {JSDOM} from 'jsdom';

const requireCore = createRequire(new URL('../../../packages/core/package.json', import.meta.url));
const ts = requireCore('typescript');
const source = readFileSync(join(dirname(fileURLToPath(import.meta.url)),
    '../overlay/chrome/browser/resources/settings/aegis_page/access_account_usage.ts'), 'utf8');
const {outputText} = ts.transpileModule(source, {compilerOptions: {
  target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
}});
const context = vm.createContext({exports: {}, performance});
vm.runInContext(outputText, context);
const {formatUsageBytes, usageFreshness, usageStatus, AccessUsageRefresh} = context.exports;
const response = age => ({state: 'available', evaluatedAt: 1000 + age, entitlement: {
  entitlementAccountId: 'A', status: 'active', measuredAt: 1000,
  periodEnd: 40000, expiresAt: 30000,
  receivedAt: 2000, snapshotAgeMs: age,
  freshness: age > 15000 ? 'unavailable' : age > 5000 ? 'delayed' : 'current',
}});
const tick = () => new Promise(resolve => setImmediate(resolve));

test('byte display preserves exact counters above Number.MAX_SAFE_INTEGER', () => {
  assert.equal(formatUsageBytes('1023'), '1023 B');
  assert.equal(formatUsageBytes('1024'), '1.00 KiB (1024 B)');
  assert.equal(formatUsageBytes('18446744073709551615'), '15.99 EiB (18446744073709551615 B)');
  assert.match(formatUsageBytes('9007199254740997'), /\(9007199254740997 B\)$/);
  for (const raw of [null, '-1', '00', '1.5', '18446744073709551616']) {
    assert.equal(formatUsageBytes(raw), '—');
  }
});

test('freshness ages monotonically and never upgrades missing/inconsistent metadata', () => {
  assert.equal(usageFreshness(response(5000), 0), 'current');
  assert.equal(usageFreshness(response(5000), 0.1), 'delayed');
  assert.equal(usageFreshness(response(15000), 0.1), 'unavailable');
  for (const elapsed of [-1, Infinity, NaN]) assert.equal(usageFreshness(response(1000), elapsed), 'unavailable');
  const missing = response(1000);
  missing.entitlement.measuredAt = null;
  assert.equal(usageFreshness(missing, 0), 'unavailable');
  const inconsistent = response(15001);
  inconsistent.entitlement.freshness = 'current';
  assert.equal(usageFreshness(inconsistent, 0), 'unavailable');
});

test('authorization expiry advances through renderer delivery and local display time', () => {
  const reply = response(1000);
  reply.entitlement.expiresAt = 2800;
  assert.equal(usageStatus(reply, 799), 'active');
  assert.equal(usageStatus(reply, 800), 'expired');
  assert.equal(usageStatus(reply, 1400), 'expired');
  reply.entitlement.status = 'exhausted';
  assert.equal(usageStatus(reply, 0), 'exhausted');
  assert.equal(usageStatus(reply, 1400), 'expired');
  delete reply.evaluatedAt;
  assert.equal(usageStatus(reply, 0), 'unavailable');
  reply.evaluatedAt = 2000;
  for (const elapsed of [-1, NaN, Infinity]) assert.equal(usageStatus(reply, elapsed), 'unavailable');
});

test('only one query runs; hide/reopen discards the old response before new account data', async () => {
  const resolves = [];
  const views = [];
  const refresh = new AccessUsageRefresh(() => new Promise(resolve => resolves.push(resolve)), view => views.push(view));
  refresh.setVisible(true);
  await refresh.refresh();
  assert.equal(resolves.length, 1);
  refresh.setVisible(false);
  refresh.setVisible(true);
  assert.equal(resolves.length, 1);
  resolves[0](response(1000));
  await tick();
  assert.equal(resolves.length, 2);
  assert.equal(views.some(view => view?.entitlement?.entitlementAccountId === 'A'), false);
  const next = response(1000);
  next.entitlement.entitlementAccountId = 'B';
  resolves[1](next);
  await tick();
  assert.equal(views.at(-1).entitlement.entitlementAccountId, 'B');
  refresh.setVisible(false);
  assert.equal(views.at(-1), null);
});

test('network failures clear prior balances and hidden views remain idle', async () => {
  const views = [];
  let failed = false;
  const refresh = new AccessUsageRefresh(async () => {
    if (failed) throw new Error('unavailable');
    return response(1000);
  }, view => views.push(view));
  refresh.setVisible(true);
  await tick();
  assert.equal(views.at(-1).state, 'available');
  failed = true;
  await refresh.refresh();
  assert.equal(views.at(-2), null);
  assert.equal(views.at(-1).state, 'unavailable');
  refresh.setVisible(false);
  await refresh.refresh();
  assert.equal(views.at(-1), null);
});

test('cached observations include the full current WebUI read time', async () => {
  let now = 100;
  let resolve;
  const views = [];
  const refresh = new AccessUsageRefresh(() => new Promise(done => { resolve = done; }),
      (reply, age) => views.push({reply, age}), () => true, () => now);
  refresh.setVisible(true);
  now += 3000;
  const reply = response(3000);
  reply.queryElapsedMs = 3000;
  reply.entitlement.expiresAt = reply.evaluatedAt + 2000;
  resolve(reply);
  await tick();
  assert.equal(views.at(-1).age, 3000);
  assert.equal(usageFreshness(reply, views.at(-1).age), 'delayed');
  assert.equal(usageStatus(reply, views.at(-1).age), 'expired');
  refresh.setVisible(false);
});

test('a recreated view waits for the detached view native query', async () => {
  const resolves = [];
  const query = () => new Promise(resolve => resolves.push(resolve));
  const before = new AccessUsageRefresh(query, () => {});
  before.setVisible(true);
  before.setVisible(false);
  const views = [];
  const after = new AccessUsageRefresh(query, reply => views.push(reply));
  after.setVisible(true);
  assert.equal(resolves.length, 1);
  resolves[0](response(1000));
  await tick();
  assert.equal(resolves.length, 2);
  assert.equal(views.some(view => view?.state === 'available'), false);
  resolves[1](response(2000));
  await tick();
  assert.equal(views.at(-1).entitlement.snapshotAgeMs, 2000);
  after.setVisible(false);
});

test('search-hidden view rejects a reply even before its visibility observer runs', async () => {
  const resolves = [];
  const views = [];
  let shown = true;
  const refresh = new AccessUsageRefresh(() => new Promise(resolve => resolves.push(resolve)),
      reply => views.push(reply), () => shown);
  refresh.setVisible(true);
  shown = false;
  resolves[0](response(1000));
  await tick();
  assert.equal(views.at(-1), null);
  assert.equal(views.some(view => view?.state === 'available'), false);
  shown = true;
  refresh.setVisible(true);
  resolves[1](response(2000));
  await tick();
  assert.equal(views.at(-1).entitlement.snapshotAgeMs, 2000);
  refresh.setVisible(false);
});

test('snapshot render immediately qualifies stale/unknown data and ages visible expiry', async t => {
  const {window} = new JSDOM();
  t.after(() => window.close());
  const {document, HTMLElement, ShadowRoot, MutationObserver} = window;
  document.documentElement.lang = 'en';
  const root = document.createElement('main');
  document.body.append(root);
  let hidden = false;
  Object.defineProperty(document, 'hidden', {get: () => hidden});
  for (const unknown of [false, true]) {
    hidden = false;
    let now = 0;
    let interval;
    const fields = Object.fromEntries(['heading', 'status', 'refresh', 'note', 'values', 'freshness'].map(id => {
      const element = document.createElement(id === 'refresh' ? 'button' : 'div');
      element.dataset.usage = id;
      return [id, element];
    }));
    root.replaceChildren(...Object.values(fields));
    const ui = vm.createContext({exports: {}, document,
      performance: {now: () => now}, HTMLElement, ShadowRoot, MutationObserver,
      window: {setInterval: tick => { interval = tick; return 1; }, clearInterval() {}},
    });
    vm.runInContext(outputText, ui);
    const reply = response(16000);
    reply.entitlement.remainingBytes = '1024';
    reply.entitlement.expiresAt = reply.evaluatedAt + 800;
    if (unknown) Object.assign(reply.entitlement,
        {measuredAt: null, snapshotAgeMs: null, freshness: 'unavailable'});
    let networkReads = 0;
    let finishQuery;
    const visibility = [];
    let observed = reply;
    const cleanup = ui.exports.startAccessUsage(root, async () => observed, () => {
      networkReads++;
      return new Promise(resolve => { finishQuery = () => resolve(reply); });
    }, value => visibility.push(value), () => true);
    await tick();
    assert.equal(fields.freshness.textContent, 'Measurement time unknown or usage stale');
    assert.equal(fields.status.textContent, 'Service reports available quota');
    now = 1400;
    interval();
    assert.equal(fields.status.textContent, 'Authorization expired');
    await tick();
    assert.equal(networkReads, 0);
    fields.refresh.click();
    assert.equal(fields.refresh.disabled, true);
    fields.refresh.click();
    assert.equal(networkReads, 1);
    finishQuery();
    await tick();
    assert.equal(fields.refresh.disabled, false);
    observed = {...reply, state: 'unavailable', stale: true};
    interval();
    await tick();
    assert.equal(fields.status.textContent, 'Last result; current balance is unconfirmed');
    assert.equal(fields.freshness.textContent, '');
    assert.ok(Array.from(fields.values.children).some(row => row.textContent ===
        'Remaining · 1.00 KiB (1024 B)'));
    observed = {state: 'superseded'};
    interval();
    await tick();
    assert.equal(fields.values.children.length, 0);
    hidden = true;
    interval();
    await tick();
    assert.deepEqual(visibility, [true, false]);
    assert.equal(fields.values.children.length, 0);
    cleanup();
    hidden = false;
    fields.refresh.click();
    assert.equal(networkReads, 1);
  }
});

// These are actual HTTP bodies from an isolated service/SQLite fixture.
// Packing fields for pure view helpers does not emulate native validation,
// network timing or a Browser/Profile acceptance run.
let serviceResponses;
function withFixtureWorkspace(run) {
  const workspace = mkdtempSync(join(tmpdir(), 'aegis-usage-wire-workspace-'));
  try {
    return run(workspace);
  } finally {
    rmSync(workspace, {recursive: true, force: true});
  }
}

const runFixture = (workspace, {timeout = 10000, stall = false} = {}) => {
  const directory = mkdtempSync(join(workspace, 'fixture-'));
  try {
    const args = ['-B', fileURLToPath(new URL('../tests/access-account/usage_fixture.py', import.meta.url)), directory];
    if (stall) args.push('--stall-after-store');
    return JSON.parse(execFileSync('python3', args, {encoding: 'utf8', timeout, killSignal: 'SIGKILL'}));
  } finally {
    // The child cannot run its cleanup after timeout/SIGKILL. Its private
    // store is nested inside this parent-owned directory, never user data.
    rmSync(directory, {recursive: true, force: true});
  }
};
const wire = () => serviceResponses ??= withFixtureWorkspace(workspace => runFixture(workspace));
const fromWire = record => {
  assert.equal(record.status, 200);
  assert.equal(record.cacheControl, 'no-store');
  return {state: 'available', evaluatedAt: record.body.evaluatedAt,
    entitlement: record.body};
};

test('real account HTTP counters retain exact large bytes and account isolation in view helpers', () => {
  const replies = wire();
  const active = fromWire(replies.active);
  assert.equal(active.entitlement.usedBytes, '9007199254740997');
  assert.equal(active.entitlement.quotaBytes, '9007199254741037');
  assert.equal(active.entitlement.remainingBytes, '40');
  assert.match(formatUsageBytes(active.entitlement.usedBytes), /\(9007199254740997 B\)$/);
  assert.equal(usageStatus(active, 0), 'active');
  assert.equal(usageFreshness(active, 0), 'current');
  const other = fromWire(replies.other);
  assert.equal(other.entitlement.entitlementAccountId, 'B');
  assert.equal(usageStatus(other, 0), 'not_subscribed');
  assert.equal(formatUsageBytes(other.entitlement.usedBytes), '—');
  assert.deepEqual(replies.activeAgain.body, active.entitlement);
});

test('real service exhausted and expired observations preserve actual overage and expiry priority', () => {
  const exhausted = fromWire(wire().exhausted);
  assert.equal(usageStatus(exhausted, 0), 'exhausted');
  assert.equal(exhausted.entitlement.usedBytes, '9007199254740997');
  assert.equal(exhausted.entitlement.remainingBytes, '0');
  assert.equal(BigInt(exhausted.entitlement.usedBytes) - BigInt(exhausted.entitlement.quotaBytes), 1n);
  const expired = fromWire(wire().expired);
  assert.equal(usageStatus(expired, 0), 'expired');
  assert.equal(usageFreshness(expired, 0), 'unavailable');
});

test('real service unknown measurement retains bytes without substituting receipt for decision time', () => {
  const unknown = fromWire(wire().unknownMeasurement);
  assert.equal(unknown.entitlement.measuredAt, null);
  assert.equal(unknown.entitlement.snapshotAgeMs, null);
  assert.equal(unknown.evaluatedAt - unknown.entitlement.receivedAt, 100);
  assert.equal(usageFreshness(unknown, 0), 'unavailable');
  assert.equal(usageStatus(unknown, 0), 'active');
  assert.equal(usageStatus(unknown, 20000), 'expired');
  assert.equal(unknown.entitlement.usedBytes, '9007199254740997');
  delete unknown.evaluatedAt;
  assert.equal(usageStatus(unknown, 0), 'unavailable');
});

test('fixture timeout cleans the parent-owned directory after the real store was created', () => {
  withFixtureWorkspace(workspace => {
    assert.throws(() => runFixture(workspace, {timeout: 2500, stall: true}), error => {
      assert.equal(error.code, 'ETIMEDOUT');
      assert.match(String(error.stdout), /fixture-store-created/);
      return true;
    });
    // eslint-disable-next-line security/detect-non-literal-fs-filename -- Inspect only this test's freshly created workspace.
    assert.deepEqual(readdirSync(workspace), []);
  });
});
