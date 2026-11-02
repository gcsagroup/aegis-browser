import test, { before } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { CompactSign, CompactEncrypt, generateKeyPair, base64url } from 'jose';
import {
  LIMITS, ContractError, publicError, parseStrictJson, parseUntrusted,
  assertFirstSliceProfile, RevisionLedger, IdempotencyLedger,
  UsageRepresentationLedger, verifyArtifact, admitContract, readVerifiedClaims,
  validateBudget, inspectConfidentialConfiguration, requireExecutableConfiguration,
} from './contract.mjs';

const vectors = JSON.parse(await readFile(new URL('./vectors.json', import.meta.url), 'utf8'));
const fixture = vectors.payloads;
const NOW = vectors.clock;
const raw = value => JSON.stringify(value);
const copy = value => structuredClone(value);
const change = (value, fields) => ({ ...copy(value), ...fields });
const clockAt = now => ({ now, uncertaintySeconds: 0 });
let signing, outsider, encryption, otherRecipient;
before(async () => {
  [signing, outsider, encryption, otherRecipient] = await Promise.all([
    generateKeyPair('ES256'), generateKeyPair('ES256'),
    generateKeyPair('RSA-OAEP-256'), generateKeyPair('RSA-OAEP-256'),
  ]);
});

function trustFor(payload, changes = {}) {
  return {
    issuer: fixture.installation.issuer, audience: payload.audience,
    realm: fixture.installation.realm, serviceEnvironment: fixture.installation.serviceEnvironment,
    allowedAlgorithms: ['ES256'],
    keys: new Map([['fixture-signing-key', { algorithm: 'ES256', key: signing.publicKey }]]),
    ...changes,
  };
}
async function sign(payload, options = {}) {
  return new CompactSign(new TextEncoder().encode(typeof payload === 'string' ? payload : raw(payload)))
    .setProtectedHeader({ alg: 'ES256', kid: 'fixture-signing-key', typ: 'aegis-provider+jws', ...options.header })
    .sign(options.key ?? signing.privateKey);
}
function recipient(changes = {}) {
  return {
    keyId: fixture.lease.recipientKeyId, key: encryption.privateKey,
    allowedKeyManagementAlgorithms: ['RSA-OAEP-256'],
    allowedContentEncryptionAlgorithms: ['A256GCM'], ...changes,
  };
}
async function encrypt(payload = fixture.configuration, options = {}) {
  return new CompactEncrypt(new TextEncoder().encode(typeof payload === 'string' ? payload : raw(payload)))
    .setProtectedHeader({
      alg: 'RSA-OAEP-256', enc: 'A256GCM', kid: fixture.lease.recipientKeyId,
      typ: 'aegis-configuration+jwe', ...options.header,
    }).encrypt(options.key ?? encryption.publicKey);
}
async function verify(payload, context = {}, trust = trustFor(payload), token) {
  return verifyArtifact(payload.kind, token ?? await sign(payload), trust, {
    clock: NOW, ...context,
  });
}
async function chain() {
  const revisions = new RevisionLedger();
  const installation = await verify(fixture.installation, {
    revisions, installationKeyId: fixture.installation.installationKeyId,
  });
  const profile = await verify(fixture.profile, {
    revisions, parents: { installation }, profileKind: 'normal',
    profileBinding: fixture.profile.profileBinding, recipientKeyId: fixture.profile.recipientKeyId,
  });
  const directory = await verify(fixture.directory, { revisions });
  const reservation = await verify(fixture.reservation, {
    revisions, parents: { profile, directory },
  });
  const lease = await verify(fixture.lease, {
    revisions, parents: { profile, directory, reservation },
  });
  const grant = await verify(fixture.grant, {
    revisions, parents: { lease }, accountingVersion: fixture.grant.accountingVersion,
  });
  return { revisions, installation, profile, directory, reservation, lease, grant };
}
function contextFor(name, c) {
  const contexts = {
    installation: { installationKeyId: fixture.installation.installationKeyId },
    profile: {
      parents: { installation: c.installation }, profileKind: 'normal',
      profileBinding: fixture.profile.profileBinding, recipientKeyId: fixture.profile.recipientKeyId,
    },
    directory: {},
    reservation: { parents: { profile: c.profile, directory: c.directory } },
    lease: { parents: { profile: c.profile, directory: c.directory, reservation: c.reservation } },
    grant: { parents: { lease: c.lease }, accountingVersion: fixture.grant.accountingVersion },
  };
  return { revisions: c.revisions, ...contexts[name] };
}
function rejects(code, operation) {
  assert.throws(operation, error => error instanceof ContractError && error.code === code);
}
async function rejectsAsync(code, operation) {
  await assert.rejects(operation, error => error instanceof ContractError && error.code === code);
}
function tamper(token, part) {
  const parts = token.split('.');
  const value = parts[part];
  parts[part] = (value[0] === 'A' ? 'B' : 'A') + value.slice(1);
  return parts.join('.');
}

test('fixture payloads are schema-only, deeply frozen and explicitly synthetic', () => {
  assert.equal(vectors.fixtureOnly, true);
  for (const payload of Object.values(fixture)) {
    const parsed = parseUntrusted(payload.kind, raw(payload));
    assert.deepEqual(parsed, payload);
    assert.equal(Object.isFrozen(parsed), true);
  }
  assert.equal(Object.isFrozen(parseUntrusted('directory', raw(fixture.directory)).endpoints[0]), true);
});

test('the isolated package exposes its reusable ESM contract entry point', async () => {
  const entry = await import('@aegis-local/access-provider-contract');
  assert.equal(entry.verifyArtifact, verifyArtifact);
  assert.equal(entry.inspectConfidentialConfiguration, inspectConfidentialConfiguration);
});

