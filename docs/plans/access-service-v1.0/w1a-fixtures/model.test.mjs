// CONTRACT_MODEL_ONLY: unit and regression tests for the isolated oracle.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { RequestRoutingContractModel } from './model.mjs';

process.stdout.write('CONTRACT_MODEL_ONLY; native=NOT_RUN; browser=NOT_RUN; authNetwork=NOT_RUN\n');

const fixture = JSON.parse(readFileSync(new URL('./scenarios.json', import.meta.url)));
const owner = (profile_token, storage_partition_token = 'default') => ({
  channel: 'dev', profile_token, storage_partition_token,
});
const tuple = (selection_generation, common = fixture.commonGenerations) => ({
  ...common, selection_generation,
});
const endpointIdentity = (port, transport = 'http') => ({
  transport, host: '127.0.0.1', port, credentialIdentity: `credential-${port}`,
});

function prepare(model, routeOwner, incarnation, { rules = fixture.routes,
  endpoints = fixture.endpoints, common = fixture.commonGenerations } = {}) {
  assert.equal(model.restart(routeOwner, incarnation).ok, true);
  const issuer = model.trustedIssuer(routeOwner);
  for (const endpoint of endpoints) {
    assert.equal(model.registerEndpoint({
      owner: routeOwner, group: endpoint.groupId,
      registrationId: endpoint.registrationId, incarnation,
      endpointIdentity: endpointIdentity(endpoint.port),
      tuple: tuple(endpoint.selection_generation, common),
    }).ok, true);
  }
  const publication = model.publishSnapshot({
    owner: routeOwner, incarnation, commonGenerations: common, rules,
    endpoints: endpoints.map(({ groupId, registrationId }) => ({ groupId, registrationId })),
  });
  assert.equal(publication.ok, true);
  assert.equal(model.acknowledgeModelSnapshot(publication.receipt).ok, true);
  return issuer;
}

function issue(model, issuer, target, requestId, topLevelSite = 'https://shop.test', extras = {}) {
  return model.issueRequest({ issuer, target, method: 'GET', requestId, hop: 0,
    attribution: { kind: 'site', topLevelSite }, ...extras });
}

test('unit: exact site and group binding produces distinct first-send routes', () => {
  const model = new RequestRoutingContractModel();
  const issuer = prepare(model, owner('profile-A'), 'context-1');
  const shop = model.evaluate(issue(model, issuer, 'https://cdn.example/image', 'shop'));
  const mail = model.evaluate(issue(model, issuer, 'https://cdn.example/image', 'mail', 'https://mail.test'));
  const payments = model.evaluate(issue(model, issuer, 'https://api.shop.test/pay', 'payments'));
  assert.deepEqual([shop.action, mail.action, payments.action], ['proxy', 'proxy', 'proxy']);
  assert.deepEqual([shop.registrationId, mail.registrationId, payments.registrationId],
    ['shop-r1', 'mail-r1', 'pay-r1']);
  assert.notEqual(shop.reuseKey, mail.reuseKey);
  assert.notEqual(shop.reuseKey, payments.reuseKey);
  assert.equal(shop.tuple.selection_generation, 11);
  assert.equal(mail.tuple.selection_generation, 12);
  assert.equal(model.dispatch(shop).ok, true);
  assert.equal(model.dispatch(mail).ok, true);
  assert.equal(model.dispatch(payments).ok, true);
});

test('unit: exact scheme/port and all four route outcomes', () => {
  const model = new RequestRoutingContractModel();
  const issuer = prepare(model, owner('profile-A'), 'context-1');
  const direct = model.evaluate(issue(model, issuer, 'https://native.test/', 'direct'));
  const preserve = model.evaluate(issue(model, issuer, 'http://native.test/', 'preserve'));
  const wrongPort = model.evaluate(issue(model, issuer, 'https://cdn.example:8443/', 'port'));
  const wrongScheme = model.evaluate(issue(model, issuer, 'http://cdn.example/', 'scheme'));
  const reject = model.evaluate(issue(model, issuer, 'https://blocked.test/', 'reject'));
  const required = model.evaluate(issue(model, issuer, 'https://unlisted.test/', 'required',
    'https://shop.test', { requireProxy: true }));
  assert.deepEqual([direct.action, direct.reason, direct.nativeProxyConfigGeneration],
    ['native', 'DIRECT', 5]);
  assert.deepEqual([preserve.action, preserve.reason], ['native', 'PRESERVE_NATIVE']);
  assert.deepEqual([wrongPort.action, wrongScheme.action], ['native', 'native']);
  assert.deepEqual([reject.action, model.dispatch(reject).reason], ['reject', 'locally_rejected']);
  assert.deepEqual([required.action, required.reason], ['wait-fail', 'required_route_missing']);
  assert.equal(model.dispatch(required).ok, false);
});

test('unit: full candidate validation and model ACK are atomic', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('profile-A');
  const issuer = prepare(model, routeOwner, 'context-1');
  const before = model.evaluate(issue(model, issuer, 'https://cdn.example/', 'before'));
  const invalid = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations,
    rules: [...fixture.routes, { ...fixture.routes[0], id: 'conflict', mode: 'REJECT', groupId: undefined }],
    endpoints: fixture.endpoints.map(({ groupId, registrationId }) => ({ groupId, registrationId })) });
  assert.deepEqual(invalid, { ok: false, reason: 'invalid_or_conflicting_rule' });
  const incomplete = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations, rules: fixture.routes,
    endpoints: [{ groupId: 'shopping', registrationId: 'missing' }] });
  assert.equal(incomplete.reason, 'missing_or_stale_registration');
  const malformedHost = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations,
    rules: [{ ...fixture.routes[0], exactHost: 'CDN.EXAMPLE' }],
    endpoints: [{ groupId: 'shopping', registrationId: 'shop-r1' }] });
  assert.equal(malformedHost.reason, 'invalid_or_conflicting_rule');
  const wrongGroup = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations, rules: [fixture.routes[0]],
    endpoints: [{ groupId: 'shopping', registrationId: 'mail-r1' }] });
  assert.equal(wrongGroup.reason, 'missing_or_stale_registration');
  assert.equal(model.acknowledgeModelSnapshot({ snapshotId: before.snapshotId,
    ownerKey: JSON.stringify(['dev', 'profile-A', 'default']), incarnation: 'context-1' }).ok, false);
  assert.equal(model.evaluate(issue(model, issuer, 'https://cdn.example/', 'after')).snapshotId,
    before.snapshotId);
  assert.equal(model.dispatch(before).ok, true);
});

