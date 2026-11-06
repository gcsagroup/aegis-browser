import { createHash } from 'node:crypto';
import { base64url, compactVerify, importJWK } from 'jose';
import { parseStrictJson, parseUntrusted } from '@aegis-local/access-provider-contract';

const errorCodes = new Set([
  'INVALID_INPUT', 'INVALID_JSON', 'INPUT_TOO_LARGE', 'DUPLICATE_FIELD',
  'UNKNOWN_FIELD', 'UNSUPPORTED_VERSION', 'PROFILE_UNAVAILABLE', 'PROFILE_UNSUPPORTED',
  'BINDING_REQUIRED', 'PRODUCTION_BINDINGS_UNAVAILABLE', 'PROOF_REJECTED',
  'BINDING_MISMATCH', 'UNAUTHORIZED', 'OWNERSHIP_REQUIRED', 'EXPIRED',
  'NOT_YET_VALID', 'CLOCK_UNTRUSTED', 'IDEMPOTENCY_CONFLICT', 'CHALLENGE_CONSUMED',
  'REVOKED', 'STALE_AUTHORITY', 'STATE_CAPACITY', 'DB_UNAVAILABLE',
  'DEADLINE_EXCEEDED', 'NOT_AVAILABLE', 'SQL_NOT_ADMITTED', 'SERVER_CLOSED',
]);
export class ProviderError extends Error {
  constructor(code) {
    super('Provider request rejected.');
    this.name = 'ProviderError';
    this.code = errorCodes.has(code) ? code : 'INVALID_INPUT';
  }
}
export const reject = code => { throw new ProviderError(code); };
export function publicFailure(error) {
  const code = error instanceof ProviderError ? error.code : 'DB_UNAVAILABLE';
  const status = {
    INPUT_TOO_LARGE: 413, PROOF_REJECTED: 401, UNAUTHORIZED: 401,
    OWNERSHIP_REQUIRED: 403, REVOKED: 403, EXPIRED: 403, STALE_AUTHORITY: 403,
    IDEMPOTENCY_CONFLICT: 409, CHALLENGE_CONSUMED: 409,
    STATE_CAPACITY: 503, DB_UNAVAILABLE: 503, DEADLINE_EXCEEDED: 503,
    NOT_AVAILABLE: 404, SERVER_CLOSED: 503,
  }[code] ?? 400;
  return Object.freeze({ status, body: { code, message: 'Provider request rejected.', retryable: false } });
}
export function identifier(value, maximum = 128) {
  if (typeof value !== 'string' || !value || value.length > maximum ||
      !/^[A-Za-z0-9._:-]+$/.test(value)) reject('INVALID_INPUT');
  return value;
}
export function safeInteger(value, minimum = 0) {
  if (!Number.isSafeInteger(value) || value < minimum) reject('INVALID_INPUT');
  return value;
}
export function exactFields(value, names) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) reject('INVALID_INPUT');
  if (Object.keys(value).some(key => !names.includes(key))) reject('UNKNOWN_FIELD');
  if (names.some(key => !Object.hasOwn(value, key))) reject('INVALID_INPUT');
  return value;
}
export function strictJson(bytes) {
  try { return parseStrictJson(bytes); }
  catch (error) {
    if (errorCodes.has(error?.code)) reject(error.code);
    reject('INVALID_JSON');
  }
}
function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]));
  }
  return value;
}
export const canonical = value => JSON.stringify(sorted(value));
export const hash = value => createHash('sha256').update(value).digest('hex');
export const contentHash = value => hash(canonical(value));
export function normalizePublicJwk(jwk) {
  exactFields(jwk, ['kty', 'crv', 'x', 'y']);
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256') reject('PROOF_REJECTED');
  for (const name of ['x', 'y']) {
    if (typeof jwk[name] !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(jwk[name])) reject('PROOF_REJECTED');
    try {
      const bytes = base64url.decode(jwk[name]);
      if (bytes.length !== 32 || base64url.encode(bytes) !== jwk[name]) reject('PROOF_REJECTED');
    } catch { reject('PROOF_REJECTED'); }
  }
  const value = Object.freeze({ kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y });
  return Object.freeze({ jwk: value, fingerprint: contentHash(value), keyId: 'key-' + contentHash(value) });
}
export async function validatePublicJwk(jwk) {
  const value = normalizePublicJwk(jwk);
  try { await importJWK(value.jwk, 'ES256'); } catch { reject('PROOF_REJECTED'); }
  return value;
}
export function observation(value) {
  if (!value || !Number.isSafeInteger(value.now) || value.now < 0 ||
      !Number.isSafeInteger(value.uncertaintySeconds) || value.uncertaintySeconds < 0 ||
      value.now < value.uncertaintySeconds ||
      !Number.isSafeInteger(value.now + value.uncertaintySeconds)) reject('CLOCK_UNTRUSTED');
  return Object.freeze({
    now: value.now, uncertaintySeconds: value.uncertaintySeconds,
    earliest: value.now - value.uncertaintySeconds, latest: value.now + value.uncertaintySeconds,
  });
}
export function liveWindow(claims, interval) {
  if (interval.earliest < claims.notBefore) reject('NOT_YET_VALID');
  if (interval.latest >= claims.expiresAt) reject('EXPIRED');
}
export function validateTrust(trust) {
  exactFields(trust, ['issuer', 'audience', 'realm', 'serviceEnvironment', 'trustEpoch',
    'algorithm', 'keyId', 'publicKey']);
  for (const name of ['issuer', 'audience']) {
    if (typeof trust[name] !== 'string' || !/^[!-~]{1,256}$/.test(trust[name])) reject('BINDING_REQUIRED');
  }
  identifier(trust.realm); identifier(trust.serviceEnvironment); identifier(trust.keyId);
  safeInteger(trust.trustEpoch, 1);
  // This executable slice has only the accepted synthetic suite.
  if (trust.algorithm !== 'ES256' || !trust.publicKey) reject('BINDING_REQUIRED');
  return Object.freeze({ ...trust });
}
export function argumentsFor(operation, value) {
  if (operation === 'register') {
    exactFields(value, ['channel', 'installationJwk']);
    identifier(value.channel, 32);
    return Object.freeze({ channel: value.channel, installationJwk: normalizePublicJwk(value.installationJwk).jwk });
  }
  if (operation === 'profile-issue') {
    exactFields(value, ['profileKind', 'recipientJwk', 'ownershipRequest']);
    if (value.profileKind === 'otr' || value.profileKind === 'guest') reject('PROFILE_UNAVAILABLE');
    if (value.profileKind === 'system') reject('PROFILE_UNSUPPORTED');
    if (value.profileKind !== 'normal') reject('INVALID_INPUT');
    identifier(value.ownershipRequest);
    return Object.freeze({
      profileKind: value.profileKind, recipientJwk: normalizePublicJwk(value.recipientJwk).jwk,
      ownershipRequest: value.ownershipRequest,
    });
  }
  reject('NOT_AVAILABLE');
}
export function parseRequest(bytes, challenge = false) {
  const value = strictJson(bytes);
  exactFields(value, challenge
    ? ['version', 'operation', 'idempotencyKey', 'arguments']
    : ['version', 'challengeId', 'nonce', 'idempotencyKey', 'arguments']);
  if (value.version !== 1) reject('UNSUPPORTED_VERSION');
  identifier(value.idempotencyKey);
  if (challenge) {
    if (!['register', 'profile-issue'].includes(value.operation)) reject('NOT_AVAILABLE');
    return Object.freeze({ ...value, arguments: argumentsFor(value.operation, value.arguments) });
  }
  identifier(value.challengeId);
  if (typeof value.nonce !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value.nonce)) reject('INVALID_INPUT');
  return Object.freeze(value);
}
export const requestFingerprint = (operation, args) => contentHash({ version: 1, operation, arguments: args });
export const registrationActor = args =>
  'register:' + args.channel + ':' + normalizePublicJwk(args.installationJwk).fingerprint;