test('duplicate fields including decoded unicode aliases reject before overwrite', () => {
  for (const input of [
    '{"kind":"directory","kind":"profile-credential"}',
    '{"kind":1,"\\u006bind":2}', '{"x":{"a":1,"a":2}}',
  ]) rejects('DUPLICATE_FIELD', () => parseStrictJson(input));
  assert.deepEqual(parseStrictJson('{"a":1,"x":{"a":2}}'), { a: 1, x: { a: 2 } });
});

test('malformed JSON, invalid UTF-8, lone surrogates and wrong input types reject', () => {
  for (const input of ['{"x":01}', '{"x":1,}', '[1,]', '{"x":NaN}', 'true false',
    '{"x":"\\ud800"}', '"unterminated', '', '"\ud800"']) {
    rejects('INVALID_JSON', () => parseStrictJson(input));
  }
  rejects('INVALID_JSON', () => parseStrictJson(Uint8Array.of(0xff)));
  rejects('INVALID_TYPE', () => parseStrictJson({ verified: true }));
  assert.deepEqual(parseStrictJson(new TextEncoder().encode(' \r\n {"ok":true} ')), { ok: true });
});

test('byte, depth, aggregate members, array and string limits are bounded', () => {
  rejects('INPUT_TOO_LARGE', () => parseStrictJson(' '.repeat(LIMITS.jsonBytes + 1)));
  rejects('INPUT_TOO_LARGE', () => parseStrictJson('['.repeat(LIMITS.depth + 1) + '0' + ']'.repeat(LIMITS.depth + 1)));
  rejects('INPUT_TOO_LARGE', () => parseStrictJson(raw(Array(LIMITS.arrayItems + 1).fill(0))));
  const rows = Array(17).fill(null).map(() => Object.fromEntries(Array(32).fill(null).map((_, i) => ['k' + i, 0])));
  rejects('INPUT_TOO_LARGE', () => parseStrictJson(raw(rows)));
  rejects('INPUT_TOO_LARGE', () => parseStrictJson(raw('x'.repeat(LIMITS.stringChars + 1))));
  rejects('INPUT_TOO_LARGE', () => parseStrictJson(raw({ ['x'.repeat(65)]: 1 })));
});

test('unknown fields, prototype-like keys, missing fields, versions and scalar roots reject', () => {
  rejects('UNKNOWN_FIELD', () => parseUntrusted('directory', raw(change(fixture.directory, { verified: true }))));
  rejects('UNKNOWN_FIELD', () => parseUntrusted('directory', raw(fixture.directory).replace('{"version"', '{"__proto__":{},"version"')));
  const missing = copy(fixture.directory); delete missing.issuer;
  rejects('MISSING_FIELD', () => parseUntrusted('directory', raw(missing)));
  rejects('UNSUPPORTED_VERSION', () => parseUntrusted('directory', raw(change(fixture.directory, { version: 2 }))));
  for (const value of [null, [], 1, 'directory']) rejects('INVALID_TYPE', () => parseUntrusted('directory', raw(value)));
  rejects('BINDING_MISMATCH', () => parseUntrusted('directory', raw(change(fixture.directory, { kind: 'endpoint-lease' }))));
});

test('scope is an exact set and numbers must be finite safe nonnegative integers', () => {
  for (const scope of [[], ['directory:read', 'admin'], ['directory:read', 'directory:read'], 'directory:read']) {
    rejects('INVALID_SCOPE', () => parseUntrusted('directory', raw(change(fixture.directory, { scope }))));
  }
  for (const grantedBytes of [null, -1, 1.5, Number.MAX_SAFE_INTEGER + 1, 'unlimited', 0]) {
    rejects('INVALID_TYPE', () => parseUntrusted('byte-grant', raw(change(fixture.grant, { grantedBytes }))));
  }
});

test('first slice explicitly distinguishes normal Profile from OTR, Guest and System', () => {
  assertFirstSliceProfile('normal');
  for (const kind of ['otr', 'guest']) rejects('PROFILE_UNAVAILABLE', () => assertFirstSliceProfile(kind));
  rejects('PROFILE_UNSUPPORTED', () => assertFirstSliceProfile('system'));
  rejects('INVALID_TYPE', () => assertFirstSliceProfile(undefined));
  rejects('INVALID_TYPE', () => parseUntrusted('profile-credential', raw(change(fixture.profile, { identityKind: 'account' }))));
});

test('client labels, verified booleans and copied handles cannot create authority', async () => {
  const c = await chain();
  for (const handle of [
    { verified: true, ...fixture.profile }, parseUntrusted('profile-credential', raw(fixture.profile)),
    { ...c.profile }, { installationRef: fixture.installation.installationRef },
  ]) rejects('PARENT_REQUIRED', () => admitContract(handle, NOW));
  await rejectsAsync('PARENT_REQUIRED', () => verify(fixture.profile, {
    ...contextFor('profile', c), parents: { installation: { verified: true, ...fixture.installation } },
  }));
  assert.equal(c.revisions.record, undefined);
  assert.equal(c.revisions.assertCurrent, undefined);
});

test('actual JWS verification creates opaque contract handles with explicit trust', async () => {
  const c = await chain();
  for (const name of ['installation', 'profile', 'directory', 'reservation', 'lease', 'grant']) {
    assert.equal(admitContract(c[name], NOW).status, 'CONTRACT_ONLY_ADMITTED');
    assert.equal(Object.isFrozen(c[name]), true);
    assert.deepEqual(readVerifiedClaims(c[name], NOW), fixture[name]);
  }
});