test('unit: zero generations and lost registration cannot become READY', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('incomplete');
  assert.equal(model.restart(routeOwner, 'context-1').ok, true);
  assert.equal(model.registerEndpoint({ owner: routeOwner, group: 'shopping',
    registrationId: 'invalid', incarnation: 'context-1',
    endpointIdentity: endpointIdentity(18101), tuple: { ...tuple(11), network_epoch: 0 } }).reason,
  'invalid_registration');
  assert.equal(model.registerEndpoint({ owner: routeOwner, group: 'shopping',
    registrationId: 'valid', incarnation: 'context-1',
    endpointIdentity: endpointIdentity(18101), tuple: tuple(11) }).ok, true);
  const zero = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: { ...fixture.commonGenerations, policy_generation: 0 },
    rules: [fixture.routes[0]], endpoints: [{ groupId: 'shopping', registrationId: 'valid' }] });
  assert.equal(zero.reason, 'incomplete_snapshot');
  const candidate = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations, rules: [fixture.routes[0]],
    endpoints: [{ groupId: 'shopping', registrationId: 'valid' }] });
  assert.equal(candidate.ok, true);
  assert.equal(model.unregisterEndpoint(routeOwner, 'valid'), true);
  assert.equal(model.acknowledgeModelSnapshot(candidate.receipt).reason,
    'registration_lost_before_model_ack');
  assert.equal(model.restart(routeOwner, 'context-2').ok, true);
  assert.equal(model.acknowledgeModelSnapshot(candidate.receipt).reason,
    'stale_or_forged_model_ack');
});

test('regression: forged and mutated inputs never expand trusted ownership', () => {
  const model = new RequestRoutingContractModel();
  const issuer = prepare(model, owner('profile-A'), 'context-1');
  const forgedIssuer = model.issueRequest({ issuer: {}, target: 'https://cdn.example/',
    attribution: { kind: 'site', topLevelSite: 'https://shop.test' },
    method: 'GET', requestId: 'forged' });
  assert.equal(forgedIssuer.reason, 'untrusted_or_unknown_issuer');
  assert.equal(model.evaluate({ target: 'https://cdn.example/' }).reason, 'unissued_request');
  const attribution = { kind: 'site', topLevelSite: 'https://shop.test' };
  const issued = model.issueRequest({ issuer, attribution, target: 'https://cdn.example/',
    method: 'GET', requestId: 'immutable' });
  attribution.topLevelSite = 'https://mail.test';
  assert.equal(model.evaluate(issued).registrationId, 'shop-r1');
  const decision = model.evaluate(issued);
  assert.equal(model.dispatch({ ...decision }).reason, 'forged_decision');
  assert.equal(model.dispatch(decision).ok, true);
  assert.equal(model.dispatch(model.evaluate(issued)).reason, 'already_sent');
});

test('regression: missing ownership cannot borrow URL, active tab, or network key', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('profile-A');
  assert.equal(model.restart(routeOwner, 'context-1').ok, true);
  const issuer = model.trustedIssuer(routeOwner);
  const opaque = model.issueRequest({ issuer, attribution: { kind: 'opaque', activeTab: 'shop', nak: 'shop' },
    target: 'https://cdn.example/', method: 'GET', requestId: 'opaque', requireProxy: true });
  const missing = model.evaluate(opaque);
  assert.deepEqual([missing.action, missing.reason], ['wait-fail', 'required_snapshot_missing']);
  const unrestricted = model.evaluate(issue(model, issuer, 'https://ordinary.test/', 'ordinary'));
  assert.deepEqual([unrestricted.action, unrestricted.reason], ['native', 'no_access_snapshot']);
  assert.equal(model.dispatch(unrestricted).ok, true);
  // Even with an active site rule for this URL, opaque attribution cannot claim that site.
  prepareAfterRestart(model, routeOwner, 'context-2');
  const newIssuer = model.trustedIssuer(routeOwner);
  const noSite = model.evaluate(model.issueRequest({ issuer: newIssuer,
    attribution: { kind: 'opaque', activeTab: 'shop', nak: 'shop' },
    target: 'https://cdn.example/', method: 'GET', requestId: 'opaque-2', requireProxy: true }));
  assert.deepEqual([noSite.action, noSite.reason], ['wait-fail', 'required_route_missing']);
});

function prepareAfterRestart(model, routeOwner, incarnation) {
  assert.equal(model.restart(routeOwner, incarnation).ok, true);
  const endpoints = fixture.endpoints.map((endpoint) => ({
    ...endpoint, registrationId: `${endpoint.registrationId}-${incarnation}`,
  }));
  for (const endpoint of endpoints) {
    assert.equal(model.registerEndpoint({ owner: routeOwner, incarnation,
      group: endpoint.groupId, registrationId: endpoint.registrationId,
      endpointIdentity: endpointIdentity(endpoint.port),
      tuple: tuple(endpoint.selection_generation) }).ok, true);
  }
  const published = model.publishSnapshot({ owner: routeOwner, incarnation,
    commonGenerations: fixture.commonGenerations, rules: fixture.routes,
    endpoints: endpoints.map(({ groupId, registrationId }) => ({ groupId, registrationId })) });
  assert.equal(model.acknowledgeModelSnapshot(published.receipt).ok, true);
}

