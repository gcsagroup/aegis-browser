import { createHash } from 'node:crypto';
import { base64url, compactVerify, compactDecrypt } from 'jose';

// Stage A reference contracts. No issuer, trust root, algorithm or clock default.
export const LIMITS = Object.freeze({
  jsonBytes: 65_536, tokenBytes: 131_072, depth: 12,
  members: 512, arrayItems: 32, stringChars: 32_768, records: 4_096,
});
const codes = new Set([
  'CONTRACT_REJECTED', 'INPUT_TOO_LARGE', 'INVALID_JSON', 'DUPLICATE_FIELD',
  'UNKNOWN_FIELD', 'MISSING_FIELD', 'INVALID_TYPE', 'UNSUPPORTED_VERSION',
  'INVALID_SCOPE', 'PROFILE_UNAVAILABLE', 'PROFILE_UNSUPPORTED',
  'TRUST_BINDING_REQUIRED', 'ALGORITHM_REJECTED', 'UNKNOWN_KEY',
  'SIGNATURE_REJECTED', 'BINDING_MISMATCH', 'CLOCK_REQUIRED', 'NOT_YET_VALID',
  'EXPIRED', 'INVALID_DEADLINE', 'PARENT_REQUIRED', 'PARENT_DEADLINE',
  'REVISION_STATE_REQUIRED', 'REVISION_ROLLBACK', 'REVISION_CONFLICT',
  'SUBJECT_REBINDING', 'STALE_AUTHORITY', 'REVOKED', 'STATE_CAPACITY',
  'IDEMPOTENCY_CONFLICT', 'REPORT_ROLLBACK', 'REPORT_CONFLICT',
  'GRANT_EXCEEDED', 'INVALID_BUDGET', 'CONFIGURATION_DECRYPTION_REJECTED',
  'CONFIGURATION_AUTHENTICITY_UNRESOLVED',
]);
export class ContractError extends Error {
  constructor(code) {
    super('Provider contract rejected.');
    this.name = 'ContractError';
    this.code = codes.has(code) ? code : 'CONTRACT_REJECTED';
  }
  toJSON() { return publicError(this); }
}
function fail(code) { throw new ContractError(code); }
export function publicError(error) {
  return Object.freeze({
    code: error instanceof ContractError && codes.has(error.code)
      ? error.code : 'CONTRACT_REJECTED',
    message: 'Provider contract rejected.',
    retryable: false,
  });
}
function text(input, maxBytes) {
  let value;
  try {
    if (typeof input === 'string') value = input;
    else if (input instanceof Uint8Array) {
      if (input.byteLength > maxBytes) fail('INPUT_TOO_LARGE');
      value = new TextDecoder('utf-8', { fatal: true }).decode(input);
    } else fail('INVALID_TYPE');
  } catch (error) {
    if (error instanceof ContractError) throw error;
    fail('INVALID_JSON');
  }
  if (!value.isWellFormed()) fail('INVALID_JSON');
  if (Buffer.byteLength(value) > maxBytes) fail('INPUT_TOO_LARGE');
  return value;
}