test('missing trust, absent revision state and absent conservative clock fail closed', async () => {
  const token = await sign(fixture.directory);
  await rejectsAsync('TRUST_BINDING_REQUIRED', () => verifyArtifact('directory', token, undefined, {}));
  for (const trust of [
    trustFor(fixture.directory, { keys: undefined }), trustFor(fixture.directory, { issuer: '' }),
    trustFor(fixture.directory, { allowedAlgorithms: [] }),
  ]) await rejectsAsync('TRUST_BINDING_REQUIRED', () => verifyArtifact('directory', token, trust, {}));
  await rejectsAsync('REVISION_STATE_REQUIRED', () => verifyArtifact('directory', token, trustFor(fixture.directory), { clock: NOW }));
  await rejectsAsync('REVISION_STATE_REQUIRED', () => verifyArtifact('directory', token, trustFor(fixture.directory), {
    clock: NOW, revisions: Object.create(RevisionLedger.prototype),
  }));
  for (const clock of [undefined, { now: 2000 }, { now: -1, uncertaintySeconds: 0 },
    { now: 2000, uncertaintySeconds: -1 }, { now: Number.MAX_SAFE_INTEGER, uncertaintySeconds: 1 }]) {
    await rejectsAsync('CLOCK_REQUIRED', () => verify(fixture.directory, { revisions: new RevisionLedger(), clock }));
  }
});

test('tampered payload/signature, unrelated signing key and unknown key ID reject', async () => {
  const token = await sign(fixture.directory);
  for (const invalid of [tamper(token, 1), tamper(token, 2), await sign(fixture.directory, { key: outsider.privateKey })]) {
    await rejectsAsync('SIGNATURE_REJECTED', () => verify(fixture.directory, { revisions: new RevisionLedger() }, trustFor(fixture.directory), invalid));
  }
  await rejectsAsync('UNKNOWN_KEY', async () => verify(fixture.directory, { revisions: new RevisionLedger() },
    trustFor(fixture.directory), await sign(fixture.directory, { header: { kid: 'unknown' } })));
});

test('unsigned/symmetric, disallowed and mispinned algorithms reject', async () => {
  const token = await sign(fixture.directory);
  for (const alg of ['none', 'HS256', 'RS256']) {
    const parts = token.split('.');
    parts[0] = base64url.encode(raw({ alg, kid: 'fixture-signing-key', typ: 'aegis-provider+jws' }));
    await rejectsAsync('ALGORITHM_REJECTED', () => verify(fixture.directory, { revisions: new RevisionLedger() }, trustFor(fixture.directory), parts.join('.')));
  }
  await rejectsAsync('ALGORITHM_REJECTED', () => verify(fixture.directory, { revisions: new RevisionLedger() },
    trustFor(fixture.directory, { keys: new Map([['fixture-signing-key', { algorithm: 'RS256', key: signing.publicKey }]]) })));
});

test('JOSE header cannot select embedded keys, URLs, critical extensions or duplicate fields', async () => {
  for (const header of [
    { jku: 'https://fixture.invalid/key' }, { jwk: { kty: 'EC' } }, { x5u: 'https://fixture.invalid/key' },
    { extra: true },
  ]) await rejectsAsync('UNKNOWN_FIELD', async () => verify(fixture.directory, { revisions: new RevisionLedger() },
    trustFor(fixture.directory), await sign(fixture.directory, { header })));
  const parts = (await sign(fixture.directory)).split('.');
  parts[0] = base64url.encode('{"alg":"ES256","kid":"fixture-signing-key","kid":"other","typ":"aegis-provider+jws"}');
  await rejectsAsync('DUPLICATE_FIELD', () => verify(fixture.directory, { revisions: new RevisionLedger() }, trustFor(fixture.directory), parts.join('.')));
  parts[0] = base64url.encode(raw({ alg: 'ES256', kid: 'fixture-signing-key', typ: 'aegis-provider+jws', crit: ['b64'], b64: false }));
  await rejectsAsync('UNKNOWN_FIELD', () => verify(fixture.directory, { revisions: new RevisionLedger() }, trustFor(fixture.directory), parts.join('.')));
  await rejectsAsync('INVALID_TYPE', async () => verify(fixture.directory, { revisions: new RevisionLedger() },
    trustFor(fixture.directory), await sign(fixture.directory, { header: { typ: 'JWT' } })));
});

test('compact token syntax and byte limits reject before authority allocation', async () => {
  for (const token of ['x.y', 'x.y.z.w', '!.y.z', '.y.z']) {
    await rejectsAsync('INVALID_TYPE', () => verify(fixture.directory, { revisions: new RevisionLedger() }, trustFor(fixture.directory), token));
  }
  await rejectsAsync('INPUT_TOO_LARGE', () => verify(fixture.directory, { revisions: new RevisionLedger() }, trustFor(fixture.directory),
    'a'.repeat(LIMITS.tokenBytes + 1)));
});

test('valid signatures cannot override pinned issuer, audience, realm or environment', async () => {
  for (const field of ['issuer', 'audience', 'realm', 'serviceEnvironment']) {
    const payload = change(fixture.directory, { [field]: 'fixture-other' });
    await rejectsAsync('BINDING_MISMATCH', () => verify(payload, { revisions: new RevisionLedger() }, trustFor(fixture.directory)));
  }
  await rejectsAsync('INVALID_SCOPE', () => verify(change(fixture.directory, { scope: ['admin'] }), { revisions: new RevisionLedger() }));
});

test('verification snapshots trusted context and trust while cryptography yields', async () => {
  const payload = fixture.directory;
  const token = await sign(payload);
  const clock = { ...NOW }, trust = trustFor(payload), revisions = new RevisionLedger();
  const context = { clock, revisions };
  const pending = verifyArtifact(payload.kind, token, trust, context);
  trust.issuer = 'fixture-other'; trust.allowedAlgorithms.length = 0; trust.keys.clear();
  clock.now = 3000; context.revisions = new RevisionLedger();
  const handle = await pending;
  assert.equal(admitContract(handle, NOW).status, 'CONTRACT_ONLY_ADMITTED');
  revisions.revoke(handle);
  rejects('REVOKED', () => admitContract(handle, NOW));
});