test('regression: Profile, OTR, partition and restart separate registration and pool keys', () => {
  const model = new RequestRoutingContractModel();
  const a = owner('profile-A');
  const b = owner('profile-B');
  const otr = owner('profile-A-OTR');
  const partition = owner('profile-A', 'isolated-partition');
  const issuers = [a, b, otr, partition].map((routeOwner) =>
    prepare(model, routeOwner, 'context-1'));
  const decisions = issuers.map((issuer, index) => model.evaluate(issue(model, issuer,
    'https://cdn.example/', `profile-${index}`)));
  assert.equal(new Set(decisions.map((decision) => decision.reuseKey)).size, 4);
  assert.equal(model.dispatch(decisions[0]).ok, true);
  assert.equal(model.restart(a, 'context-2').ok, true);
  assert.equal(model.dispatch(decisions[1]).ok, true);
  assert.equal(model.dispatch(decisions[2]).ok, true);
  assert.equal(model.dispatch(decisions[3]).ok, true);
  assert.equal(model.authorizeCredentialLookup(decisions[0], {
    owner: a, registrationId: 'shop-r1', transport: 'http' }).ok, false);
  assert.equal(issue(model, issuers[0], 'https://cdn.example/', 'after-restart').reason,
    'untrusted_or_unknown_issuer');
  const restoringIssuer = model.trustedIssuer(a);
  assert.equal(model.evaluate(issue(model, restoringIssuer, 'https://cdn.example/', 'restoring',
    'https://shop.test', { requireProxy: true })).action, 'wait-fail');
  prepareAfterRestart(model, a, 'context-3');
  const later = model.evaluate(issue(model, model.trustedIssuer(a),
    'https://cdn.example/', 'later'));
  assert.notEqual(later.reuseKey, decisions[0].reuseKey);
});

test('regression: group-specific selection and missing registrations invalidate only valid reuse', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('profile-A');
  const issuer = prepare(model, routeOwner, 'context-1');
  const shopping = model.evaluate(issue(model, issuer, 'https://cdn.example/', 'shop-old'));
  const mail = model.evaluate(issue(model, issuer, 'https://cdn.example/', 'mail-old', 'https://mail.test'));
  assert.equal(model.registerEndpoint({ owner: routeOwner, group: 'mail', registrationId: 'mail-r2',
    incarnation: 'context-1', endpointIdentity: endpointIdentity(18112), tuple: tuple(22) }).ok, true);
  const endpoints = fixture.endpoints.map(({ groupId, registrationId }) => ({
    groupId, registrationId: groupId === 'mail' ? 'mail-r2' : registrationId,
  }));
  const published = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations, rules: fixture.routes, endpoints });
  assert.equal(published.ok, true);
  assert.equal(model.acknowledgeModelSnapshot(published.receipt).ok, true);
  assert.equal(model.dispatch(mail).reason, 'stale_decision');
  const shoppingNew = model.evaluate(issue(model, issuer, 'https://cdn.example/', 'shop-new'));
  const mailNew = model.evaluate(issue(model, issuer, 'https://cdn.example/', 'mail-new', 'https://mail.test'));
  assert.equal(shoppingNew.reuseKey, shopping.reuseKey);
  assert.notEqual(mailNew.reuseKey, mail.reuseKey);
  assert.equal(model.unregisterEndpoint(routeOwner, 'mail-r2'), true);
  assert.equal(model.evaluate(issue(model, issuer, 'https://cdn.example/', 'mail-lost',
    'https://mail.test')).action, 'wait-fail');
  assert.equal(model.dispatch(mailNew).reason, 'registration_unavailable');
  assert.equal(model.dispatch(shoppingNew).ok, true);
});

test('regression: redirect reissues every hop while sent POST/PATCH cannot be replayed', () => {
  const model = new RequestRoutingContractModel();
  const issuer = prepare(model, owner('profile-A'), 'context-1');
  const post = issue(model, issuer, 'https://api.shop.test/pay', 'payment',
    'https://shop.test', { method: 'POST' });
  const first = model.evaluate(post);
  assert.equal(model.dispatch(first).ok, true);
  assert.equal(model.dispatch(first).reason, 'already_sent');
  assert.equal(model.dispatch(model.evaluate(post)).reason, 'already_sent');
  const redirected = model.redirect(post, { target: 'https://cdn.example/after',
    method: 'POST', navigation: 'subresource' });
  const second = model.evaluate(redirected);
  assert.deepEqual([second.hop, second.registrationId], [1, 'shop-r1']);
  assert.equal(model.dispatch(second).ok, true);
  const main = model.redirect(redirected, { target: 'https://cdn.example/final',
    method: 'POST', navigation: 'main', nextTopLevelSite: 'https://mail.test' });
  const third = model.evaluate(main);
  assert.deepEqual([third.hop, third.registrationId], [2, 'mail-r1']);
  assert.equal(model.dispatch(third).ok, true);
  assert.equal(model.dispatch(model.evaluate(main)).reason, 'already_sent');
  const patch = issue(model, issuer, 'https://api.shop.test/pay', 'patch',
    'https://shop.test', { method: 'PATCH' });
  assert.equal(model.dispatch(model.evaluate(patch)).ok, true);
  assert.equal(model.dispatch(model.evaluate(patch)).reason, 'already_sent');
});

test('regression: required POST waits with send zero, then dispatches once after READY', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('waiting-post');
  assert.equal(model.restart(routeOwner, 'context-1').ok, true);
  const issuer = model.trustedIssuer(routeOwner);
  const post = issue(model, issuer, 'https://cdn.example/', 'waiting-post',
    'https://shop.test', { method: 'POST', requireProxy: true });
  const waiting = model.evaluate(post);
  assert.deepEqual([waiting.action, model.dispatch(waiting).ok], ['wait-fail', false]);
  assert.equal(model.registerEndpoint({ owner: routeOwner, group: 'shopping',
    registrationId: 'post-r1', incarnation: 'context-1',
    endpointIdentity: endpointIdentity(18101), tuple: tuple(11) }).ok, true);
  const candidate = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations, rules: [fixture.routes[0]],
    endpoints: [{ groupId: 'shopping', registrationId: 'post-r1' }] });
  assert.equal(model.acknowledgeModelSnapshot(candidate.receipt).ok, true);
  const ready = model.evaluate(post);
  assert.deepEqual([ready.action, ready.registrationId], ['proxy', 'post-r1']);
  assert.equal(model.dispatch(ready).ok, true);
  assert.equal(model.dispatch(model.evaluate(post)).reason, 'already_sent');
});

