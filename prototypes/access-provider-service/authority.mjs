import { randomUUID, randomBytes } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { base64url } from 'jose';
import { verifyArtifact, parseUntrusted, RevisionLedger } from '@aegis-local/access-provider-contract';
import {
  ProviderError, reject, identifier, safeInteger, liveWindow,
  validateTrust, validatePublicJwk, normalizePublicJwk, argumentsFor,
  hash, contentHash, requestFingerprint, registrationActor, peekInstallationToken,
  proofContext, verifyProof, strictJson, canonical,
} from './proof.mjs';

export const FIXTURE_MAXIMUMS = Object.freeze({
  installations: 128, profiles: 8, challenges: 4096, operations: 4096,
  revocations: 128, challengeSeconds: 60, installationSeconds: 600,
  profileSeconds: 300, concurrentRequests: 8, requestMilliseconds: 5000,
});
export function validateLimits(value) {
  if (!value || Object.keys(value).length !== Object.keys(FIXTURE_MAXIMUMS).length) reject('BINDING_REQUIRED');
  for (const [name, maximum] of Object.entries(FIXTURE_MAXIMUMS)) {
    if (!Object.hasOwn(value, name)) reject('BINDING_REQUIRED');
    safeInteger(value[name], 1);
    if (value[name] > maximum) reject('BINDING_REQUIRED');
  }
  return Object.freeze({ ...value });
}
// A configured lifetime starts at the issuance lower bound. Uncertainty must
// fit inside that lifetime; it cannot be added to it. Check before signing/writes.
function issuanceExpiry(interval, seconds, parentExpiry = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(interval.earliest) || interval.earliest < 0 ||
      !Number.isSafeInteger(interval.latest) || interval.latest < interval.earliest ||
      !Number.isSafeInteger(seconds) || seconds < 1 ||
      !Number.isSafeInteger(parentExpiry) || parentExpiry < 1) reject('CLOCK_UNTRUSTED');
  const proposed = interval.earliest + seconds;
  if (!Number.isSafeInteger(proposed)) reject('CLOCK_UNTRUSTED');
  const expiresAt = Math.min(proposed, parentExpiry);
  liveWindow({ notBefore: interval.earliest, expiresAt }, interval);
  return expiresAt;
}
function immutable(claims) {
  return contentHash(Object.fromEntries(Object.entries(claims).filter(([name]) =>
    !['revision', 'credentialRevision', 'issuedAt', 'notBefore', 'expiresAt'].includes(name))));
}
function storedCredential(claims, jws, profileId = null, parentId = null) {
  return {
    id: claims.credentialId, kind: claims.kind, installation_id: claims.installationRef,
    pool_id: claims.entitlementAccountId, profile_id: profileId, parent_id: parentId,
    revision: claims.kind === 'profile-credential' ? claims.credentialRevision : claims.revision,
    claims, claims_hash: contentHash(claims), immutable_hash: immutable(claims),
    issued_at: claims.issuedAt, not_before: claims.notBefore, expires_at: claims.expiresAt,
    revoked_at: null, jws,
  };
}
function stableResult(credential) {
  return { status: 201, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
    body: Buffer.from(canonical({ version: 1, mode: 'SYNTHETIC_FIXTURE_ONLY',
      credential: credential.jws, claims: credential.claims })) };
}
function fromOperation(operation) {
  return { status: operation.status, headers: { ...operation.headers }, body: Buffer.from(operation.body) };
}
function checkRecord(record, interval) {
  if (!record || record.revoked_at !== null) reject(record ? 'REVOKED' : 'UNAUTHORIZED');
  const revision = record.claims.kind === 'profile-credential' ? record.claims.credentialRevision : record.claims.revision;
  if (record.revision !== revision || record.claims_hash !== contentHash(record.claims) ||
      record.immutable_hash !== immutable(record.claims) ||
      record.id !== record.claims.credentialId || record.installation_id !== record.claims.installationRef ||
      record.pool_id !== record.claims.entitlementAccountId ||
      record.issued_at !== record.claims.issuedAt || record.not_before !== record.claims.notBefore ||
      record.expires_at !== record.claims.expiresAt) reject('STALE_AUTHORITY');
  liveWindow(record.claims, interval);
}
function checkAuthorization(authorization, interval) {
  if (!authorization) return;
  liveWindow(authorization.challenge, interval);
  for (const window of authorization.proofWindows) liveWindow(window, interval);
}
async function bounded(promise, context) {
  let timer, abort;
  const failure = () => context.signal.reason instanceof ProviderError ? context.signal.reason : new ProviderError('DEADLINE_EXCEEDED');
  try {
    const result = await Promise.race([promise, new Promise((_, fail) => {
      abort = () => fail(failure());
      context.signal.addEventListener('abort', abort, { once: true });
      timer = setTimeout(abort, Math.max(0, context.deadline - performance.now()));
      if (context.signal.aborted || performance.now() >= context.deadline) abort();
    })]);
    if (context.signal.aborted || performance.now() >= context.deadline) throw failure();
    return result;
  } catch (error) { throw error; } finally { clearTimeout(timer); context.signal.removeEventListener('abort', abort); }
}
export class B1Authority {
  #config;
  #origin = null;
  #closed = false;
  constructor(config) { this.#config = authorityConfig(config); }
  bindOrigin(origin) {
    if (this.#closed || this.#origin !== null || !/^http:\/\/127\.0\.0\.1:[0-9]+$/.test(origin)) reject('BINDING_REQUIRED');
    this.#origin = origin;
  }
  async #request(signal, callback) {
    if (this.#closed) reject('SERVER_CLOSED');
    if (!this.#origin) reject('BINDING_REQUIRED');
    const controller = new AbortController();
    const relay = () => controller.abort(signal.reason);
    signal?.addEventListener('abort', relay, { once: true });
    if (signal?.aborted) controller.abort();
    const deadline = Math.min(performance.now() + this.#config.limits.requestMilliseconds,
      signal?.b1Deadline ?? Infinity);
    const timer = setTimeout(() => controller.abort(), this.#config.limits.requestMilliseconds);
    const context = { trust: this.#config.trust, limits: this.#config.limits, deadline, signal: controller.signal };
    try { return await bounded(callback(context), context); }
    finally { clearTimeout(timer); signal?.removeEventListener('abort', relay); }
  }
  async #verifiedWindow(token,key,expected,interval,context) {
    const receipt=await bounded(verifyProof(token,key,Object.freeze({...expected}),interval),context);
    // Decode only the identical primitive token whose exact signature/context passed.
    const claims=strictJson(base64url.decode(token.split('.')[1]));
    safeInteger(claims.notBefore);safeInteger(claims.expiresAt,1);
    if(claims.notBefore>=claims.expiresAt||claims.expiresAt!==receipt.expiresAt)reject('PROOF_REJECTED');
    return Object.freeze({notBefore:claims.notBefore,expiresAt:claims.expiresAt});
  }
  async #time(tx) { return tx.time(() => this.#config.clock.observe()); }
  async #contract(record, root, interval) {
    const trust = this.#config.trust;
    const options = { keys: new Map([[trust.keyId, { algorithm: trust.algorithm, key: trust.publicKey }]]),
      allowedAlgorithms: [trust.algorithm], issuer: trust.issuer, audience: trust.audience,
      realm: trust.realm, serviceEnvironment: trust.serviceEnvironment };
    const revisions = new RevisionLedger();
    try {
      const verify = async (kind, credential, context) => {
        const token = credential.jws, expected = canonical(credential.claims);
        const admitted = await verifyArtifact(kind, token, options, context);
        // Decode only the identical primitive token whose signature passed.
        // Every signed claim must match the persisted authority representation.
        if (canonical(strictJson(base64url.decode(token.split('.')[1]))) !== expected) reject('UNAUTHORIZED');
        return admitted;
      };
      const rootRecord = root?.credential ?? record;
      const installation = await verify('installation-credential', rootRecord, {
        clock: interval, revisions, installationKeyId: rootRecord.claims.installationKeyId,
      });
      if (record.kind === 'installation-credential') return installation;
      return await verify('profile-credential', record, {
        clock: interval, revisions, parents: { installation }, profileKind: 'normal',
        profileBinding: record.claims.profileBinding, recipientKeyId: record.claims.recipientKeyId,
      });
    } catch { reject('UNAUTHORIZED'); }
  }
  async #root(tx, token) {
    const hint = peekInstallationToken(token); // lookup only; no authority from parsed bytes
    const root = await this.#admit(tx, hint.credentialId);
    if (root.parent || root.credential.kind !== 'installation-credential' ||
        token !== root.credential.jws ||
        root.installation.key_id !== root.credential.claims.installationKeyId) reject('UNAUTHORIZED');
    return root;
  }
  async #admit(tx, credentialId, authorization) {
    const chain = await tx.hierarchy(credentialId);
    let interval = await this.#time(tx);
    if (chain.parent) checkRecord(chain.parent, interval);
    checkRecord(chain.credential, interval);
    checkAuthorization(authorization, interval);
    await bounded(this.#contract(chain.credential, chain.parent ? { credential: chain.parent } : null, interval), tx.context);
    // Sample after hierarchy locks and signature verification have completed.
    interval = await this.#time(tx);
    if (chain.parent) checkRecord(chain.parent, interval);
    checkRecord(chain.credential, interval);
    checkAuthorization(authorization, interval);
    return chain;
  }
  async challenge(request, installationToken, signal) {
    return this.#request(signal, async context => {
      const args = argumentsFor(request.operation, request.arguments);
      const key = await bounded(validatePublicJwk(request.operation === 'register'
        ? args.installationJwk : args.recipientJwk), context);
      return this.#config.db.transaction(context, async tx => {
        let interval = await this.#time(tx), root;
        if (request.operation === 'profile-issue') root = await this.#root(tx, installationToken);
        const signer = root ? normalizePublicJwk(root.installation.public_jwk) : key;
        const actor = root ? root.installation.id : registrationActor(args);
        await tx.capacity('challenges', this.#config.limits.challenges);
        interval = await this.#time(tx);
        if (root) checkRecord(root.credential, interval);
        const nonce = base64url.encode(randomBytes(32));
        const row = {
          id: randomUUID(), nonce_hash: hash(nonce), operation: request.operation, actor,
          key_hash: signer.fingerprint, recipient_hash: root ? key.fingerprint : null,
          signer_jwk: signer.jwk, recipient_jwk: root ? key.jwk : null,
          parent_id: root?.credential.id ?? null, parent_revision: root?.credential.revision ?? null,
          idem_key: request.idempotencyKey, request_hash: requestFingerprint(request.operation, args),
          issued_at: interval.earliest, expires_at: issuanceExpiry(interval, this.#config.limits.challengeSeconds),
          consumed_operation_id: null, consumed_at: null,
        };
        await tx.insertChallenge(row);
        interval = await this.#time(tx);
        if (root) checkRecord(root.credential, interval);
        liveWindow({ notBefore: row.issued_at, expiresAt: row.expires_at }, interval);
        return { status: 200, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
          body: Buffer.from(canonical({ version: 1, challengeId: row.id, nonce, actor,
            operation: row.operation, requestDigest: row.request_hash,
            keyFingerprint: row.key_hash, recipientFingerprint: row.recipient_hash,
            parentId: row.parent_id, parentRevision: row.parent_revision,
            issuedAt: row.issued_at, expiresAt: row.expires_at })) };
      });
    });
  }
  async issue(operation, request, headers, signal) {
    return this.#request(signal, async context => {
      const proof=headers.proof,recipientProof=headers.recipientProof,installationToken=headers.installationToken;
      const args = argumentsFor(operation, request.arguments);
      const key = await bounded(validatePublicJwk(operation === 'register' ? args.installationJwk : args.recipientJwk), context);
      // Check actual cryptography against a non-authorizing DB snapshot before
      // holding write locks. Every binding and proof is checked again below.
      const preview = await bounded(this.#config.db.proofBinding(request.challengeId,context),context);
      const preContext = role => proofContext({trust:this.#config.trust,origin:this.#origin,
        path:operation==='register'?'/bootstrap/register':'/profile-credentials',operation,
        challenge:preview,nonce:request.nonce,role});
      const preTime=await bounded(this.#config.db.observeTime(context,()=>this.#config.clock.observe()),context);
      await bounded(verifyProof(proof,preview.signer_jwk,preContext('installation'),preTime),context);
      if(operation==='profile-issue')await bounded(verifyProof(recipientProof,preview.recipient_jwk,preContext('recipient'),preTime),context);
      const result = await this.#config.db.transaction(context, async tx => {
        const local = tx.context;
        let interval = await this.#time(tx), root;
        if (operation === 'profile-issue') root = await this.#root(tx, installationToken);
        // Lock the existing installation/pool before challenge/operation rows.
        let existing;
        if (operation === 'register') existing = await tx.installationByKey(args.channel, key.fingerprint);
        let owner, profile;
        if (root) {
          if (key.fingerprint === root.installation.key_hash) reject('BINDING_MISMATCH');
          owner = await bounded(this.#config.ownership.verify({
            installationId: root.installation.id, request: args.ownershipRequest,
            recipientFingerprint: key.fingerprint, signal: local.signal,
          }), local);
          if (!owner || owner.installationId !== root.installation.id ||
              owner.profileKind !== 'normal' || typeof owner.subject !== 'string' ||
              !owner.subject || owner.subject.length > 128 || owner.verified !== undefined) reject('OWNERSHIP_REQUIRED');
          profile = await tx.profileByOwner(root.installation.id, hash(owner.subject));
          if (profile && profile.profile.key_hash !== key.fingerprint) reject('BINDING_MISMATCH');
        }
        const ch = await tx.challenge(request.challengeId);
        const actor = root ? root.installation.id : registrationActor(args);
        if (ch.actor !== actor || ch.operation !== operation || ch.idem_key !== request.idempotencyKey ||
            ch.nonce_hash !== hash(request.nonce) || ch.key_hash !== (root ? root.installation.key_hash : key.fingerprint) ||
            ch.recipient_hash !== (root ? key.fingerprint : null) ||
            ch.parent_id !== (root?.credential.id ?? null) ||
            ch.parent_revision !== (root?.credential.revision ?? null)) reject('BINDING_MISMATCH');
        if (ch.request_hash !== requestFingerprint(operation, args)) reject('IDEMPOTENCY_CONFLICT');
        const op = await tx.operation(actor, operation, request.idempotencyKey);
        if (op && op.request_hash !== ch.request_hash) reject('IDEMPOTENCY_CONFLICT');
        if (ch.consumed_operation_id !== null && (!op || ch.consumed_operation_id !== op.id)) reject('CHALLENGE_CONSUMED');
        interval = await this.#time(tx);
        liveWindow({ notBefore: ch.issued_at, expiresAt: ch.expires_at }, interval);
        const expected = role => proofContext({ trust: this.#config.trust, origin: this.#origin,
          path: operation === 'register' ? '/bootstrap/register' : '/profile-credentials',
          operation, challenge: ch, nonce: request.nonce, role });
        const installationProof = await this.#verifiedWindow(proof,ch.signer_jwk,expected('installation'),interval,local);
        const proofWindows = [installationProof];
        if (root) {
          const recipientWindow = await this.#verifiedWindow(recipientProof,ch.recipient_jwk,expected('recipient'),interval,local);
          proofWindows.push(recipientWindow);
        }
        const authorization = Object.freeze({ challenge: Object.freeze({ notBefore: ch.issued_at, expiresAt: ch.expires_at }), proofWindows:Object.freeze(proofWindows) });
        if (op) {
          await this.#admit(tx, op.result_credential_id, authorization);
          if (ch.consumed_operation_id === null) await tx.consumeChallenge(ch.id, op.id, (await this.#time(tx)).latest);
          await this.#admit(tx, op.result_credential_id, authorization);
          return { response: fromOperation(op), credentialId: op.result_credential_id, authorization };
        }
        await tx.capacity('operations', this.#config.limits.operations);
        let credential;
        interval = await this.#time(tx);
        if (existing) {
          if (existing.installation.registration_digest !== requestFingerprint(operation, args)) reject('IDEMPOTENCY_CONFLICT');
          checkRecord(existing.credential, interval);
          await bounded(this.#contract(existing.credential, null, interval), local);
          credential = existing.credential;
        } else if (profile) {
          checkRecord(root.credential, interval); checkRecord(profile.credential, interval);
          await bounded(this.#contract(profile.credential, root, interval), local);
          credential = profile.credential;
        } else {
          const trust = this.#config.trust;
          const common = { version: 1, issuer: trust.issuer, audience: trust.audience,
            realm: trust.realm, serviceEnvironment: trust.serviceEnvironment,
            issuedAt: interval.earliest, notBefore: interval.earliest };
          let claims, profileId, parentId;
          if (root) {
            checkRecord(root.credential, interval);
            await tx.capacity('profiles', this.#config.limits.profiles, root.installation.id);
            const expiresAt = issuanceExpiry(interval, this.#config.limits.profileSeconds, root.credential.expires_at);
            profileId = randomUUID(); parentId = root.credential.id;
            const p = { id: profileId, installation_id: root.installation.id, pool_id: root.pool.id,
              ownership_hash: hash(owner.subject), profile_binding: randomUUID(),
              key_id: key.keyId, key_hash: key.fingerprint, public_jwk: key.jwk };
            await tx.insertProfile(p);
            claims = { ...common, kind: 'profile-credential',
              expiresAt,
              scope: ['directory:read', 'lease:issue', 'usage:read'],
              installationRef: root.installation.id, principalId: profileId,
              entitlementAccountId: root.pool.id, credentialId: randomUUID(), credentialRevision: 1,
              profileBinding: p.profile_binding, recipientKeyId: key.keyId,
              parentCredentialId: parentId, identityKind: 'installation_guest', profileKind: 'normal' };
          } else {
            await tx.capacity('installations', this.#config.limits.installations);
            const expiresAt = issuanceExpiry(interval, this.#config.limits.installationSeconds);
            const installationId = randomUUID(), poolId = randomUUID();
            await tx.insertInstallation({ id: installationId, channel: args.channel,
              key_id: key.keyId, key_hash: key.fingerprint, public_jwk: key.jwk,
              registration_digest: requestFingerprint(operation, args) });
            await tx.insertPool({ id: poolId, installation_id: installationId });
            claims = { ...common, kind: 'installation-credential',
              expiresAt,
              scope: ['profile:issue'], credentialId: randomUUID(), installationRef: installationId,
              installationKeyId: key.keyId, entitlementAccountId: poolId, revision: 1 };
          }
          parseUntrusted(claims.kind, canonical(claims));
          // Keep the expected payload private across the injected signer await.
          // A signer may mutate its argument, but cannot redefine our authority.
          const expectedClaims = canonical(claims);
          const jws = await bounded(this.#config.signer.sign(JSON.parse(expectedClaims), { signal: local.signal }), local);
          credential = storedCredential(JSON.parse(expectedClaims), jws, profileId, parentId);
          interval = await this.#time(tx);
          checkAuthorization(authorization, interval);
          await bounded(this.#contract(credential, root, interval), local);
          interval = await this.#time(tx);
          checkAuthorization(authorization, interval);
          if (root) checkRecord(root.credential, interval);
          checkRecord(credential, interval);
          await tx.insertCredential(credential);
        }
        interval = await this.#time(tx);
        checkAuthorization(authorization, interval);
        checkRecord(credential, interval);
        const response = stableResult(credential);
        const operationId = randomUUID();
        await tx.insertOperation({ id: operationId, actor, operation, idem_key: request.idempotencyKey,
          request_hash: ch.request_hash, result_credential_id: credential.id,
          ...response, result_deadline: credential.expires_at, created_at: interval.latest });
        await tx.consumeChallenge(ch.id, operationId, interval.latest);
        await this.#admit(tx, credential.id, authorization);
        return { response, credentialId: credential.id, authorization };
      });
      // Separate, locked admission before response; no locks held during network writes.
      await this.#config.db.transaction(context, async tx => {
        await this.#admit(tx, result.credentialId, result.authorization);
      });
      return result.response;
    });
  }
  async revokeInstallation({ installationId, capability, signal }) {
    identifier(installationId);
    return this.#request(signal, async context => {
      const administrator = await bounded(this.#config.administration.verify(capability, { signal: context.signal }), context);
      if (!administrator || typeof administrator.subject !== 'string') reject('UNAUTHORIZED');
      identifier(administrator.subject);
      return this.#config.db.transaction(context, async tx => {
        const root = await tx.installationById(installationId);
        if (!root) reject('UNAUTHORIZED');
        const at = (await this.#time(tx)).latest;
        const op = await tx.operation(administrator.subject, 'revoke', installationId);
        if (op) return fromOperation(op);
        await tx.capacity('revocations', this.#config.limits.revocations);
        if (root.credential.revoked_at === null) await tx.revoke(root.credential.id, at);
        const response = { status: 200, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
          body: Buffer.from(canonical({ version: 1, status: 'LOCAL_FIXTURE_REVOCATION_RECEIPT',
            installationRef: installationId, revocationSequence: tx.domain.revocation_seq })) };
        await tx.insertOperation({ id: randomUUID(), actor: administrator.subject, operation: 'revoke',
          idem_key: installationId, request_hash: contentHash({ installationId }),
          ...response, result_credential_id: null, result_deadline: null, created_at: at });
        return response;
      });
    });
  }
  async close() { this.#closed = true; await this.#config.db.close(); }
}
export function authorityConfig(config) {
  if (!config || config.mode !== 'fixture') reject('PRODUCTION_BINDINGS_UNAVAILABLE');
  if (!config.db || !['postgresql', 'synthetic-test-double'].includes(config.db.kind) ||
      typeof config.db.transaction !== 'function' || typeof config.db.close !== 'function' ||
      typeof config.db.proofBinding !== 'function' || typeof config.db.observeTime !== 'function' ||
      !config.clock || typeof config.clock.observe !== 'function' ||
      !config.ownership || typeof config.ownership.verify !== 'function' ||
      !config.administration || typeof config.administration.verify !== 'function' ||
      !config.signer || typeof config.signer.sign !== 'function') reject('BINDING_REQUIRED');
  const trust = validateTrust(config.trust);
  if (config.signer.keyId !== trust.keyId || config.signer.algorithm !== trust.algorithm) reject('BINDING_REQUIRED');
  return Object.freeze({ ...config, trust, limits: validateLimits(config.limits) });
}