test('two normal Profiles share entitlement representation but keep independent credentials', async () => {
  const c = await chain();
  const b = change(fixture.profile, {
    principalId: 'fixture-profile-b', credentialId: 'fixture-profile-credential-b',
    profileBinding: 'fixture-normal-profile-b', recipientKeyId: 'fixture-recipient-b',
  });
  const profileB = await verify(b, {
    revisions: c.revisions, parents: { installation: c.installation }, profileKind: 'normal',
    profileBinding: b.profileBinding, recipientKeyId: b.recipientKeyId,
  });
  const claimsB = readVerifiedClaims(profileB, NOW);
  assert.equal(claimsB.entitlementAccountId, fixture.profile.entitlementAccountId);
  assert.notEqual(claimsB.credentialId, fixture.profile.credentialId);
  await rejectsAsync('BINDING_MISMATCH', () => verify(fixture.reservation, {
    revisions: c.revisions, parents: { profile: profileB, directory: c.directory },
  }));
  await rejectsAsync('BINDING_MISMATCH', () => verify(b, {
    ...contextFor('profile', c), profileBinding: fixture.profile.profileBinding,
  }));
  await rejectsAsync('BINDING_MISMATCH', () => verify(b, {
    ...contextFor('profile', c), profileBinding: b.profileBinding, recipientKeyId: fixture.profile.recipientKeyId,
  }));
});

test('installation possession and Profile eligibility must have owner supplied expected bindings', async () => {
  await rejectsAsync('BINDING_MISMATCH', () => verify(fixture.installation, { revisions: new RevisionLedger() }));
  await rejectsAsync('BINDING_MISMATCH', () => verify(fixture.installation, {
    revisions: new RevisionLedger(), installationKeyId: 'fixture-other-key',
  }));
  const c = await chain();
  for (const profileKind of ['otr', 'guest', 'system']) {
    await rejectsAsync(profileKind === 'system' ? 'PROFILE_UNSUPPORTED' : 'PROFILE_UNAVAILABLE',
      () => verify(fixture.profile, { ...contextFor('profile', c), profileKind }));
  }
  for (const field of ['profileBinding', 'recipientKeyId']) {
    await rejectsAsync('BINDING_MISMATCH', () => verify(fixture.profile, { ...contextFor('profile', c), [field]: undefined }));
  }
});

test('signed parent bindings reject installation/account/recipient/profile mismatches', async () => {
  const c = await chain();
  for (const field of ['installationRef', 'entitlementAccountId', 'parentCredentialId']) {
    await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.profile, { [field]: 'fixture-other' }), contextFor('profile', c)));
  }
  for (const field of ['installationRef', 'principalId', 'credentialId', 'profileBinding', 'recipientKeyId', 'entitlementAccountId']) {
    await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.lease, { [field]: 'fixture-other' }), contextFor('lease', c)));
  }
  await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.lease, { credentialRevision: 2 }), contextFor('lease', c)));
});

test('directory selection and reservation must match exact node, assignment and revision', async () => {
  const c = await chain();
  for (const field of ['directoryId', 'endpointId', 'nodeId', 'proxyGroupId', 'assignmentId', 'reservationId']) {
    await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.lease, { [field]: 'fixture-other' }), contextFor('lease', c)));
  }
  await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.lease, { directoryRevision: 2 }), contextFor('lease', c)));
  await rejectsAsync('PARENT_REQUIRED', () => verify(fixture.lease, {
    ...contextFor('lease', c), parents: { profile: c.profile, directory: c.directory, reservation: c.grant },
  }));
});

test('capacity is a slot reservation and never a byte grant or fallback list', async () => {
  rejects('UNKNOWN_FIELD', () => parseUntrusted('capacity-reservation', raw(change(fixture.reservation, { grantedBytes: 1000 }))));
  rejects('UNKNOWN_FIELD', () => parseUntrusted('byte-grant', raw(change(fixture.grant, { reservedSlots: 1 }))));
  rejects('INVALID_TYPE', () => parseUntrusted('capacity-reservation', raw(change(fixture.reservation, { reservedSlots: 2 }))));
  rejects('INVALID_TYPE', () => parseUntrusted('directory', raw(change(fixture.directory, {
    endpoints: [...fixture.directory.endpoints, ...fixture.directory.endpoints],
  }))));
  const c = await chain();
  await rejectsAsync('PARENT_REQUIRED', () => verify(fixture.grant, {
    ...contextFor('grant', c), parents: { lease: c.reservation },
  }));
});

test('grant authority binds exact lease/assignment/node/recipient and accounting version', async () => {
  const c = await chain();
  for (const field of ['leaseId', 'assignmentId', 'nodeId', 'endpointId', 'recipientKeyId', 'profileBinding']) {
    await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.grant, { [field]: 'fixture-other' }), contextFor('grant', c)));
  }
  await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.grant, { leaseRevision: 2 }), contextFor('grant', c)));
  await rejectsAsync('BINDING_MISMATCH', () => verify(fixture.grant, { ...contextFor('grant', c), accountingVersion: undefined }));
  await rejectsAsync('BINDING_MISMATCH', () => verify(change(fixture.grant, { accountingVersion: 'fixture-other' }), contextFor('grant', c)));
});

test('not-before, exact expiry and uncertainty use conservative rejection boundaries', async () => {
  const c = await chain();
  assert.equal(admitContract(c.grant, clockAt(1900)).status, 'CONTRACT_ONLY_ADMITTED');
  rejects('NOT_YET_VALID', () => admitContract(c.grant, clockAt(1899)));
  assert.equal(admitContract(c.grant, clockAt(2199)).status, 'CONTRACT_ONLY_ADMITTED');
  rejects('EXPIRED', () => admitContract(c.grant, clockAt(2200)));
  rejects('NOT_YET_VALID', () => admitContract(c.grant, { now: 1900, uncertaintySeconds: 1 }));
  rejects('EXPIRED', () => admitContract(c.grant, { now: 2199, uncertaintySeconds: 1 }));
  await rejectsAsync('EXPIRED', () => verify(fixture.directory, { revisions: new RevisionLedger(), clock: clockAt(2600) }));
});

