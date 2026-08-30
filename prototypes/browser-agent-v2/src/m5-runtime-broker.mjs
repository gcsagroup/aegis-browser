import crypto from 'node:crypto';

const FINAL_TRANSACTION = /(?:最终下单|立即购买|确认支付|submit\s+order|place\s+order|purchase|pay\s+now)/iu;
const REDIRECT_ACTION = /(?:外部重定向|重定向|redirect)/iu;
const DOWNLOAD_ACTION = /(?:下载|download)/iu;
const HANDOFF_ACTION = /(?:用户接管|人工接管|handoff)/iu;
const SAFE_INTERACTION_METHODS = new Set(['click']);

function canonical(value) {
  return JSON.stringify(value, Object.keys(value).sort());
}

export function observationToken(actions) {
  return crypto.createHash('sha256').update(JSON.stringify(actions)).digest('hex');
}

function sameBinding(left, right) {
  return Boolean(left && right && canonical(left) === canonical(right));
}

function validBinding(binding) {
  return binding
    && typeof binding.profileId === 'string' && binding.profileId
    && typeof binding.taskId === 'string' && binding.taskId
    && typeof binding.tabId === 'string' && binding.tabId
    && typeof binding.frameToken === 'string' && binding.frameToken
    && typeof binding.documentToken === 'string' && binding.documentToken
    && typeof binding.observationToken === 'string' && binding.observationToken
    && typeof binding.url === 'string' && binding.url;
}

export class M5RuntimeBroker {
  constructor({ profileId, taskId, allowedOrigins, maxTabs = 4, maxActions = 16 }) {
    if (!profileId || !taskId) throw new Error('Runtime 需要 profileId 和 taskId');
    this.profileId = profileId;
    this.taskId = taskId;
    this.allowedOrigins = new Set(allowedOrigins);
    this.maxTabs = maxTabs;
    this.maxActions = maxActions;
    this.ownedTabs = new Set();
    this.documents = new Map();
    this.consumedActionIds = new Set();
    this.actionCount = 0;
    this.stopped = false;
  }

  allowsUrl(rawUrl) {
    if (rawUrl === 'about:blank') return true;
    try {
      const url = new URL(rawUrl);
      return !url.username
        && !url.password
        && url.protocol === 'https:'
        && this.allowedOrigins.has(url.origin);
    } catch {
      return false;
    }
  }

  adoptOwnedTab(tabId) {
    if (this.stopped || !tabId || this.ownedTabs.has(tabId) || this.ownedTabs.size >= this.maxTabs) {
      return false;
    }
    this.ownedTabs.add(tabId);
    return true;
  }

  commitDocument(binding) {
    if (this.stopped || !validBinding(binding)
      || binding.profileId !== this.profileId
      || binding.taskId !== this.taskId
      || !this.ownedTabs.has(binding.tabId)
      || !this.allowsUrl(binding.url)) {
      return false;
    }
    this.documents.set(binding.tabId, structuredClone(binding));
    return true;
  }

  authorize({
    actionId, tool, binding, destination = null, actionIndex = null,
    observedActions = [], completionVerified = false,
  }) {
    if (this.stopped) return { allowed: false, reason: 'stopped' };
    if (!actionId || this.consumedActionIds.has(actionId)) {
      return { allowed: false, reason: 'duplicate-action' };
    }
    if (this.actionCount >= this.maxActions) return { allowed: false, reason: 'action-budget' };
    if (!validBinding(binding)
      || binding.profileId !== this.profileId
      || binding.taskId !== this.taskId
      || !this.ownedTabs.has(binding.tabId)) {
      return { allowed: false, reason: 'scope-violation' };
    }
    if (!sameBinding(this.documents.get(binding.tabId), binding)) {
      return { allowed: false, reason: 'stale-document' };
    }

    if (tool === 'navigate') {
      if (!destination || !this.allowsUrl(destination)) {
        return { allowed: false, reason: 'invalid-destination' };
      }
      if (new URL(destination).href === new URL(binding.url).href) {
        return { allowed: false, reason: 'no-op-navigation' };
      }
    } else if (tool === 'interact') {
      if (destination !== null
        || !Number.isInteger(actionIndex)
        || actionIndex < 0
        || actionIndex >= observedActions.length
        || observationToken(observedActions) !== binding.observationToken) {
        return { allowed: false, reason: 'invalid-observed-action' };
      }
      const selected = observedActions[actionIndex];
      if (!SAFE_INTERACTION_METHODS.has(selected.method ?? 'click')) {
        return { allowed: false, reason: 'unsafe-interaction-method' };
      }
      if (FINAL_TRANSACTION.test(selected.description ?? '')) {
        return { allowed: false, reason: 'final-transaction-user-takeover' };
      }
      if (DOWNLOAD_ACTION.test(selected.description ?? '')) {
        return { allowed: false, reason: 'download-requires-dedicated-tool' };
      }
      if (HANDOFF_ACTION.test(selected.description ?? '')) {
        return { allowed: false, reason: 'handoff-requires-dedicated-tool' };
      }
      if (selected.targetUrl && !this.allowsUrl(selected.targetUrl)) {
        return { allowed: false, reason: 'invalid-destination' };
      }
      if (selected.targetUrl) {
        const target = new URL(selected.targetUrl);
        for (const key of ['to', 'url', 'redirect', 'next', 'continue', 'return']) {
          const nested = target.searchParams.get(key);
          if (nested && !this.allowsUrl(nested)) {
            return { allowed: false, reason: 'redirect-target-denied' };
          }
        }
      }
      if (REDIRECT_ACTION.test(selected.description ?? '')) {
        return { allowed: false, reason: 'redirect-requires-preflight' };
      }
    } else if (tool === 'complete' && completionVerified !== true) {
      return { allowed: false, reason: 'completion-not-verified' };
    } else if (!['read_bookmarks', 'request_handoff', 'complete', 'stop'].includes(tool)) {
      return { allowed: false, reason: 'tool-denied' };
    }

    this.consumedActionIds.add(actionId);
    this.actionCount += 1;
    return { allowed: true, reason: 'allow' };
  }

  stop() {
    const tabs = [...this.ownedTabs];
    this.stopped = true;
    this.ownedTabs.clear();
    this.documents.clear();
    this.consumedActionIds.clear();
    return tabs;
  }
}

export const testing = Object.freeze({ sameBinding, validBinding });