export function peekInstallationToken(input) {
  if (typeof input !== 'string' || Buffer.byteLength(input) > 131_072) reject('UNAUTHORIZED');
  const parts = input.split('.');
  if (parts.length !== 3 || parts.some(part => !/^[A-Za-z0-9_-]+$/.test(part))) reject('UNAUTHORIZED');
  try { return parseUntrusted('installation-credential', base64url.decode(parts[1])); }
  catch { reject('UNAUTHORIZED'); }
}
const proofFields = ['version', 'method', 'target', 'operation', 'issuer', 'audience',
  'realm', 'serviceEnvironment', 'role', 'keyFingerprint', 'recipientFingerprint',
  'parentId', 'parentRevision', 'challengeId', 'nonce', 'requestDigest', 'actor',
  'idempotencyKey', 'issuedAt', 'notBefore', 'expiresAt'];
export async function verifyProof(token, publicJwk, expected, interval) {
  if (typeof token !== 'string' || Buffer.byteLength(token) > 16_384) reject('PROOF_REJECTED');
  const parts = token.split('.');
  if (parts.length !== 3 || parts.some(part => !/^[A-Za-z0-9_-]+$/.test(part))) reject('PROOF_REJECTED');
  const normalized = await validatePublicJwk(publicJwk);
  let header, payload;
  try {
    header = strictJson(base64url.decode(parts[0]));
    exactFields(header, ['alg', 'kid', 'typ']);
    if (header.alg !== 'ES256' || header.kid !== normalized.keyId || header.typ !== 'aegis-b1-pop+jws') reject('PROOF_REJECTED');
    const key = await importJWK(normalized.jwk, 'ES256');
    ({ payload } = await compactVerify(token, key, { algorithms: ['ES256'] }));
  } catch { reject('PROOF_REJECTED'); }
  const claims = strictJson(payload);
  exactFields(claims, proofFields);
  for (const field of proofFields.filter(name => !['issuedAt', 'notBefore', 'expiresAt'].includes(name))) {
    if (claims[field] !== expected[field]) reject('BINDING_MISMATCH');
  }
  safeInteger(claims.issuedAt); safeInteger(claims.notBefore); safeInteger(claims.expiresAt, 1);
  if (claims.issuedAt > claims.notBefore || claims.notBefore >= claims.expiresAt ||
      claims.expiresAt > expected.expiresAt) reject('PROOF_REJECTED');
  liveWindow(claims, interval);
  return Object.freeze({ verified: 'KEY_POSSESSION_ONLY', expiresAt: claims.expiresAt });
}
export function proofContext({ trust, origin, path, operation, challenge, nonce, role }) {
  const key = normalizePublicJwk(role === 'recipient' ? challenge.recipient_jwk : challenge.signer_jwk);
  return Object.freeze({
    version: 1, method: 'POST', target: origin + path, operation,
    issuer: trust.issuer, audience: trust.audience, realm: trust.realm,
    serviceEnvironment: trust.serviceEnvironment, role, keyFingerprint: key.fingerprint,
    recipientFingerprint: challenge.recipient_hash ?? null,
    parentId: challenge.parent_id ?? null, parentRevision: challenge.parent_revision ?? null,
    challengeId: challenge.id, nonce, requestDigest: challenge.request_hash,
    actor: challenge.actor, idempotencyKey: challenge.idem_key, expiresAt: challenge.expires_at,
  });
}