test('child lifetime cannot exceed any parent and connection deadline equals expiry', async () => {
  const c = await chain();
  for (const [name, fields] of [
    ['profile', { expiresAt: 2601 }], ['reservation', { expiresAt: 2501 }],
    ['lease', { expiresAt: 2401, connectionDeadline: 2401 }],
    ['grant', { expiresAt: 2301, connectionDeadline: 2301 }],
  ]) await rejectsAsync('PARENT_DEADLINE', () => verify(change(fixture[name], fields), contextFor(name, c)));
  for (const fields of [{ issuedAt: 2001 }, { notBefore: 2600 }, { notBefore: 2700 }]) {
    await rejectsAsync('INVALID_DEADLINE', () => verify(change(fixture.directory, fields), { revisions: new RevisionLedger() }));
  }
  await rejectsAsync('INVALID_DEADLINE', () => verify(change(fixture.lease, { connectionDeadline: 2301 }), contextFor('lease', c)));
});

test('revision replay is idempotent, rollback/conflict reject and old handles become stale', async () => {
  const c = await chain();
  const replay = await verify(fixture.directory, contextFor('directory', c));
  assert.equal(replay.disposition, 'IDEMPOTENT');
  await rejectsAsync('REVISION_CONFLICT', () => verify(change(fixture.directory, { selectionPolicyVersion: 2 }), contextFor('directory', c)));
  const newer = await verify(change(fixture.directory, { revision: 2 }), contextFor('directory', c));
  assert.equal(newer.disposition, 'NEW');
  rejects('STALE_AUTHORITY', () => admitContract(c.directory, NOW));
  rejects('STALE_AUTHORITY', () => admitContract(c.lease, NOW));
  await rejectsAsync('REVISION_ROLLBACK', () => verify(fixture.directory, contextFor('directory', c)));
});

test('revision updates cannot rebind identity, recipient, account or node', async () => {
  const c = await chain();
  const install = change(fixture.installation, { revision: 2, installationRef: 'fixture-other-installation' });
  await rejectsAsync('SUBJECT_REBINDING', () => verify(install, contextFor('installation', c)));
  const profile = change(fixture.profile, { credentialRevision: 2, recipientKeyId: 'fixture-other-recipient' });
  await rejectsAsync('SUBJECT_REBINDING', () => verify(profile, {
    ...contextFor('profile', c), recipientKeyId: profile.recipientKeyId,
  }));
});

test('local revocation propagates ancestors and cannot be reversed by replay', async () => {
  const c = await chain();
  c.revisions.revoke(c.installation);
  for (const name of ['installation', 'profile', 'lease', 'grant']) rejects('REVOKED', () => admitContract(c[name], NOW));
  await rejectsAsync('REVOKED', () => verify(fixture.installation, contextFor('installation', c)));
  rejects('BINDING_MISMATCH', () => new RevisionLedger().revoke(c.directory));
  rejects('PARENT_REQUIRED', () => c.revisions.revoke({ verified: true }));
});

test('parent revocation during asynchronous child verification rejects before issuing a handle', async () => {
  const c = await chain();
  const token = await sign(fixture.profile);
  const pending = verifyArtifact('profile-credential', token, trustFor(fixture.profile), { clock: NOW, ...contextFor('profile', c) });
  c.revisions.revoke(c.installation);
  await rejectsAsync('REVOKED', () => pending);
});

test('expired replay cannot renew or recreate contract admission', async () => {
  const c = await chain();
  await rejectsAsync('EXPIRED', () => verify(fixture.grant, { ...contextFor('grant', c), clock: clockAt(2200) }));
  rejects('EXPIRED', () => admitContract(c.grant, clockAt(2200)));
});

test('same idempotency key preserves result through credential revision without reissue', async () => {
  const c = await chain(), ledger = new IdempotencyLedger();
  assert.deepEqual(ledger.record(c.profile, raw(fixture.request), NOW), {
    disposition: 'RECORDED', authority: false, durable: false,
  });
  assert.equal(ledger.record(c.profile, raw(fixture.request), NOW).disposition, 'REPLAY_NO_REISSUE');
  rejects('IDEMPOTENCY_CONFLICT', () => ledger.record(c.profile, raw(change(fixture.request, { expectedLeaseRevision: 1 })), NOW));
  const renewed = await verify(change(fixture.profile, { credentialRevision: 2 }), contextFor('profile', c));
  assert.equal(ledger.record(renewed, raw(fixture.request), NOW).disposition, 'REPLAY_NO_REISSUE');
  rejects('STALE_AUTHORITY', () => ledger.record(c.profile, raw(fixture.request), NOW));
  rejects('EXPIRED', () => ledger.record(renewed, raw(fixture.request), clockAt(2500)));
});

test('idempotency is scoped to independently authenticated Profiles', async () => {
  const c = await chain(), ledger = new IdempotencyLedger();
  ledger.record(c.profile, raw(fixture.request), NOW);
  const b = change(fixture.profile, { credentialId: 'fixture-credential-b', principalId: 'fixture-profile-b', profileBinding: 'fixture-profile-binding-b' });
  const profile = await verify(b, { ...contextFor('profile', c), profileBinding: b.profileBinding });
  assert.equal(ledger.record(profile, raw(change(fixture.request, { expectedLeaseRevision: 1 })), NOW).disposition, 'RECORDED');
  rejects('PARENT_REQUIRED', () => ledger.record({ verified: true }, raw(fixture.request), NOW));
});