test('unit: credential lookup binds owner, registration, transport and active snapshot', () => {
  const model = new RequestRoutingContractModel();
  const a = owner('profile-A');
  const b = owner('profile-B');
  const issuer = prepare(model, a, 'context-1');
  prepare(model, b, 'context-1');
  const decision = model.evaluate(issue(model, issuer, 'https://cdn.example/', 'auth'));
  assert.deepEqual(model.authorizeCredentialLookup(decision, {
    owner: a, registrationId: 'shop-r1', transport: 'http' }),
  { ok: true, credentialIdentity: 'credential-18101' });
  for (const candidate of [
    { owner: b, registrationId: 'shop-r1', transport: 'http' },
    { owner: a, registrationId: 'mail-r1', transport: 'http' },
    { owner: a, registrationId: 'shop-r1', transport: 'socks5' },
  ]) assert.equal(model.authorizeCredentialLookup(decision, candidate).reason,
    'credential_binding_denied');
});

test('unit: http/https/ws/wss default and explicit ports remain distinct', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('protocol-profile');
  const rules = [
    ['http', 80], ['https', 443], ['ws', 80], ['wss', 443], ['https', 8443],
  ].map(([scheme, port]) => ({ id: `${scheme}-${port}`, scope: 'profile',
    exactHost: 'protocol.test', scheme, port, mode: 'PROXY', groupId: 'shopping' }));
  const issuer = prepare(model, routeOwner, 'context-1', {
    rules, endpoints: [fixture.endpoints[0]],
  });
  const targets = ['http://protocol.test/', 'https://protocol.test/',
    'ws://protocol.test/', 'wss://protocol.test/', 'https://protocol.test:8443/'];
  for (const [index, target] of targets.entries()) {
    const decision = model.evaluate(issue(model, issuer, target, `protocol-${index}`));
    assert.deepEqual([decision.action, decision.registrationId], ['proxy', 'shop-r1']);
    assert.equal(model.dispatch(decision).ok, true);
  }
  const wrongPort = model.evaluate(issue(model, issuer, 'wss://protocol.test:8443/', 'wss-wrong'));
  assert.deepEqual([wrongPort.action, wrongPort.reason], ['native', 'PRESERVE_NATIVE']);
});

test('regression: each GenerationTuple field and same-address registration changes reuse key', () => {
  for (const field of ['policy_generation', 'identity_generation', 'selection_generation',
    'network_epoch', 'base_proxy_config_generation']) {
    const model = new RequestRoutingContractModel();
    const routeOwner = owner(`generation-${field}`);
    const rules = [fixture.routes[0]];
    const oldEndpoint = fixture.endpoints[0];
    const issuer = prepare(model, routeOwner, 'context-1', { rules, endpoints: [oldEndpoint] });
    const oldDecision = model.evaluate(issue(model, issuer, 'https://cdn.example/', `old-${field}`));
    const nextCommon = { ...fixture.commonGenerations };
    let selection = oldEndpoint.selection_generation;
    if (field === 'selection_generation') selection += 1;
    else nextCommon[field] += 1;
    assert.equal(model.registerEndpoint({ owner: routeOwner, group: 'shopping',
      registrationId: `shop-new-${field}`, incarnation: 'context-1',
      endpointIdentity: endpointIdentity(oldEndpoint.port),
      tuple: tuple(selection, nextCommon) }).ok, true);
    const published = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
      commonGenerations: nextCommon, rules,
      endpoints: [{ groupId: 'shopping', registrationId: `shop-new-${field}` }] });
    assert.equal(published.ok, true, field);
    assert.equal(model.acknowledgeModelSnapshot(published.receipt).ok, true);
    const next = model.evaluate(issue(model, issuer, 'https://cdn.example/', `new-${field}`));
    assert.deepEqual([next.action, next.registrationId], ['proxy', `shop-new-${field}`]);
    assert.notEqual(next.reuseKey, oldDecision.reuseKey, field);
    assert.equal(model.dispatch(oldDecision).reason, 'stale_decision');
    assert.equal(model.dispatch(next).ok, true);
  }
});

test('regression: each tuple field changes reuse key with registration identity fixed', () => {
  for (const field of ['policy_generation', 'identity_generation', 'selection_generation',
    'network_epoch', 'base_proxy_config_generation']) {
    const routeOwner = owner('fixed-registration');
    const baseline = new RequestRoutingContractModel();
    const changed = new RequestRoutingContractModel();
    const baselineIssuer = prepare(baseline, routeOwner, 'context-1', {
      rules: [fixture.routes[0]], endpoints: [fixture.endpoints[0]],
    });
    const changedCommon = { ...fixture.commonGenerations };
    const changedEndpoint = { ...fixture.endpoints[0] };
    if (field === 'selection_generation') changedEndpoint.selection_generation += 1;
    else changedCommon[field] += 1;
    const changedIssuer = prepare(changed, routeOwner, 'context-1', {
      rules: [fixture.routes[0]], endpoints: [changedEndpoint], common: changedCommon,
    });
    const oldDecision = baseline.evaluate(issue(baseline, baselineIssuer,
      'https://cdn.example/', `baseline-${field}`));
    const newDecision = changed.evaluate(issue(changed, changedIssuer,
      'https://cdn.example/', `changed-${field}`));
    assert.deepEqual([oldDecision.action, newDecision.action], ['proxy', 'proxy']);
    assert.deepEqual([oldDecision.registrationId, newDecision.registrationId],
      ['shop-r1', 'shop-r1']);
    assert.equal(newDecision.tuple[field], oldDecision.tuple[field] + 1, field);
    assert.notEqual(newDecision.reuseKey, oldDecision.reuseKey, field);
    assert.equal(baseline.dispatch(oldDecision).ok, true);
    assert.equal(changed.dispatch(newDecision).ok, true);
    if (field === 'base_proxy_config_generation') {
      const oldNative = baseline.evaluate(issue(baseline, baselineIssuer,
        'https://native.test/', 'native-old'));
      const newNative = changed.evaluate(issue(changed, changedIssuer,
        'https://native.test/', 'native-new'));
      assert.deepEqual([oldNative.nativeProxyConfigGeneration,
        newNative.nativeProxyConfigGeneration], [5, 6]);
    }
  }
});