// Detect decoded duplicate keys before JSON.parse can discard them. This scanner
// parses only JSON syntax; signatures and encryption are handled exclusively by jose.
export function parseStrictJson(input) {
  const raw = text(input, LIMITS.jsonBytes);
  let pos = 0;
  let members = 0;
  const ws = () => { while (/^[\x20\x09\x0a\x0d]$/.test(raw[pos] ?? '')) pos++; };
  function string() {
    const start = pos++;
    let closed = false;
    while (pos < raw.length) {
      const ch = raw[pos++];
      if (ch === '"') { closed = true; break; }
      if (ch === '\\') pos++;
    }
    if (!closed) fail('INVALID_JSON');
    let value;
    try { value = JSON.parse(raw.slice(start, pos)); } catch { fail('INVALID_JSON'); }
    if (!value.isWellFormed()) fail('INVALID_JSON');
    if (value.length > LIMITS.stringChars) fail('INPUT_TOO_LARGE');
    return value;
  }
  function value(depth) {
    if (depth > LIMITS.depth) fail('INPUT_TOO_LARGE');
    ws();
    if (raw[pos] === '{') {
      pos++; ws();
      const keys = new Set();
      if (raw[pos] === '}') { pos++; return; }
      while (pos < raw.length) {
        if (raw[pos] !== '"') fail('INVALID_JSON');
        const key = string();
        if (key.length > 64) fail('INPUT_TOO_LARGE');
        if (keys.has(key)) fail('DUPLICATE_FIELD');
        keys.add(key);
        if (++members > LIMITS.members) fail('INPUT_TOO_LARGE');
        ws(); if (raw[pos++] !== ':') fail('INVALID_JSON');
        value(depth + 1); ws();
        const delimiter = raw[pos++];
        if (delimiter === '}') return;
        if (delimiter !== ',') fail('INVALID_JSON');
        ws();
      }
      fail('INVALID_JSON');
    }
    if (raw[pos] === '[') {
      pos++; ws();
      if (raw[pos] === ']') { pos++; return; }
      let count = 0;
      while (pos < raw.length) {
        if (++count > LIMITS.arrayItems) fail('INPUT_TOO_LARGE');
        value(depth + 1); ws();
        const delimiter = raw[pos++];
        if (delimiter === ']') return;
        if (delimiter !== ',') fail('INVALID_JSON');
      }
      fail('INVALID_JSON');
    }
    if (raw[pos] === '"') { string(); return; }
    const token = /^(?:true|false|null|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/.exec(raw.slice(pos));
    if (!token) fail('INVALID_JSON');
    pos += token[0].length;
  }
  value(0); ws();
  if (pos !== raw.length) fail('INVALID_JSON');
  try { return JSON.parse(raw); } catch { fail('INVALID_JSON'); }
}
function freeze(value) {
  if (value && typeof value === 'object') {
    Object.values(value).forEach(freeze); Object.freeze(value);
  }
  return value;
}
const integer = (min = 0) => value => {
  if (!Number.isSafeInteger(value) || value < min) fail('INVALID_TYPE');
};
const id = value => {
  if (typeof value !== 'string' || value.length < 1 || value.length > 128 ||
      !/^[A-Za-z0-9._:-]+$/.test(value)) fail('INVALID_TYPE');
};
const label = value => {
  if (typeof value !== 'string' || value.length < 1 || value.length > 256 ||
      !/^[!-~]+$/.test(value)) fail('INVALID_TYPE');
};
const exact = expected => value => {
  if (value !== expected) fail('INVALID_TYPE');
};
const boolean = value => { if (typeof value !== 'boolean') fail('INVALID_TYPE'); };
function object(value, fields) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) fail('INVALID_TYPE');
  if (Object.keys(value).some(key => !Object.hasOwn(fields, key))) fail('UNKNOWN_FIELD');
  for (const [key, check] of Object.entries(fields)) {
    if (!Object.hasOwn(value, key)) fail('MISSING_FIELD');
    check(value[key]);
  }
}
function scope(expected) {
  return value => {
    if (!Array.isArray(value) || value.length !== expected.length ||
        new Set(value).size !== value.length ||
        value.some(item => !expected.includes(item))) fail('INVALID_SCOPE');
  };
}
export function assertFirstSliceProfile(kind) {
  if (kind === 'normal') return;
  if (kind === 'otr' || kind === 'guest') fail('PROFILE_UNAVAILABLE');
  if (kind === 'system') fail('PROFILE_UNSUPPORTED');
  fail('INVALID_TYPE');
}
const common = {
  version: value => { if (value !== 1) fail('UNSUPPORTED_VERSION'); },
  kind: id, issuer: label, audience: label, realm: id, serviceEnvironment: id,
  issuedAt: integer(), notBefore: integer(), expiresAt: integer(1),
};
const profileBinding = {
  installationRef: id, principalId: id, entitlementAccountId: id,
  credentialId: id, credentialRevision: integer(1),
  profileBinding: id, recipientKeyId: id,
};
const selection = {
  proxyGroupId: id, directoryId: id, directoryRevision: integer(1),
  endpointId: id, nodeId: id, assignmentId: id, reservationId: id,
};
const leaseBinding = {
  ...profileBinding, nodeId: id, endpointId: id, assignmentId: id,
  leaseId: id, leaseRevision: integer(1),
};
const grantBinding = {
  ...leaseBinding, nodeEpoch: integer(1), sessionId: id,
  periodId: id, accountingVersion: id, grantId: id,
};
const schemas = {
  'installation-credential': {
    ...common, scope: scope(['profile:issue']), credentialId: id,
    installationRef: id, installationKeyId: id, entitlementAccountId: id,
    revision: integer(1),
  },
  'profile-credential': {
    ...common, ...profileBinding,
    scope: scope(['directory:read', 'lease:issue', 'usage:read']),
    parentCredentialId: id, identityKind: exact('installation_guest'),
    profileKind: assertFirstSliceProfile,
  },
  directory: {
    ...common, scope: scope(['directory:read']), directoryId: id,
    revision: integer(1), selectionPolicyVersion: integer(1),
    endpoints: value => {
      // This experiment has exactly one selected candidate, no alternate.
      if (!Array.isArray(value) || value.length !== 1) fail('INVALID_TYPE');
      object(value[0], {
        endpointId: id, nodeId: id, proxyGroupId: id, deploymentId: id,
        capacityGroupId: id, trafficPoolId: id, failureDomainId: id,
        protocol: exact('vless-reality-vision'), coreVersion: label,
      });
    },
  },
  'capacity-reservation': {
    ...common, ...profileBinding, ...selection, scope: scope(['capacity:reserve']),
    revision: integer(1), reservedSlots: exact(1),
  },
  'endpoint-lease': {
    ...common, ...profileBinding, ...selection, scope: scope(['proxy:connect']),
    leaseId: id, leaseRevision: integer(1), protocol: exact('vless-reality-vision'),
    configurationRevision: integer(1), connectionDeadline: integer(1),
  },
  'byte-grant': {
    ...common, ...grantBinding, scope: scope(['budget:grant']),
    revision: integer(1), grantedBytes: integer(1), connectionDeadline: integer(1),
  },
  'usage-report': {
    version: common.version, kind: id, ...grantBinding,
    realm: id, serviceEnvironment: id, grantRevision: integer(1), sequence: integer(1),
    upstreamBytes: integer(), downstreamBytes: integer(), final: boolean,
  },
  'lease-request': {
    version: common.version, kind: id, proxyGroupId: id, directoryId: id,
    directoryRevision: integer(1), endpointId: id,
    expectedLeaseRevision: integer(), idempotencyKey: id,
  },
  'node-configuration': {
    version: common.version, kind: id, ...leaseBinding, realm: id,
    serviceEnvironment: id, configurationRevision: integer(1), expiresAt: integer(1),
    configuration: value => {
      if (typeof value !== 'string' || !value.isWellFormed() ||
          value.length < 1 || Buffer.byteLength(value) > 32_768) fail('INVALID_TYPE');
    },
  },
  'budget-state': {
    version: common.version, kind: id, quota: integer(), actual: integer(),
    held: integer(), available: integer(),
  },
};
export function parseUntrusted(kind, input) {
  const fields = schemas[kind];
  if (!fields) fail('UNSUPPORTED_VERSION');
  const value = parseStrictJson(input);
  object(value, fields);
  if (value.kind !== kind) fail('BINDING_MISMATCH');
  return freeze(value);
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}
// A request/content comparison digest, never identity or cryptographic authority.
function digest(value) {
  return createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
}
function clock(value) {
  if (!value || !Number.isSafeInteger(value.now) || value.now < 0 ||
      !Number.isSafeInteger(value.uncertaintySeconds) || value.uncertaintySeconds < 0 ||
      !Number.isSafeInteger(value.now + value.uncertaintySeconds)) fail('CLOCK_REQUIRED');
  return { earliest: value.now - value.uncertaintySeconds, latest: value.now + value.uncertaintySeconds };
}
function time(claims, observation) {
  const interval = clock(observation);
  if (claims.issuedAt > claims.notBefore || claims.notBefore >= claims.expiresAt) fail('INVALID_DEADLINE');
  if (interval.earliest < claims.notBefore) fail('NOT_YET_VALID');
  if (interval.latest >= claims.expiresAt) fail('EXPIRED');
  if ('connectionDeadline' in claims && claims.connectionDeadline !== claims.expiresAt) fail('INVALID_DEADLINE');
}
function same(left, right, fields) {
  if (fields.some(field => left[field] !== right[field])) fail('BINDING_MISMATCH');
}
const privateClaims = new WeakMap();
function claimsOf(handle, kind) {
  const record = privateClaims.get(handle);
  if (!record || (kind && record.claims.kind !== kind)) fail('PARENT_REQUIRED');
  return record;
}
function revisionOf(claims) {
  switch (claims.kind) {
    case 'profile-credential': return claims.credentialRevision;
    case 'endpoint-lease': return claims.leaseRevision;
    case 'installation-credential':
    case 'directory':
    case 'capacity-reservation':
    case 'byte-grant': return claims.revision;
    default: fail('INVALID_TYPE');
  }
}
function subjectOf(claims) {
  const field = {
    'installation-credential': 'credentialId', 'profile-credential': 'credentialId',
    directory: 'directoryId', 'capacity-reservation': 'reservationId',
    'endpoint-lease': 'leaseId', 'byte-grant': 'grantId',
  }[claims.kind];
  return JSON.stringify([claims.kind, claims.issuer, claims.realm, claims[field]]);
}
function immutableOf(claims) {
  let fields = ['kind', 'issuer', 'realm', 'serviceEnvironment', 'audience'];
  if (claims.kind === 'installation-credential') {
    fields.push('installationRef', 'installationKeyId', 'entitlementAccountId');
  } else if (claims.kind !== 'directory') {
    fields.push(...Object.keys(profileBinding), 'nodeId', 'endpointId',
      'assignmentId', 'reservationId', 'leaseId', 'sessionId', 'nodeEpoch',
      'periodId', 'accountingVersion', 'parentCredentialId', 'identityKind');
    // Revision changes are not identity changes.
    fields = fields.filter(field => field !== 'credentialRevision');
  }
  return digest(Object.fromEntries(fields.filter(field => field in claims).map(field => [field, claims[field]])));
}
const revisionRecords = new WeakMap();
function recordRevision(ledger, claims) {
    const records = revisionRecords.get(ledger);
    if (!records) fail('REVISION_STATE_REQUIRED');
    const subject = subjectOf(claims);
    const value = { revision: revisionOf(claims), digest: digest(claims), immutable: immutableOf(claims), revoked: false };
    const previous = records.get(subject);
    if (previous?.revoked) fail('REVOKED');
    if (previous && value.immutable !== previous.immutable) fail('SUBJECT_REBINDING');
    if (previous && value.revision < previous.revision) fail('REVISION_ROLLBACK');
    if (previous && value.revision === previous.revision && value.digest !== previous.digest) fail('REVISION_CONFLICT');
    if (!previous && records.size >= LIMITS.records) fail('STATE_CAPACITY');
    records.set(subject, value);
    return { subject, ...value, disposition: previous?.digest === value.digest ? 'IDEMPOTENT' : 'NEW' };
}
function assertCurrentRevision(record) {
    const current = revisionRecords.get(record.ledger)?.get(record.subject);
    if (current?.revoked) fail('REVOKED');
    if (!current || current.revision !== record.revision || current.digest !== record.digest) fail('STALE_AUTHORITY');
}
export class RevisionLedger {
  constructor() { revisionRecords.set(this, new Map()); }
  revoke(handle) {
    const record = claimsOf(handle);
    if (record.ledger !== this) fail('BINDING_MISMATCH');
    const current = revisionRecords.get(this)?.get(record.subject);
    if (!current) fail('STALE_AUTHORITY');
    // Local fencing only, not a remote revocation acknowledgement.
    current.revoked = true;
  }
}
function admitted(handle, observation, visited = new Set()) {
  const record = claimsOf(handle);
  if (visited.has(handle)) fail('PARENT_REQUIRED');
  visited.add(handle);
  time(record.claims, observation);
  assertCurrentRevision(record);
  for (const parent of record.parents) admitted(parent, observation, visited);
  visited.delete(handle);
  return record.claims;
}
export function admitContract(handle, observation) {
  const claims = admitted(handle, observation);
  return Object.freeze({ status: 'CONTRACT_ONLY_ADMITTED', kind: claims.kind, expiresAt: claims.expiresAt });
}
export function readVerifiedClaims(handle, observation) {
  return freeze(structuredClone(admitted(handle, observation)));
}
function parent(handle, kind, observation) {
  claimsOf(handle, kind);
  return admitted(handle, observation);
}
function childDeadline(child, parents) {
  if (parents.some(value => child.expiresAt > value.expiresAt)) fail('PARENT_DEADLINE');
}
const ownerFields = ['installationRef', 'principalId', 'entitlementAccountId',
  'credentialId', 'credentialRevision', 'profileBinding', 'recipientKeyId',
  'realm', 'serviceEnvironment'];