test('idempotency storage is bounded and same-key replay works at capacity', async () => {
  const c = await chain(), ledger = new IdempotencyLedger();
  for (let i = 0; i < LIMITS.records; i++) {
    ledger.record(c.profile, raw(change(fixture.request, { idempotencyKey: 'fixture-key-' + i })), NOW);
  }
  rejects('STATE_CAPACITY', () => ledger.record(c.profile, raw(change(fixture.request, { idempotencyKey: 'fixture-overflow' })), NOW));
  assert.equal(ledger.record(c.profile, raw(change(fixture.request, { idempotencyKey: 'fixture-key-0' })), NOW).disposition, 'REPLAY_NO_REISSUE');
});

test('usage report is cumulative representation with exact authenticated-grant identifiers', async () => {
  const c = await chain(), ledger = new UsageRepresentationLedger();
  assert.deepEqual(ledger.record(raw(fixture.report), c.grant), {
    status: 'REPRESENTATION_ONLY_NO_SEND_AUTHORITY', disposition: 'RECORDED',
    authoritativeMetering: false, durable: false,
  });
  assert.equal(ledger.record(raw(fixture.report), c.grant).disposition, 'REPLAY');
  for (const field of ['installationRef', 'principalId', 'entitlementAccountId', 'credentialId',
    'profileBinding', 'recipientKeyId', 'nodeId', 'endpointId', 'assignmentId', 'leaseId',
    'sessionId', 'periodId', 'accountingVersion', 'grantId', 'realm', 'serviceEnvironment']) {
    rejects('BINDING_MISMATCH', () => ledger.record(raw(change(fixture.report, { [field]: 'fixture-other' })), c.grant));
  }
  for (const field of ['nodeEpoch', 'leaseRevision', 'credentialRevision', 'grantRevision']) {
    rejects('BINDING_MISMATCH', () => ledger.record(raw(change(fixture.report, { [field]: 2 })), c.grant));
  }
  rejects('PARENT_REQUIRED', () => ledger.record(raw(fixture.report), c.reservation));
});

test('usage sequence, cumulative counters, finality and grant maximum reject inconsistent reports', async () => {
  const c = await chain(), ledger = new UsageRepresentationLedger();
  ledger.record(raw(fixture.report), c.grant);
  rejects('REPORT_CONFLICT', () => ledger.record(raw(change(fixture.report, { upstreamBytes: 101 })), c.grant));
  rejects('REPORT_ROLLBACK', () => ledger.record(raw(change(fixture.report, { sequence: 2, upstreamBytes: 99 })), c.grant));
  const second = change(fixture.report, { sequence: 2, upstreamBytes: 300 });
  ledger.record(raw(second), c.grant);
  rejects('REPORT_ROLLBACK', () => ledger.record(raw(fixture.report), c.grant));
  rejects('GRANT_EXCEEDED', () => ledger.record(raw(change(second, { sequence: 3, upstreamBytes: 1000 })), c.grant));
  const final = change(second, { sequence: 3, final: true });
  ledger.record(raw(final), c.grant);
  assert.equal(ledger.record(raw(final), c.grant).disposition, 'REPLAY');
  rejects('REPORT_ROLLBACK', () => ledger.record(raw(change(final, { sequence: 4, final: false })), c.grant));
  rejects('REPORT_CONFLICT', () => ledger.record(raw(change(final, { sequence: 4 })), c.grant));
});

test('expired/revoked grant reports cannot restore send authority', async () => {
  const c = await chain(), ledger = new UsageRepresentationLedger();
  rejects('EXPIRED', () => admitContract(c.grant, clockAt(2200)));
  c.revisions.revoke(c.grant);
  assert.equal(ledger.record(raw(fixture.report), c.grant).authoritativeMetering, false);
  rejects('REVOKED', () => admitContract(c.grant, NOW));
  rejects('PARENT_REQUIRED', () => admitContract(ledger.record(raw(fixture.report), c.grant), NOW));
});

test('finite budget conservation does not imply measurement, settlement or unknown/unlimited capacity', () => {
  assert.deepEqual(validateBudget(raw(fixture.budget)), {
    status: 'CONSERVATION_REPRESENTATION_ONLY', authoritativeMetering: false,
  });
  for (const fields of [{ available: 601 }, { actual: 1001 }, { held: 1001 }]) {
    rejects('INVALID_BUDGET', () => validateBudget(raw(change(fixture.budget, fields))));
  }
  for (const quota of [null, 'unlimited', Number.MAX_SAFE_INTEGER + 1, -1]) {
    rejects('INVALID_TYPE', () => validateBudget(raw(change(fixture.budget, { quota }))));
  }
  rejects('INVALID_BUDGET', () => validateBudget(raw({
    version: 1, kind: 'budget-state', quota: Number.MAX_SAFE_INTEGER,
    actual: Number.MAX_SAFE_INTEGER, held: Number.MAX_SAFE_INTEGER, available: 2,
  })));
  // Deterministic cross-Profile held amounts sharing one finite pool.
  for (let profileA = 0; profileA <= 10; profileA++) {
    for (let profileB = 0; profileB <= 10 - profileA; profileB++) {
      const held = profileA + profileB;
      validateBudget(raw({ version: 1, kind: 'budget-state', quota: 20, actual: 5, held, available: 15 - held }));
    }
  }
});

test('signed directory establishes fixture authenticity; JWE alone yields confidentiality only', async () => {
  const c = await chain();
  assert.equal(readVerifiedClaims(c.directory, NOW).directoryId, fixture.directory.directoryId);
  // An unrelated sender only needs the recipient public key to encrypt.
  const token = await encrypt();
  const result = await inspectConfidentialConfiguration(token, recipient(), c.lease, NOW);
  assert.deepEqual(result, {
    kind: 'node-configuration', version: 1, status: 'CONFIDENTIALITY_ONLY',
    executable: false, serverAuthenticity: false,
  });
  rejects('PARENT_REQUIRED', () => admitContract(result, NOW));
  rejects('CONFIGURATION_AUTHENTICITY_UNRESOLVED', () => requireExecutableConfiguration(result));
  assert.equal(raw(result).includes(fixture.configuration.configuration), false);
});

