// CONTRACT_MODEL_ONLY: executable request-routing oracle, never a Chromium adapter.
const generationFields = [
  'policy_generation', 'identity_generation', 'selection_generation',
  'network_epoch', 'base_proxy_config_generation',
];
const commonFields = generationFields.filter((field) => field !== 'selection_generation');
const supportedSchemes = new Set(['http', 'https', 'ws', 'wss']);
const supportedModes = new Set(['DIRECT', 'PROXY', 'REJECT']);

const fail = (reason) => Object.freeze({ ok: false, reason });
const ownerKey = (owner) => JSON.stringify([
  owner?.channel, owner?.profile_token, owner?.storage_partition_token,
]);
const validOwner = (owner) =>
  ['dev', 'alpha', 'beta', 'release'].includes(owner?.channel) &&
  typeof owner?.profile_token === 'string' && owner.profile_token.length > 0 &&
  typeof owner?.storage_partition_token === 'string' && owner.storage_partition_token.length > 0;
const validGeneration = (value) => Number.isSafeInteger(value) && value > 0;
const validTuple = (tuple) => generationFields.every((field) => validGeneration(tuple?.[field]));
const sameFields = (left, right, fields) => fields.every((field) => left[field] === right[field]);
const copy = (value) => structuredClone(value);
const tupleKey = (tuple) => generationFields.map((field) => tuple[field]);

function parseTarget(target) {
  if (typeof target !== 'string') return null;
  try {
    const url = new URL(target);
    const scheme = url.protocol.slice(0, -1);
    if (!supportedSchemes.has(scheme) || !url.hostname) return null;
    const port = url.port ? Number(url.port) : (scheme === 'http' || scheme === 'ws' ? 80 : 443);
    return Object.freeze({ scheme, host: url.hostname.toLowerCase(), port });
  } catch {
    return null;
  }
}

function canonicalSite(site) {
  try {
    const url = new URL(site);
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    return `${url.protocol}//${url.hostname}`;
  } catch {
    return null;
  }
}

function isCanonicalConfigSite(site) {
  const canonical = canonicalSite(site);
  return canonical === site && !new URL(site).hostname.endsWith('.');
}

function canonicalExactHost(host) {
  try {
    const url = new URL(`https://${host}/`);
    return url.port ? null : url.hostname;
  } catch {
    return null;
  }
}

function validRule(rule) {
  return typeof rule?.id === 'string' && rule.id.length > 0 &&
    ['site', 'profile'].includes(rule.scope) &&
    (rule.scope === 'profile' ? rule.topLevelSite === undefined :
      (typeof rule.topLevelSite === 'string' && rule.topLevelSite.length > 0 &&
        isCanonicalConfigSite(rule.topLevelSite))) &&
    typeof rule.exactHost === 'string' && rule.exactHost.length > 0 &&
    !rule.exactHost.endsWith('.') &&
    canonicalExactHost(rule.exactHost) === rule.exactHost &&
    supportedSchemes.has(rule.scheme) &&
    Number.isInteger(rule.port) && rule.port > 0 && rule.port <= 65535 &&
    supportedModes.has(rule.mode) &&
    (rule.mode !== 'PROXY' || (typeof rule.groupId === 'string' && rule.groupId.length > 0)) &&
    (rule.mode === 'PROXY' || rule.groupId === undefined);
}

function ruleKey(rule) {
  return JSON.stringify([rule.scope, rule.topLevelSite ?? null, rule.exactHost,
    rule.scheme, rule.port]);
}

export class RequestRoutingContractModel {
  #owners = new Map();
  #seenIncarnations = new Map();
  #usedRegistrationIds = new Map();
  #sentHops = new Map();
  #lastCommittedRules = new Map();
  #issuers = new WeakMap();
  #credentialHandles = new WeakMap();
  #issued = new WeakMap();
  #decisions = new WeakMap();
  #nextSnapshotId = 1;
  #now = 0;

  advanceClock(now) {
    if (!Number.isFinite(now) || now < this.#now) return fail('invalid_clock_advance');
    this.#now = now;
    return Object.freeze({ ok: true, now });
  }

  #liveRegistration(entry) {
    return this.#now < entry.expiresAt && this.#now < entry.connectionDeadline;
  }