test('regression: all six policy mode transitions invalidate old decisions', () => {
  const modes = ['DIRECT', 'PROXY', 'REJECT'];
  for (const from of modes) for (const to of modes) {
    if (from === to) continue;
    const model = new RequestRoutingContractModel();
    const routeOwner = owner(`mode-${from}-${to}`);
    const oldRule = { id: 'target', scope: 'profile', exactHost: 'target.test',
      scheme: 'https', port: 443, mode: from,
      ...(from === 'PROXY' ? { groupId: 'shopping' } : {}) };
    const issuer = prepare(model, routeOwner, 'context-1', {
      rules: [oldRule], endpoints: [fixture.endpoints[0]],
    });
    const old = model.evaluate(issue(model, issuer, 'https://target.test/', `old-${from}-${to}`));
    const nextCommon = { ...fixture.commonGenerations, policy_generation: 4 };
    assert.equal(model.registerEndpoint({ owner: routeOwner, group: 'shopping',
      registrationId: 'shop-r2', incarnation: 'context-1',
      endpointIdentity: endpointIdentity(18101), tuple: tuple(11, nextCommon) }).ok, true);
    const newRule = { ...oldRule, mode: to };
    if (to === 'PROXY') newRule.groupId = 'shopping';
    else delete newRule.groupId;
    const publication = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
      commonGenerations: nextCommon, rules: [newRule],
      endpoints: [{ groupId: 'shopping', registrationId: 'shop-r2' }] });
    assert.equal(publication.ok, true);
    assert.equal(model.acknowledgeModelSnapshot(publication.receipt).ok, true);
    assert.equal(model.dispatch(old).reason, 'stale_decision');
    const next = model.evaluate(issue(model, issuer, 'https://target.test/', `new-${from}-${to}`));
    const expected = { DIRECT: 'native', PROXY: 'proxy', REJECT: 'reject' }[to];
    assert.equal(next.action, expected, `${from}->${to}`);
    assert.equal(next.nativeProxyConfigGeneration, 5);
    if (to === 'REJECT') assert.equal(model.dispatch(next).reason, 'locally_rejected');
    else assert.equal(model.dispatch(next).ok, true);
  }
});

test('regression: native redirect can become proxy or reject at its new hop', () => {
  const model = new RequestRoutingContractModel();
  const issuer = prepare(model, owner('redirect-profile'), 'context-1');
  for (const [index, target, action] of [
    ['proxy', 'https://cdn.example/', 'proxy'],
    ['reject', 'https://blocked.test/', 'reject'],
  ]) {
    const initial = issue(model, issuer, 'https://native.test/', `native-${index}`);
    assert.equal(model.dispatch(model.evaluate(initial)).ok, true);
    const redirected = model.redirect(initial, { target, method: 'GET',
      navigation: 'subresource' });
    const next = model.evaluate(redirected);
    assert.deepEqual([next.hop, next.action], [1, action]);
    if (action === 'proxy') assert.equal(model.dispatch(next).ok, true);
    else assert.equal(model.dispatch(next).reason, 'locally_rejected');
  }
});

test('regression: stale ACK cannot replace later BLOCK; close invalidates issuer and decision', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('block-profile');
  const issuer = prepare(model, routeOwner, 'context-1', {
    rules: [fixture.routes[0]], endpoints: [fixture.endpoints[0]],
  });
  const pendingProxy = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations, rules: [fixture.routes[0]],
    endpoints: [{ groupId: 'shopping', registrationId: 'shop-r1' }] });
  const blockRule = { ...fixture.routes[0], id: 'later-block', mode: 'REJECT' };
  delete blockRule.groupId;
  const block = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations, rules: [blockRule],
    endpoints: [{ groupId: 'shopping', registrationId: 'shop-r1' }] });
  assert.equal(model.acknowledgeModelSnapshot(pendingProxy.receipt).reason,
    'stale_or_forged_model_ack');
  assert.equal(model.acknowledgeModelSnapshot(block.receipt).ok, true);
  const denied = model.evaluate(issue(model, issuer, 'https://cdn.example/', 'blocked'));
  assert.equal(denied.action, 'reject');
  assert.equal(model.dispatch(denied).reason, 'locally_rejected');
  assert.equal(model.close(routeOwner).ok, true);
  assert.equal(model.dispatch(denied).reason, 'stale_decision');
  assert.equal(issue(model, issuer, 'https://cdn.example/', 'closed').reason,
    'untrusted_or_unknown_issuer');
  assert.equal(model.restart(routeOwner, 'context-1').reason, 'incarnation_not_advanced');
  assert.equal(model.restart(routeOwner, 'context-2').ok, true);
  assert.equal(issue(model, issuer, 'https://cdn.example/', 'revived').reason,
    'untrusted_or_unknown_issuer');
});