test('JWE rejects wrong recipient, private key, tampering, algorithms and absent bindings', async () => {
  const c = await chain(), token = await encrypt();
  await rejectsAsync('BINDING_MISMATCH', () => inspectConfidentialConfiguration(token, recipient({ keyId: 'fixture-other' }), c.lease, NOW));
  await rejectsAsync('CONFIGURATION_DECRYPTION_REJECTED', () => inspectConfidentialConfiguration(token, recipient({ key: otherRecipient.privateKey }), c.lease, NOW));
  for (const part of [1, 3, 4]) await rejectsAsync('CONFIGURATION_DECRYPTION_REJECTED',
    () => inspectConfidentialConfiguration(tamper(token, part), recipient(), c.lease, NOW));
  await rejectsAsync('ALGORITHM_REJECTED', () => inspectConfidentialConfiguration(token,
    recipient({ allowedContentEncryptionAlgorithms: ['A128GCM'] }), c.lease, NOW));
  await rejectsAsync('TRUST_BINDING_REQUIRED', () => inspectConfidentialConfiguration(token, undefined, c.lease, NOW));
  await rejectsAsync('PARENT_REQUIRED', () => inspectConfidentialConfiguration(token, recipient(), c.directory, NOW));
  await rejectsAsync('EXPIRED', () => inspectConfidentialConfiguration(token, recipient(), c.lease, clockAt(2300)));
});

test('JWE configuration binds exact lease tuple, revision, realm and bounded lifetime', async () => {
  const c = await chain();
  for (const field of ['leaseId', 'assignmentId', 'nodeId', 'endpointId', 'recipientKeyId', 'profileBinding', 'realm']) {
    await rejectsAsync('BINDING_MISMATCH', async () => inspectConfidentialConfiguration(
      await encrypt(change(fixture.configuration, { [field]: 'fixture-other' })), recipient(), c.lease, NOW));
  }
  for (const field of ['configurationRevision', 'leaseRevision']) {
    await rejectsAsync('BINDING_MISMATCH', async () => inspectConfidentialConfiguration(
      await encrypt(change(fixture.configuration, { [field]: 2 })), recipient(), c.lease, NOW));
  }
  await rejectsAsync('PARENT_DEADLINE', async () => inspectConfidentialConfiguration(
    await encrypt(change(fixture.configuration, { expiresAt: 2301 })), recipient(), c.lease, NOW));
  await rejectsAsync('EXPIRED', async () => inspectConfidentialConfiguration(
    await encrypt(change(fixture.configuration, { expiresAt: 2000 })), recipient(), c.lease, NOW));
});

test('JWE header/payload duplicates and unknown fields reject with no secret diagnostics', async () => {
  const c = await chain();
  await rejectsAsync('UNKNOWN_FIELD', async () => inspectConfidentialConfiguration(
    await encrypt(fixture.configuration, { header: { jku: 'https://fixture.invalid/key' } }), recipient(), c.lease, NOW));
  const duplicate = raw(fixture.configuration).replace('{"version"', '{"leaseId":"secret-untrusted","version"');
  await rejectsAsync('DUPLICATE_FIELD', async () => inspectConfidentialConfiguration(await encrypt(duplicate), recipient(), c.lease, NOW));
  await rejectsAsync('UNKNOWN_FIELD', async () => inspectConfidentialConfiguration(
    await encrypt(change(fixture.configuration, { extraSecret: 'never-public' })), recipient(), c.lease, NOW));
});

test('configuration revocation during decryption is checked before the result returns', async () => {
  const c = await chain(), token = await encrypt();
  const pending = inspectConfidentialConfiguration(token, recipient(), c.lease, NOW);
  c.revisions.revoke(c.lease);
  await rejectsAsync('REVOKED', () => pending);
});

test('public error serialization never echoes payloads, causes or unknown messages', async () => {
  const secret = fixture.configuration.configuration;
  const supplied = new Error(secret, { cause: secret });
  assert.deepEqual(publicError(supplied), {
    code: 'CONTRACT_REJECTED', message: 'Provider contract rejected.', retryable: false,
  });
  assert.equal(raw(new ContractError(secret)).includes(secret), false);
  const c = await chain();
  let caught;
  try {
    await inspectConfidentialConfiguration(await encrypt(change(fixture.configuration, { leaseId: 'synthetic-secret' })), recipient(), c.lease, NOW);
  } catch (error) { caught = error; }
  assert.equal(caught.code, 'BINDING_MISMATCH');
  for (const output of [caught.message, caught.stack, raw(caught), raw(publicError(caught))]) {
    assert.equal(output.includes(secret), false);
    assert.equal(output.includes('synthetic-secret'), false);
  }
});


// Review regressions use independently pinned ephemeral signing keys. Issuers
// deliberately share every local ID/realm/environment to expose cross-domain
// ancestor substitution; these fixtures introduce no production trust defaults.
async function verifyIssuer(payload, keyPair, context) {
  const trust = trustFor(payload, {
    issuer: payload.issuer,
    keys: new Map([['fixture-signing-key', { algorithm: 'ES256', key: keyPair.publicKey }]]),
  });
  return verify(payload, context, trust, await sign(payload, { key: keyPair.privateKey }));
}
async function issuerChain(issuer, keyPair, revisions) {
  const names = ['installation', 'profile', 'directory', 'reservation', 'lease', 'grant'];
  const payloads = Object.fromEntries(names.map(name => [name, change(fixture[name], { issuer })]));
  const c = { revisions, payloads, keyPair };
  for (const name of names) c[name] = await verifyIssuer(payloads[name], keyPair, contextFor(name, c));
  return c;
}