function parentsFor(claims, context) {
  const parents = context.parents ?? {};
  const used = [];
  const take = (name, kind) => {
    const handle = parents[name];
    const value = parent(handle, kind, context.clock);
    // An artifact cannot acquire a different authority's live ancestor by
    // matching local IDs. Keep the complete chain in its verified issuer domain.
    same(claims, value, ['issuer', 'realm', 'serviceEnvironment']);
    used.push(handle); return value;
  };
  if (claims.kind === 'installation-credential') {
    if (!context.installationKeyId) fail('BINDING_MISMATCH');
    same(claims, context, ['installationKeyId']);
  } else if (claims.kind === 'profile-credential') {
    assertFirstSliceProfile(context.profileKind);
    const install = take('installation', 'installation-credential');
    same(claims, install, ['installationRef', 'entitlementAccountId', 'realm', 'serviceEnvironment']);
    if (claims.parentCredentialId !== install.credentialId) fail('BINDING_MISMATCH');
    if (!context.profileBinding || !context.recipientKeyId) fail('BINDING_MISMATCH');
    same(claims, context, ['profileBinding', 'recipientKeyId']);
    childDeadline(claims, [install]);
  } else if (claims.kind === 'capacity-reservation' || claims.kind === 'endpoint-lease') {
    const profile = take('profile', 'profile-credential');
    const directory = take('directory', 'directory');
    same(claims, profile, ownerFields);
    same(claims, directory, ['directoryId', 'realm', 'serviceEnvironment']);
    if (claims.directoryRevision !== directory.revision) fail('BINDING_MISMATCH');
    same(claims, directory.endpoints[0], ['nodeId', 'endpointId', 'proxyGroupId']);
    if (claims.audience !== claims.nodeId) fail('BINDING_MISMATCH');
    childDeadline(claims, [profile, directory]);
    if (claims.kind === 'endpoint-lease') {
      const reservation = take('reservation', 'capacity-reservation');
      same(claims, reservation, [...ownerFields, ...Object.keys(selection)]);
      childDeadline(claims, [reservation]);
    }
  } else if (claims.kind === 'byte-grant') {
    const lease = take('lease', 'endpoint-lease');
    same(claims, lease, [...Object.keys(leaseBinding), 'realm', 'serviceEnvironment']);
    if (claims.audience !== claims.nodeId || !context.accountingVersion ||
        claims.accountingVersion !== context.accountingVersion) fail('BINDING_MISMATCH');
    childDeadline(claims, [lease]);
  }
  return used;
}
function compactHeader(input, count, headerFields) {
  const token = text(input, LIMITS.tokenBytes);
  const parts = token.split('.');
  if (parts.length !== count || parts.some(part => !/^[A-Za-z0-9_-]*$/.test(part)) ||
      !parts[0]) fail('INVALID_TYPE');
  let header;
  try { header = parseStrictJson(base64url.decode(parts[0])); }
  catch (error) { if (error instanceof ContractError) throw error; fail('INVALID_JSON'); }
  object(header, headerFields);
  return { token, header };
}
export async function verifyArtifact(kind, input, trust, context) {
  if (!trust || !context || !trust.keys || !(trust.keys instanceof Map) ||
      !Array.isArray(trust.allowedAlgorithms) || trust.allowedAlgorithms.length === 0) fail('TRUST_BINDING_REQUIRED');
  for (const field of ['issuer', 'audience', 'realm', 'serviceEnvironment']) {
    if (typeof trust[field] !== 'string' || !trust[field]) fail('TRUST_BINDING_REQUIRED');
  }
  if (!revisionRecords.has(context.revisions)) fail('REVISION_STATE_REQUIRED');
  // Snapshot trusted inputs before yielding to crypto. Ledger revocation/revision
  // state stays live; request/context object mutation cannot change this decision.
  clock(context.clock);
  context = { ...context, clock: { ...context.clock }, parents: { ...context.parents } };
  trust = { ...trust, keys: new Map(trust.keys), allowedAlgorithms: [...trust.allowedAlgorithms] };
  if (!['installation-credential', 'profile-credential', 'directory', 'capacity-reservation', 'endpoint-lease', 'byte-grant'].includes(kind)) fail('INVALID_TYPE');
  const { token, header } = compactHeader(input, 3, {
    alg: label, kid: id, typ: exact('aegis-provider+jws'),
  });
  if (header.alg === 'none' || header.alg.startsWith('HS') ||
      !trust.allowedAlgorithms.includes(header.alg)) fail('ALGORITHM_REJECTED');
  const binding = { ...trust.keys.get(header.kid) };
  if (!binding || !binding.key) fail('UNKNOWN_KEY');
  if (binding.algorithm !== header.alg) fail('ALGORITHM_REJECTED');
  let payload;
  try { ({ payload } = await compactVerify(token, binding.key, { algorithms: [header.alg] })); }
  catch { fail('SIGNATURE_REJECTED'); }
  const claims = parseUntrusted(kind, payload);
  same(claims, trust, ['issuer', 'audience', 'realm', 'serviceEnvironment']);
  time(claims, context.clock);
  const parents = parentsFor(claims, context);
  // Recheck ancestors after all asynchronous crypto work and before recording.
  parents.forEach(handle => admitted(handle, context.clock));
  const state = recordRevision(context.revisions, claims);
  const handle = Object.freeze({ kind, version: 1, disposition: state.disposition });
  privateClaims.set(handle, { claims, parents, ledger: context.revisions, ...state });
  return handle;
}
export class IdempotencyLedger {
  #records = new Map();
  record(profileHandle, input, observation) {
    const profile = parent(profileHandle, 'profile-credential', observation);
    const request = parseUntrusted('lease-request', input);
    const key = JSON.stringify([profile.issuer, profile.realm, profile.principalId,
      profile.serviceEnvironment, profile.installationRef, profile.entitlementAccountId,
      profile.profileBinding, 'lease:issue', request.idempotencyKey]);
    const fingerprint = digest(request);
    const previous = this.#records.get(key);
    if (previous && previous !== fingerprint) fail('IDEMPOTENCY_CONFLICT');
    if (!previous && this.#records.size >= LIMITS.records) fail('STATE_CAPACITY');
    this.#records.set(key, fingerprint);
    return Object.freeze({ disposition: previous ? 'REPLAY_NO_REISSUE' : 'RECORDED',
      authority: false, durable: false });
  }
}
export class UsageRepresentationLedger {
  #records = new Map();
  record(input, grantHandle) {
    // Old reports may describe old grants; this method never renews send authority.
    const grant = claimsOf(grantHandle, 'byte-grant').claims;
    const report = parseUntrusted('usage-report', input);
    same(report, grant, [...Object.keys(grantBinding), 'realm', 'serviceEnvironment']);
    if (report.grantRevision !== grant.revision) fail('BINDING_MISMATCH');
    if (BigInt(report.upstreamBytes) + BigInt(report.downstreamBytes) > BigInt(grant.grantedBytes)) fail('GRANT_EXCEEDED');
    const key = JSON.stringify([subjectOf(grant), grant.revision]);
    const previous = this.#records.get(key);
    const fingerprint = digest(report);
    if (previous) {
      if (report.sequence < previous.report.sequence ||
          report.upstreamBytes < previous.report.upstreamBytes ||
          report.downstreamBytes < previous.report.downstreamBytes ||
          (previous.report.final && !report.final)) fail('REPORT_ROLLBACK');
      if (report.sequence === previous.report.sequence && fingerprint !== previous.digest) fail('REPORT_CONFLICT');
      if (previous.report.final && fingerprint !== previous.digest) fail('REPORT_CONFLICT');
    }
    if (!previous && this.#records.size >= LIMITS.records) fail('STATE_CAPACITY');
    this.#records.set(key, { report, digest: fingerprint });
    return Object.freeze({ status: 'REPRESENTATION_ONLY_NO_SEND_AUTHORITY',
      disposition: previous?.digest === fingerprint ? 'REPLAY' : 'RECORDED',
      authoritativeMetering: false, durable: false });
  }
}
export function validateBudget(input) {
  const value = parseUntrusted('budget-state', input);
  if (BigInt(value.actual) + BigInt(value.held) + BigInt(value.available) !== BigInt(value.quota)) fail('INVALID_BUDGET');
  return Object.freeze({ status: 'CONSERVATION_REPRESENTATION_ONLY', authoritativeMetering: false });
}
export async function inspectConfidentialConfiguration(input, recipient, leaseHandle, observation) {
  clock(observation);
  observation = { ...observation };
  const lease = parent(leaseHandle, 'endpoint-lease', observation);
  if (!recipient?.key || !recipient.keyId ||
      !Array.isArray(recipient.allowedKeyManagementAlgorithms) ||
      recipient.allowedKeyManagementAlgorithms.length === 0 ||
      !Array.isArray(recipient.allowedContentEncryptionAlgorithms) ||
      recipient.allowedContentEncryptionAlgorithms.length === 0) fail('TRUST_BINDING_REQUIRED');
  recipient = { ...recipient,
    allowedKeyManagementAlgorithms: [...recipient.allowedKeyManagementAlgorithms],
    allowedContentEncryptionAlgorithms: [...recipient.allowedContentEncryptionAlgorithms] };
  const { token, header } = compactHeader(input, 5, {
    alg: label, enc: label, kid: id, typ: exact('aegis-configuration+jwe'),
  });
  if (header.kid !== recipient.keyId || header.kid !== lease.recipientKeyId) fail('BINDING_MISMATCH');
  if (!recipient.allowedKeyManagementAlgorithms.includes(header.alg) ||
      !recipient.allowedContentEncryptionAlgorithms.includes(header.enc)) fail('ALGORITHM_REJECTED');
  let plaintext;
  try {
    ({ plaintext } = await compactDecrypt(token, recipient.key, {
      keyManagementAlgorithms: recipient.allowedKeyManagementAlgorithms,
      contentEncryptionAlgorithms: recipient.allowedContentEncryptionAlgorithms,
    }));
  } catch { fail('CONFIGURATION_DECRYPTION_REJECTED'); }
  const value = parseUntrusted('node-configuration', plaintext);
  same(value, lease, [...Object.keys(leaseBinding), 'realm', 'serviceEnvironment', 'configurationRevision']);
  if (value.expiresAt > lease.expiresAt) fail('PARENT_DEADLINE');
  if (clock(observation).latest >= value.expiresAt) fail('EXPIRED');
  admitted(leaseHandle, observation);
  // Public-key encryption can be performed by any sender. No signed ciphertext
  // or nested-payload authenticity binding has been accepted for production.
  // Discard plaintext and return no executable configuration or authority handle.
  return Object.freeze({ kind: 'node-configuration', version: 1,
    status: 'CONFIDENTIALITY_ONLY', executable: false, serverAuthenticity: false });
}
export function requireExecutableConfiguration() {
  fail('CONFIGURATION_AUTHENTICITY_UNRESOLVED');
}