test('regression: restart retains committed constraints without blocking unrelated native routes', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('restoring-profile');
  const rules = [
    { id: 'profile-proxy', scope: 'profile', exactHost: 'cdn.example',
      scheme: 'https', port: 443, mode: 'PROXY', groupId: 'shopping' },
    { id: 'site-direct', scope: 'site', topLevelSite: 'https://shop.test',
      exactHost: 'cdn.example', scheme: 'https', port: 443, mode: 'DIRECT' },
    { id: 'profile-block', scope: 'profile', exactHost: 'blocked.test',
      scheme: 'https', port: 443, mode: 'REJECT' },
  ];
  const oldIssuer = prepare(model, routeOwner, 'context-1', {
    rules, endpoints: [fixture.endpoints[0]],
  });
  assert.equal(model.evaluate(issue(model, oldIssuer, 'https://cdn.example/', 'old-shop')).reason,
    'DIRECT');
  assert.equal(model.evaluate(issue(model, oldIssuer, 'https://cdn.example/', 'old-mail',
    'https://mail.test')).action, 'proxy');
  assert.equal(model.restart(routeOwner, 'context-2').ok, true);
  const issuer = model.trustedIssuer(routeOwner);
  const constrained = model.evaluate(issue(model, issuer, 'https://cdn.example/',
    'restoring-mail', 'https://mail.test'));
  assert.deepEqual([constrained.action, constrained.reason],
    ['wait-fail', 'restoring_constrained_route']);
  assert.equal(model.dispatch(constrained).ok, false);
  const blocked = model.evaluate(issue(model, issuer, 'https://blocked.test/', 'restoring-block'));
  assert.deepEqual([blocked.action, blocked.reason],
    ['wait-fail', 'restoring_constrained_route']);
  assert.equal(model.dispatch(blocked).ok, false);
  const opaque = model.evaluate(model.issueRequest({ issuer,
    attribution: { kind: 'opaque', activeTab: 'shop', nak: 'shop' },
    target: 'https://cdn.example/', method: 'GET', requestId: 'restoring-opaque' }));
  assert.equal(opaque.action, 'wait-fail');
  const siteDirect = model.evaluate(issue(model, issuer, 'https://cdn.example/',
    'restoring-shop'));
  assert.deepEqual([siteDirect.action, siteDirect.reason], ['native', 'no_access_snapshot']);
  const unrelated = model.evaluate(issue(model, issuer, 'https://ordinary.test/',
    'restoring-unrelated'));
  assert.deepEqual([unrelated.action, unrelated.reason], ['native', 'no_access_snapshot']);
  assert.equal(model.dispatch(unrelated).ok, true);
  assert.equal(model.restart(routeOwner, 'context-3').ok, true);
  const twice = model.evaluate(issue(model, model.trustedIssuer(routeOwner),
    'https://cdn.example/', 'restoring-twice', 'https://mail.test'));
  assert.equal(twice.action, 'wait-fail');
  assert.equal(model.close(routeOwner).ok, true);
  assert.equal(model.restart(routeOwner, 'context-4').ok, true);
  const reopenedIssuer = model.trustedIssuer(routeOwner);
  assert.equal(model.evaluate(issue(model, reopenedIssuer, 'https://cdn.example/',
    'reopened-constrained', 'https://mail.test')).action, 'wait-fail');
  assert.equal(model.evaluate(issue(model, reopenedIssuer, 'https://ordinary.test/',
    'reopened-native')).action, 'native');
});

test('regression: sent POST tombstone survives restart and forbids same-hop replay', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('post-restart');
  const issuer = prepare(model, routeOwner, 'context-1', {
    rules: [fixture.routes[0]], endpoints: [fixture.endpoints[0]],
  });
  const first = issue(model, issuer, 'https://cdn.example/', 'same-post',
    'https://shop.test', { method: 'POST' });
  assert.equal(model.dispatch(model.evaluate(first)).ok, true);
  assert.equal(model.restart(routeOwner, 'context-2').ok, true);
  const newIssuer = model.trustedIssuer(routeOwner);
  const sameHop = issue(model, newIssuer, 'https://cdn.example/', 'same-post',
    'https://shop.test', { method: 'POST' });
  assert.equal(model.evaluate(sameHop).action, 'wait-fail');
  const nextCommon = { ...fixture.commonGenerations, network_epoch: 5 };
  assert.equal(model.registerEndpoint({ owner: routeOwner, incarnation: 'context-2',
    group: 'shopping', registrationId: 'post-new-context',
    endpointIdentity: endpointIdentity(18101), tuple: tuple(11, nextCommon) }).ok, true);
  const publication = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-2',
    commonGenerations: nextCommon, rules: [fixture.routes[0]],
    endpoints: [{ groupId: 'shopping', registrationId: 'post-new-context' }] });
  assert.equal(model.acknowledgeModelSnapshot(publication.receipt).ok, true);
  assert.equal(model.evaluate(sameHop).action, 'proxy');
  assert.equal(model.dispatch(model.evaluate(sameHop)).reason, 'already_sent');
  const fresh = issue(model, newIssuer, 'https://cdn.example/', 'fresh-post',
    'https://shop.test', { method: 'POST' });
  assert.equal(model.dispatch(model.evaluate(fresh)).ok, true);
});

test('regression: registration ID cannot be reused after unregister, restart or close', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('registration-history');
  assert.equal(model.restart(routeOwner, 'context-1').ok, true);
  const register = (incarnation, credentialIdentity) => model.registerEndpoint({
    owner: routeOwner, incarnation, group: 'shopping', registrationId: 'r1',
    endpointIdentity: { ...endpointIdentity(18101), credentialIdentity }, tuple: tuple(11),
  });
  assert.equal(register('context-1', 'first-credential').ok, true);
  assert.equal(model.unregisterEndpoint(routeOwner, 'r1'), true);
  assert.equal(register('context-1', 'new-credential').reason, 'registration_id_reused');
  assert.equal(model.restart(routeOwner, 'context-2').ok, true);
  assert.equal(register('context-2', 'third-credential').reason, 'registration_id_reused');
  assert.equal(model.close(routeOwner).ok, true);
  assert.equal(model.restart(routeOwner, 'context-3').ok, true);
  assert.equal(register('context-3', 'fourth-credential').reason, 'registration_id_reused');
});

test('unit: publication refuses a trailing-dot exactHost rule', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('canonical-rule');
  assert.equal(model.restart(routeOwner, 'context-1').ok, true);
  const rejected = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations,
    rules: [{ id: 'blocked', scope: 'profile', exactHost: 'target.example.',
      scheme: 'https', port: 443, mode: 'REJECT' }], endpoints: [] });
  assert.equal(rejected.reason, 'invalid_or_conflicting_rule');
});