test('review regression: a revoked issuer cannot replay authority through another issuer root', async () => {
  const revisions = new RevisionLedger();
  const a = await issuerChain(fixture.installation.issuer, signing, revisions);
  const b = await issuerChain('https://fixture.invalid/provider-b', outsider, revisions);
  assert.equal(admitContract(a.grant, NOW).status, 'CONTRACT_ONLY_ADMITTED');
  assert.equal(admitContract(b.grant, NOW).status, 'CONTRACT_ONLY_ADMITTED');
  revisions.revoke(b.installation);
  rejects('REVOKED', () => admitContract(b.profile, NOW));
  rejects('REVOKED', () => admitContract(b.grant, NOW));

  // Each replay is correctly signed by B, and all identifier values match A.
  // None may graft a live A branch into B's previously revoked ancestor chain.
  for (const name of ['profile', 'reservation', 'lease', 'grant']) {
    const context = contextFor(name, a);
    await rejectsAsync('BINDING_MISMATCH', () => verifyIssuer(b.payloads[name], outsider, context));
  }
  rejects('REVOKED', () => admitContract(b.grant, NOW));
  assert.equal(admitContract(a.grant, NOW).status, 'CONTRACT_ONLY_ADMITTED');
});

for (const [name, parentName] of [
  ['profile', 'installation'], ['reservation', 'profile'], ['reservation', 'directory'],
  ['lease', 'profile'], ['lease', 'directory'], ['lease', 'reservation'], ['grant', 'lease'],
]) {
  test('review regression: issuer binding at ' + name + ' -> ' + parentName, async () => {
    const revisions = new RevisionLedger();
    const a = await issuerChain(fixture.installation.issuer, signing, revisions);
    const b = await issuerChain('https://fixture.invalid/provider-b', outsider, revisions);
    const context = contextFor(name, b);
    context.parents = { ...context.parents, [parentName]: a[parentName] };
    await rejectsAsync('BINDING_MISMATCH', () => verifyIssuer(b.payloads[name], outsider, context));
    // Rejection must leave both independently signed chains unchanged.
    assert.equal(admitContract(a.grant, NOW).status, 'CONTRACT_ONLY_ADMITTED');
    assert.equal(admitContract(b.grant, NOW).status, 'CONTRACT_ONLY_ADMITTED');
  });
}

for (const [name, revisionField, descendant] of [
  ['reservation', 'revision', 'lease'],
  ['lease', 'leaseRevision', 'grant'],
  ['grant', 'revision', undefined],
]) {
  test('review regression: ' + name + ' uses its own revision while Profile remains revision 1', async () => {
    const c = await chain();
    const context = contextFor(name, c);
    const renewedPayload = change(fixture[name], { [revisionField]: 2 });
    const renewed = await verify(renewedPayload, context);
    assert.equal(renewed.disposition, 'NEW');
    const renewedClaims = readVerifiedClaims(renewed, NOW);
    assert.equal(renewedClaims[revisionField], 2);
    assert.equal(renewedClaims.credentialRevision, 1);
    assert.equal(readVerifiedClaims(c.profile, NOW).credentialRevision, 1);
    assert.equal(admitContract(c.profile, NOW).status, 'CONTRACT_ONLY_ADMITTED');
    assert.equal((await verify(renewedPayload, context)).disposition, 'IDEMPOTENT');

    const conflictingPayload = change(renewedPayload, { expiresAt: renewedPayload.expiresAt - 1 });
    if ('connectionDeadline' in conflictingPayload) conflictingPayload.connectionDeadline = conflictingPayload.expiresAt;
    await rejectsAsync('REVISION_CONFLICT', () => verify(conflictingPayload, context));
    await rejectsAsync('REVISION_ROLLBACK', () => verify(fixture[name], context));
    rejects('STALE_AUTHORITY', () => admitContract(c[name], NOW));
    if (descendant) rejects('STALE_AUTHORITY', () => admitContract(c[descendant], NOW));
    assert.equal(admitContract(renewed, NOW).status, 'CONTRACT_ONLY_ADMITTED');
    assert.equal(readVerifiedClaims(c.profile, NOW).credentialRevision, 1);
  });
}

test('review regression: reservation lease and grant renew together without renewing Profile', async () => {
  const c = await chain();
  const reservationPayload = change(fixture.reservation, { revision: 2 });
  const reservation = await verify(reservationPayload, contextFor('reservation', c));
  const leasePayload = change(fixture.lease, { leaseRevision: 2 });
  const lease = await verify(leasePayload, {
    ...contextFor('lease', c), parents: { profile: c.profile, directory: c.directory, reservation },
  });
  const grantPayload = change(fixture.grant, { revision: 2, leaseRevision: 2 });
  const grant = await verify(grantPayload, {
    ...contextFor('grant', c), parents: { lease },
  });
  for (const handle of [reservation, lease, grant]) {
    assert.equal(admitContract(handle, NOW).status, 'CONTRACT_ONLY_ADMITTED');
    assert.equal(readVerifiedClaims(handle, NOW).credentialRevision, 1);
  }
  for (const handle of [c.reservation, c.lease, c.grant]) {
    rejects('STALE_AUTHORITY', () => admitContract(handle, NOW));
  }
  assert.equal(readVerifiedClaims(c.profile, NOW).credentialRevision, 1);
  const reports = new UsageRepresentationLedger();
  const report = change(fixture.report, { grantRevision: 2, leaseRevision: 2 });
  assert.equal(reports.record(raw(report), grant).authoritativeMetering, false);
  rejects('BINDING_MISMATCH', () => reports.record(raw(fixture.report), grant));
});