  #credentialBound(entry, key) {
    if (!entry) return false;
    const credential = this.#credentialHandles.get(entry.credentialHandle);
    return credential?.key === key && credential.incarnation === entry.incarnation &&
      credential.group === entry.group && credential.registrationId === entry.registrationId &&
      credential.transport === entry.endpointIdentity.transport &&
      credential.listenerIncarnation === entry.endpointIdentity.listenerIncarnation;
  }

  restart(owner, newIncarnation) {
    if (!validOwner(owner) || typeof newIncarnation !== 'string' || !newIncarnation) {
      return fail('invalid_owner_or_incarnation');
    }
    const key = ownerKey(owner);
    const seen = this.#seenIncarnations.get(key) ?? new Set();
    if (seen.has(newIncarnation)) return fail('incarnation_not_advanced');
    seen.add(newIncarnation);
    this.#seenIncarnations.set(key, seen);
    const prior = this.#owners.get(key);
    const restoringPublishedSnapshot = prior?.active ? true :
      (prior?.restoringPublishedSnapshot ?? this.#lastCommittedRules.has(key));
    const restoreRules = prior?.active?.rules ?? prior?.restoreRules ??
      this.#lastCommittedRules.get(key) ?? [];
    const pendingBlocks = [
      ...(prior?.pendingBlocks ?? []),
      ...(prior?.pending?.rules.filter((rule) => rule.mode === 'REJECT') ?? []),
    ];
    const usedRegistrationIds = this.#usedRegistrationIds.get(key) ?? new Set();
    const sentHops = this.#sentHops.get(key) ?? new Set();
    this.#usedRegistrationIds.set(key, usedRegistrationIds);
    this.#sentHops.set(key, sentHops);
    this.#owners.set(key, {
      owner: copy(owner), incarnation: newIncarnation, registrations: new Map(),
      pending: null, active: null, sentHops, usedRegistrationIds,
      restoreRules: Object.freeze([...restoreRules]),
      pendingBlocks: Object.freeze([...pendingBlocks]),
      restoringPublishedSnapshot,
    });
    return Object.freeze({ ok: true, incarnation: newIncarnation });
  }

  trustedIssuer(owner) {
    if (!validOwner(owner)) return fail('invalid_owner');
    const state = this.#owners.get(ownerKey(owner));
    if (!state) return fail('owner_not_live');
    const token = Object.freeze({});
    this.#issuers.set(token, { key: ownerKey(owner), incarnation: state.incarnation });
    return token;
  }

  issueCredentialHandle({ issuer, owner, group, registrationId, transport,
    listenerIncarnation, credentialIdentity }) {
    const authority = this.#issuers.get(issuer);
    const key = ownerKey(owner);
    const state = this.#owners.get(key);
    if (!validOwner(owner) || !authority || authority.key !== key || !state ||
        authority.incarnation !== state.incarnation ||
        typeof group !== 'string' || !group ||
        typeof registrationId !== 'string' || !registrationId ||
        !['http', 'socks5'].includes(transport) ||
        typeof listenerIncarnation !== 'string' || !listenerIncarnation ||
        typeof credentialIdentity !== 'string' || !credentialIdentity) {
      return fail('invalid_credential_issuer_or_binding');
    }
    const handle = Object.freeze({});
    this.#credentialHandles.set(handle, Object.freeze({
      key, incarnation: state.incarnation, group, registrationId, transport,
      listenerIncarnation, credentialIdentity,
    }));
    return handle;
  }

  close(owner) {
    if (!validOwner(owner)) return fail('invalid_owner');
    return Object.freeze({ ok: this.#owners.delete(ownerKey(owner)) });
  }

  registerEndpoint({ owner, group, registrationId, endpointIdentity, tuple, incarnation,
    credentialHandle, expiresAt, connectionDeadline }) {
    const state = this.#owners.get(ownerKey(owner));
    if (!validOwner(owner) || !state || state.incarnation !== incarnation) return fail('stale_incarnation');
    const credential = this.#credentialHandles.get(credentialHandle);
    if (!validTuple(tuple) || typeof group !== 'string' || !group ||
        typeof registrationId !== 'string' || !registrationId ||
        !['http', 'socks5'].includes(endpointIdentity?.transport) ||
        endpointIdentity?.host !== '127.0.0.1' ||
        !Number.isInteger(endpointIdentity?.port) || endpointIdentity.port < 1 ||
        endpointIdentity.port > 65535 || endpointIdentity.credentialIdentity !== undefined ||
        typeof endpointIdentity?.listenerIncarnation !== 'string' ||
        !endpointIdentity.listenerIncarnation ||
        !credential || credential.key !== ownerKey(owner) ||
        credential.incarnation !== incarnation || credential.group !== group ||
        credential.registrationId !== registrationId ||
        credential.transport !== endpointIdentity.transport ||
        credential.listenerIncarnation !== endpointIdentity.listenerIncarnation ||
        !Number.isFinite(expiresAt) || !Number.isFinite(connectionDeadline) ||
        !(this.#now < expiresAt && expiresAt <= connectionDeadline)) {
      return fail('invalid_registration');
    }
    if (state.usedRegistrationIds.has(registrationId)) return fail('registration_id_reused');
    state.registrations.set(registrationId, Object.freeze({
      group, registrationId, endpointIdentity: Object.freeze(copy(endpointIdentity)),
      tuple: Object.freeze(copy(tuple)), incarnation, credentialHandle,
      expiresAt, connectionDeadline,
    }));
    state.usedRegistrationIds.add(registrationId);
    return Object.freeze({ ok: true, registrationId });
  }

  unregisterEndpoint(owner, registrationId) {
    const state = this.#owners.get(ownerKey(owner));
    return Boolean(state?.registrations.delete(registrationId));
  }

  publishSnapshot({ owner, commonGenerations, incarnation, rules, endpoints }) {
    const state = this.#owners.get(ownerKey(owner));
    if (!validOwner(owner) || !state || state.incarnation !== incarnation) return fail('stale_incarnation');
    if (!commonFields.every((field) => validGeneration(commonGenerations?.[field])) ||
        !Array.isArray(rules) || !Array.isArray(endpoints)) return fail('incomplete_snapshot');
    const groupMap = new Map();
    for (const binding of endpoints) {
      const entry = state.registrations.get(binding?.registrationId);
      if (typeof binding?.groupId !== 'string' || !binding.groupId ||
          typeof binding?.registrationId !== 'string' || !binding.registrationId ||
          groupMap.has(binding.groupId) || !entry ||
          entry.group !== binding.groupId || entry.incarnation !== incarnation ||
          !this.#liveRegistration(entry) || !this.#credentialBound(entry, ownerKey(owner)) ||
          !sameFields(entry.tuple, commonGenerations, commonFields)) {
        return fail('missing_or_stale_registration');
      }
      groupMap.set(binding.groupId, entry);
    }
    const keys = new Set();
    for (const rule of rules) {
      if (!validRule(rule) || keys.has(ruleKey(rule))) return fail('invalid_or_conflicting_rule');
      keys.add(ruleKey(rule));
      if (rule.mode === 'PROXY' && !groupMap.has(rule.groupId)) return fail('missing_group');
    }
    // No observable state changes before every group and rule validates.
    const receipt = Object.freeze({
      snapshotId: this.#nextSnapshotId++, ownerKey: ownerKey(owner), incarnation,
      groupSet: Object.freeze([...groupMap.keys()].sort()),
    });
    state.pending = {
      receipt, commonGenerations: Object.freeze(copy(commonGenerations)),
      rules: Object.freeze(copy(rules).map((rule) => Object.freeze(rule))),
      groups: groupMap,
    };
    return Object.freeze({ ok: true, receipt });
  }

  acknowledgeModelSnapshot(receipt) {
    const state = this.#owners.get(receipt?.ownerKey);
    if (!state || state.incarnation !== receipt?.incarnation || state.pending?.receipt !== receipt) {
      return fail('stale_or_forged_model_ack');
    }
    for (const [group, entry] of state.pending.groups) {
      if (state.registrations.get(entry.registrationId) !== entry || entry.group !== group ||
          !this.#liveRegistration(entry) || !this.#credentialBound(entry, receipt.ownerKey)) {
        return fail('registration_lost_before_model_ack');
      }
    }
    state.active = state.pending;
    state.pending = null;
    this.#lastCommittedRules.set(receipt.ownerKey, state.active.rules);
    state.restoreRules = Object.freeze([]);
    state.pendingBlocks = Object.freeze([]);
    state.restoringPublishedSnapshot = false;
    return Object.freeze({ ok: true, snapshotId: receipt.snapshotId });
  }

  issueRequest({ issuer, attribution, target, method, requestId, hop = 0, requireProxy = false }) {
    const authority = this.#issuers.get(issuer);
    const key = authority?.key;
    const state = this.#owners.get(key);
    const parsed = parseTarget(target);
    if (!key || !state || authority.incarnation !== state.incarnation) {
      return fail('untrusted_or_unknown_issuer');
    }
    if (!parsed || !/^[A-Z]+$/.test(method ?? '') ||
        typeof requestId !== 'string' || !requestId ||
        !Number.isSafeInteger(hop) || hop < 0 ||
        !['site', 'opaque'].includes(attribution?.kind) ||
        (attribution.kind === 'site' && !attribution.topLevelSite)) {
      return fail('invalid_request');
    }
    const site = attribution.kind === 'site' ? canonicalSite(attribution.topLevelSite) : null;
    if (attribution.kind === 'site' && !site) return fail('invalid_request');
    const issuedAttribution = attribution.kind === 'site'
      ? { ...attribution, topLevelSite: site } : attribution;
    const issued = Object.freeze({
      requestId, hop, method, target: parsed, attribution: Object.freeze(copy(issuedAttribution)),
      requireProxy: Boolean(requireProxy), owner: Object.freeze(copy(state.owner)),
      incarnation: state.incarnation,
    });
    this.#issued.set(issued, { key, issuer });
    return issued;
  }

  nextHop(issued, { target, method, navigation = 'subresource', nextTopLevelSite }) {
    const source = this.#issued.get(issued);
    if (!source) return fail('unissued_request');
    const state = this.#owners.get(source.key);
    if (!state || state.incarnation !== issued.incarnation) return fail('stale_incarnation');
    if (!state.sentHops.has(JSON.stringify([issued.requestId, issued.hop]))) {
      return fail('redirect_source_not_sent');
    }
    if (!['subresource', 'main'].includes(navigation) ||
        (navigation === 'main' && !nextTopLevelSite)) return fail('missing_redirect_attribution');
    const attribution = navigation === 'main'
      ? { kind: 'site', topLevelSite: nextTopLevelSite }
      : issued.attribution;
    return this.issueRequest({
      issuer: source.issuer, attribution, target, method: method ?? issued.method,
      requestId: issued.requestId, hop: issued.hop + 1, requireProxy: issued.requireProxy,
    });
  }

  evaluate(issued) {
    const source = this.#issued.get(issued);
    if (!source) return fail('unissued_request');
    const state = this.#owners.get(source.key);
    if (!state || state.incarnation !== issued.incarnation) return fail('stale_incarnation');
    const snapshot = state.active;
    let action = 'native';
    let reason = 'PRESERVE_NATIVE';
    let group = null;
    let entry = null;
    const noncanonicalRequest = issued.target.host.endsWith('.') ||
      (issued.attribution.kind === 'site' &&
        new URL(issued.attribution.topLevelSite).hostname.endsWith('.'));
    if (noncanonicalRequest && (snapshot || state.restoringPublishedSnapshot ||
        state.pendingBlocks.length > 0)) {
      action = 'wait-fail';
      reason = 'noncanonical_request';
    } else if (!snapshot) {
      const targetRules = state.restoreRules.filter((rule) =>
        rule.exactHost === issued.target.host &&
        rule.scheme === issued.target.scheme && rule.port === issued.target.port);
      const matching = targetRules.filter((rule) => rule.scope === 'profile' ||
        (issued.attribution.kind === 'site' &&
          rule.topLevelSite === issued.attribution.topLevelSite));
      const rule = matching.find((candidate) => candidate.scope === 'site') ?? matching[0];
      const ambiguousSiteConstraint = issued.attribution.kind === 'opaque' &&
        targetRules.some((candidate) => candidate.scope === 'site' &&
          candidate.mode !== 'DIRECT');
      const pendingBlock = state.pendingBlocks.some((candidate) =>
        candidate.exactHost === issued.target.host &&
        candidate.scheme === issued.target.scheme && candidate.port === issued.target.port &&
        (candidate.scope === 'profile' || issued.attribution.kind === 'opaque' ||
          candidate.topLevelSite === issued.attribution.topLevelSite));
      const wasConstrained = pendingBlock || ambiguousSiteConstraint ||
        (rule && rule.mode !== 'DIRECT');
      if (issued.requireProxy || wasConstrained) {
        action = 'wait-fail';
        reason = wasConstrained ? 'restoring_constrained_route' : 'required_snapshot_missing';
      }
      else reason = 'no_access_snapshot';
    } else {
      const matching = snapshot.rules.filter((rule) =>
        rule.exactHost.toLowerCase() === issued.target.host &&
        rule.scheme === issued.target.scheme && rule.port === issued.target.port &&
        (rule.scope === 'profile' ||
          (issued.attribution.kind === 'site' && rule.topLevelSite === issued.attribution.topLevelSite)));
      const rule = matching.find((candidate) => candidate.scope === 'site') ?? matching[0];
      if (rule?.mode === 'REJECT') { action = 'reject'; reason = 'REJECT'; }
      else if (rule?.mode === 'PROXY') {
        group = rule.groupId;
        entry = snapshot.groups.get(group);
        if (!entry || state.registrations.get(entry.registrationId) !== entry ||
            !this.#credentialBound(entry, source.key)) {
          action = 'wait-fail'; reason = 'registration_unavailable';
        } else if (!this.#liveRegistration(entry)) {
          action = 'wait-fail'; reason = 'registration_expired';
        } else { action = 'proxy'; reason = 'PROXY'; }
      } else if (rule?.mode === 'DIRECT') reason = 'DIRECT';
      else if (issued.requireProxy) { action = 'wait-fail'; reason = 'required_route_missing'; }
    }
    const decision = Object.freeze({
      ok: true, action, reason, requestId: issued.requestId, hop: issued.hop,
      owner: issued.owner, incarnation: issued.incarnation,
      snapshotId: snapshot?.receipt.snapshotId ?? null,
      nativeProxyConfigGeneration: snapshot?.commonGenerations.base_proxy_config_generation ?? null,
      groupId: action === 'proxy' ? group : null,
      registrationId: action === 'proxy' ? entry.registrationId : null,
      credentialHandle: action === 'proxy' ? entry.credentialHandle : null,
      tuple: action === 'proxy' ? entry.tuple : null,
      reuseKey: action === 'proxy' ? JSON.stringify([
        source.key, group, entry.registrationId, entry.endpointIdentity.listenerIncarnation,
        ...tupleKey(entry.tuple), state.incarnation,
      ]) : null,
    });
    this.#decisions.set(decision, { source, issued, snapshot, entry, sent: false });
    return decision;
  }

  dispatch(decision) {
    const record = this.#decisions.get(decision);
    if (!record) return fail('forged_decision');
    const state = this.#owners.get(record.source.key);
    if (!state || state.incarnation !== decision.incarnation || state.active !== record.snapshot) {
      return fail('stale_decision');
    }
    const hopKey = JSON.stringify([decision.requestId, decision.hop]);
    if (record.sent || state.sentHops.has(hopKey)) return fail('already_sent');
    if (decision.action === 'reject') return fail('locally_rejected');
    if (decision.action === 'wait-fail') return fail(decision.reason);
    if (decision.action === 'proxy') {
      if (state.registrations.get(record.entry.registrationId) !== record.entry) {
        return fail('registration_unavailable');
      }
      if (!this.#credentialBound(record.entry, record.source.key)) {
        return fail('credential_binding_denied');
      }
      if (!this.#liveRegistration(record.entry)) return fail('registration_expired');
    }
    record.sent = true;
    state.sentHops.add(hopKey);
    return Object.freeze({ ok: true, action: decision.action, requestId: decision.requestId,
      hop: decision.hop, registrationId: decision.registrationId });
  }

  authorizeCredentialLookup(decision, { owner, registrationId, transport, credentialHandle }) {
    const record = this.#decisions.get(decision);
    const state = this.#owners.get(ownerKey(owner));
    if (!record || decision.action !== 'proxy' || !record.entry || !state ||
        record.source.key !== ownerKey(owner) || state.active !== record.snapshot ||
        state.incarnation !== decision.incarnation ||
        registrationId !== decision.registrationId ||
        credentialHandle !== record.entry?.credentialHandle ||
        state.registrations.get(registrationId) !== record.entry ||
        transport !== record.entry.endpointIdentity.transport ||
        !this.#credentialBound(record.entry, record.source.key) ||
        !this.#liveRegistration(record.entry)) return fail('credential_binding_denied');
    const credential = this.#credentialHandles.get(record.entry.credentialHandle);
    if (!credential || credential.key !== record.source.key ||
        credential.incarnation !== decision.incarnation ||
        credential.group !== decision.groupId ||
        credential.registrationId !== registrationId ||
        credential.transport !== transport ||
        credential.listenerIncarnation !== record.entry.endpointIdentity.listenerIncarnation) {
      return fail('credential_binding_denied');
    }
    return Object.freeze({ ok: true, credentialIdentity: credential.credentialIdentity });
  }
}