for (const mode of ['REJECT', 'PROXY']) {
  for (const requestPath of ['initial', 'redirect']) {
    test(`regression: ${mode} trailing-dot ${requestPath} cannot dispatch native`, () => {
    const model = new RequestRoutingContractModel();
    const rule = { id: 'protected', scope: 'profile', exactHost: 'target.example',
      scheme: 'https', port: 443, mode,
      ...(mode === 'PROXY' ? { groupId: 'shopping' } : {}) };
    const issuer = prepare(model, owner(`canonical-${mode}`), 'context-1', {
      rules: [rule], endpoints: mode === 'PROXY' ? [fixture.endpoints[0]] : [],
    });
    const canonical = model.evaluate(issue(model, issuer, 'https://target.example/',
      `${mode}-canonical`));
    assert.equal(canonical.action, mode === 'REJECT' ? 'reject' : 'proxy');

    const assertNoNativeSend = (issued, label) => {
      assert.equal(issued.ok, undefined, label);
      const decision = model.evaluate(issued);
      assert.deepEqual([decision.action, decision.reason],
        ['wait-fail', 'noncanonical_request'], label);
      assert.equal(model.dispatch(decision).reason, 'noncanonical_request', label);
    };
    if (requestPath === 'initial') {
      assertNoNativeSend(issue(model, issuer, 'https://target.example./',
        `${mode}-first`), `${mode} initial trailing-dot target`);
    } else {
      const initial = issue(model, issuer, 'https://unrelated.example/', `${mode}-redirect`);
      assert.equal(model.dispatch(model.evaluate(initial)).ok, true);
      const redirected = model.redirect(initial, { target: 'https://target.example./',
        method: 'GET', navigation: 'subresource' });
      assertNoNativeSend(redirected, `${mode} redirected trailing-dot target`);
    }
    });
  }
}

test('unit: publication refuses a trailing-dot site topLevelSite', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('canonical-site-rule');
  assert.equal(model.restart(routeOwner, 'context-1').ok, true);
  const rejected = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
    commonGenerations: fixture.commonGenerations,
    rules: [{ id: 'site-block', scope: 'site', topLevelSite: 'https://shop.test.',
      exactHost: 'target.example', scheme: 'https', port: 443, mode: 'REJECT' }],
    endpoints: [] });
  assert.equal(rejected.reason, 'invalid_or_conflicting_rule');
});

test('regression: published snapshot rejects trailing-dot target and top site even unmatched', () => {
  const model = new RequestRoutingContractModel();
  const issuer = prepare(model, owner('published-canonical'), 'context-1', {
    rules: [], endpoints: [],
  });
  for (const [requestId, target, topSite] of [
    ['target-tail', 'https://unmatched.example./', 'https://shop.test'],
    ['site-tail', 'https://unmatched.example/', 'https://shop.test.'],
  ]) {
    const decision = model.evaluate(issue(model, issuer, target, requestId, topSite));
    assert.deepEqual([decision.action, decision.reason],
      ['wait-fail', 'noncanonical_request'], requestId);
    assert.equal(model.dispatch(decision).reason, 'noncanonical_request');
  }
  const initial = issue(model, issuer, 'https://unmatched.example/', 'site-tail-redirect');
  assert.equal(model.dispatch(model.evaluate(initial)).ok, true);
  const redirected = model.redirect(initial, { target: 'https://unmatched.example/',
    method: 'GET', navigation: 'main', nextTopLevelSite: 'https://shop.test.' });
  const redirectDecision = model.evaluate(redirected);
  assert.deepEqual([redirectDecision.action, redirectDecision.reason],
    ['wait-fail', 'noncanonical_request']);
  assert.equal(model.dispatch(redirectDecision).reason, 'noncanonical_request');
});

test('regression: never-published owner keeps trailing-dot initial and redirect native', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('never-published');
  assert.equal(model.restart(routeOwner, 'context-1').ok, true);
  const issuer = model.trustedIssuer(routeOwner);
  for (const [requestId, target, topSite] of [
    ['native-target-tail', 'https://unmatched.example./', 'https://shop.test'],
    ['native-site-tail', 'https://unmatched.example/', 'https://shop.test.'],
    ['native-ip-single-tail', 'https://127.0.0.1./', 'https://shop.test'],
    ['native-ip-double-tail', 'https://127.0.0.1../', 'https://shop.test'],
    ['native-ip-site-tail', 'https://unmatched.example/', 'https://127.0.0.1.'],
  ]) {
    const decision = model.evaluate(issue(model, issuer, target, requestId, topSite));
    assert.deepEqual([decision.action, decision.reason], ['native', 'no_access_snapshot']);
    assert.equal(model.dispatch(decision).ok, true);
  }
  for (const [index, target, navigation, nextTopLevelSite] of [
    [0, 'https://unmatched.example./', 'subresource', undefined],
    [1, 'https://unmatched.example/', 'main', 'https://shop.test.'],
  ]) {
    const initial = issue(model, issuer, 'https://unmatched.example/',
      `native-redirect-${index}`);
    assert.equal(model.dispatch(model.evaluate(initial)).ok, true);
    const redirected = model.redirect(initial, { target, method: 'GET', navigation,
      nextTopLevelSite });
    const decision = model.evaluate(redirected);
    assert.deepEqual([decision.action, decision.reason], ['native', 'no_access_snapshot']);
    assert.equal(model.dispatch(decision).ok, true);
  }
});

test('regression: restoring committed proxy constraint rejects trailing-dot target without flag', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('restoring-canonical');
  prepare(model, routeOwner, 'context-1', {
    rules: [{ id: 'proxy', scope: 'profile', exactHost: 'target.example',
      scheme: 'https', port: 443, mode: 'PROXY', groupId: 'shopping' }],
    endpoints: [fixture.endpoints[0]],
  });
  assert.equal(model.restart(routeOwner, 'context-2').ok, true);
  const issuer = model.trustedIssuer(routeOwner);
  const decision = model.evaluate(issue(model, issuer, 'https://target.example./',
    'restoring-tail'));
  assert.deepEqual([decision.action, decision.reason], ['wait-fail', 'noncanonical_request']);
  assert.equal(model.dispatch(decision).reason, 'noncanonical_request');
  const siteTail = model.evaluate(issue(model, issuer, 'https://unmatched.example/',
    'restoring-site-tail', 'https://shop.test.'));
  assert.deepEqual([siteTail.action, siteTail.reason], ['wait-fail', 'noncanonical_request']);
  assert.equal(model.dispatch(siteTail).reason, 'noncanonical_request');
});

test('unit: raw noncanonical IPv4 site and exact host cannot enter a rule', () => {
  for (const [id, exactHost, topLevelSite] of [
    ['site-dot', 'target.example', 'https://127.0.0.1.'],
    ['site-encoded-dot', 'target.example', 'https://127.0.0.1%2e'],
    ['site-short-ip', 'target.example', 'https://127.1.'],
    ['site-port', 'target.example', 'https://127.0.0.1:8443'],
    ['host-dot', '127.0.0.1.', 'https://shop.test'],
    ['host-encoded-dot', '127.0.0.1%2e', 'https://shop.test'],
    ['host-short-ip', '127.1.', 'https://shop.test'],
    ['dns-site-encoded-dot', 'target.example', 'https://shop.test%2e'],
    ['dns-host-encoded-dot', 'target.example%2e', 'https://shop.test'],
  ]) {
    const model = new RequestRoutingContractModel();
    const routeOwner = owner(`raw-${id}`);
    assert.equal(model.restart(routeOwner, 'context-1').ok, true);
    const publication = model.publishSnapshot({ owner: routeOwner, incarnation: 'context-1',
      commonGenerations: fixture.commonGenerations,
      rules: [{ id, scope: 'site', topLevelSite, exactHost,
        scheme: 'https', port: 443, mode: 'REJECT' }], endpoints: [] });
    assert.equal(publication.reason, 'invalid_or_conflicting_rule', id);
  }
});

test('regression: parsed IPv4 single-dot target and site match canonical routes', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('parsed-ipv4');
  const rules = [
    { id: 'canonical-ip-target', scope: 'profile', exactHost: '127.0.0.1',
      scheme: 'https', port: 443, mode: 'REJECT' },
    { id: 'canonical-ip-site', scope: 'site', topLevelSite: 'https://127.0.0.1',
      exactHost: 'resource.test', scheme: 'https', port: 443, mode: 'PROXY',
      groupId: 'shopping' },
  ];
  const issuer = prepare(model, routeOwner, 'context-1', {
    rules, endpoints: [fixture.endpoints[0]],
  });
  for (const [index, rawTarget] of [
    'https://127.0.0.1./', 'https://127.0.0.1%2e/', 'https://127.1./',
  ].entries()) {
    const decision = model.evaluate(issue(model, issuer, rawTarget, `ip-target-${index}`));
    assert.deepEqual([decision.action, decision.reason], ['reject', 'REJECT'], rawTarget);
    assert.equal(model.dispatch(decision).reason, 'locally_rejected');
  }
  for (const [index, rawSite] of [
    'https://127.0.0.1.', 'https://127.0.0.1%2e', 'https://127.1.',
  ].entries()) {
    const decision = model.evaluate(issue(model, issuer, 'https://resource.test/',
      `ip-site-${index}`, rawSite));
    assert.deepEqual([decision.action, decision.registrationId], ['proxy', 'shop-r1'], rawSite);
    assert.equal(model.dispatch(decision).ok, true);
  }
  const initial = issue(model, issuer, 'https://unrelated.test/', 'ip-redirect');
  assert.equal(model.dispatch(model.evaluate(initial)).ok, true);
  const redirected = model.redirect(initial, { target: 'https://resource.test/',
    method: 'GET', navigation: 'main', nextTopLevelSite: 'https://127.0.0.1.' });
  assert.equal(model.evaluate(redirected).registrationId, 'shop-r1');
  assert.equal(model.dispatch(model.evaluate(redirected)).ok, true);
});

test('regression: parsed DNS dot and IPv4 double dot remain fail closed', () => {
  const model = new RequestRoutingContractModel();
  const issuer = prepare(model, owner('parsed-dotted'), 'context-1', {
    rules: [], endpoints: [],
  });
  for (const [index, target, site] of [
    ['dns-target', 'https://target.example./', 'https://shop.test'],
    ['dns-encoded-target', 'https://target.example%2e/', 'https://shop.test'],
    ['dns-site', 'https://safe.test/', 'https://target.example.'],
    ['double-ip-target', 'https://127.0.0.1../', 'https://shop.test'],
    ['double-ip-site', 'https://safe.test/', 'https://127.0.0.1..'],
  ]) {
    const decision = model.evaluate(issue(model, issuer, target, `${index}`, site));
    assert.deepEqual([decision.action, decision.reason],
      ['wait-fail', 'noncanonical_request'], index);
    assert.equal(model.dispatch(decision).reason, 'noncanonical_request');
  }
  const invalidIpv6 = model.issueRequest({ issuer,
    attribution: { kind: 'site', topLevelSite: 'https://shop.test' },
    target: 'https://[::1]./', method: 'GET', requestId: 'invalid-ipv6' });
  assert.equal(invalidIpv6.reason, 'invalid_request');
});

test('regression: normalized IPv4 proxy with lost endpoint does not fall back native', () => {
  const model = new RequestRoutingContractModel();
  const routeOwner = owner('ipv4-missing-endpoint');
  const issuer = prepare(model, routeOwner, 'context-1', {
    rules: [{ id: 'ip-proxy', scope: 'profile', exactHost: '127.0.0.1',
      scheme: 'https', port: 443, mode: 'PROXY', groupId: 'shopping' }],
    endpoints: [fixture.endpoints[0]],
  });
  assert.equal(model.unregisterEndpoint(routeOwner, 'shop-r1'), true);
  const decision = model.evaluate(issue(model, issuer, 'https://127.0.0.1./',
    'lost-ip-endpoint'));
  assert.deepEqual([decision.action, decision.reason],
    ['wait-fail', 'registration_unavailable']);
  assert.equal(model.dispatch(decision).reason, 'registration_unavailable');
});
