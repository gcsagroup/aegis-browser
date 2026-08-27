import {
  PolicyEngine,
  TRACKING_QUERY_PARAMS,
  classifyBlockedUrl,
  type AegisPorts,
} from "@gcsa-aegis/core";
import { resolveLocale } from "@gcsa-aegis/i18n";
import { createPorts } from "./ports";
import { fetchRemoteHostRules } from "./remote-rules";
import {
  loadPhishFeedback,
  loadSettings,
  savePhishFeedback,
} from "../shared/settings";
import type { ExtensionRequest, ExtensionResponse } from "../shared/messages";

let engine: PolicyEngine;
let ports: AegisPorts;
let refreshModel: () => Promise<void>;

const sessionBypass = new Set<string>();

async function syncAllRules() {
  const settings = engine.getSettings();
  let remote: Awaited<ReturnType<typeof fetchRemoteHostRules>> = [];
  if (settings.ruleSourceUrl) {
    try {
      remote = await fetchRemoteHostRules(settings.ruleSourceUrl);
    } catch (err) {
      console.warn("[aegis] remote rules fetch failed", err);
    }
  }
  await engine.syncTrackerRules(remote);
}

async function init() {
  const created = await createPorts();
  ports = created.ports;
  refreshModel = created.refreshModel;
  engine = new PolicyEngine(ports);
  await engine.init();
  await syncAllRules();
  engine.loadPhishFeedback(await loadPhishFeedback());

  chrome.declarativeNetRequest.onRuleMatchedDebug?.addListener((info) => {
    const tabId = info.request.tabId;
    if (tabId < 0) return;
    engine.recordBlock({
      id: `${info.request.requestId}`,
      tabId,
      url: info.request.url,
      timestamp: Date.now(),
      ruleId: info.rule.ruleId,
      type: classifyBlockedUrl(info.request.url),
    });
  });
}

const ready = init();

chrome.runtime.onInstalled.addListener(async () => {
  await ready;
  if (chrome.sidePanel?.setPanelBehavior) {
    await chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: false });
  }
});

chrome.webNavigation.onCommitted.addListener(async (details) => {
  await ready;
  if (details.frameId !== 0 || details.tabId < 0) return;
  if (!engine.getSettings().modules.phish) return;
  if (!/^https?:/i.test(details.url)) return;

  let host = "";
  try {
    host = new URL(details.url).hostname;
  } catch {
    return;
  }
  if (sessionBypass.has(host)) return;

  const quick = engine.assessPage({
    url: details.url,
    title: "",
    textSample: "",
    forms: 0,
    passwordFields: 0,
  });

  if (quick.score >= 70) {
    const blockedUrl = chrome.runtime.getURL(
      `src/blocked/index.html?url=${encodeURIComponent(details.url)}&score=${quick.score}`,
    );
    await chrome.tabs.update(details.tabId, { url: blockedUrl });
  }
});

chrome.webNavigation.onCompleted.addListener(async (details) => {
  await ready;
  if (details.frameId !== 0 || details.tabId < 0) return;
  const settings = engine.getSettings();

  if (settings.sanitizeLinkDecorations && settings.modules.tracker) {
    try {
      await ports.page.sanitizeLinks?.(details.tabId, [...TRACKING_QUERY_PARAMS]);
    } catch {
      /* restricted pages */
    }
  }

  if (settings.modules.tracker && settings.rejectedCookieCategories.length) {
    try {
      await engine.enforceCookiePolicy(details.url);
    } catch {
      /* ignore */
    }
  }
});

chrome.runtime.onMessage.addListener(
  (message: ExtensionRequest, sender, sendResponse) => {
    void (async () => {
      await ready;
      try {
        sendResponse(await handleMessage(message, sender));
      } catch (err) {
        sendResponse({
          ok: false,
          error: err instanceof Error ? err.message : String(err),
        } satisfies ExtensionResponse);
      }
    })();
    return true;
  },
);

async function handleMessage(
  message: ExtensionRequest,
  sender: chrome.runtime.MessageSender,
): Promise<ExtensionResponse> {
  switch (message.type) {
    case "GET_SETTINGS":
      return { ok: true, settings: engine.getSettings() };

    case "SET_SETTINGS": {
      const settings = await engine.updateSettings(message.patch);
      await refreshModel();
      await syncAllRules();
      return { ok: true, settings };
    }

    case "GET_TAB_STATS":
      return { ok: true, stats: engine.getTabStats(message.tabId) };

    case "TOGGLE_WHITELIST": {
      const settings = engine.getSettings();
      const set = new Set(settings.trackerWhitelist.map((h) => h.toLowerCase()));
      const host = message.host.toLowerCase();
      if (message.enabled) set.add(host);
      else set.delete(host);
      const next = await engine.updateSettings({
        trackerWhitelist: [...set],
      });
      return { ok: true, settings: next };
    }

    case "ASSESS_PAGE":
      return { ok: true, assessment: engine.assessPage(message.snapshot) };

    case "SUMMARIZE_PAGE":
      return { ok: true, summary: await engine.summarize(message.snapshot) };

    case "GATE_PROMPT": {
      const gate = engine.gateCloudPrompt(message.text, message.approved);
      return {
        ok: true,
        gate: {
          allowed: gate.allowed,
          payload: gate.payload,
          reason: gate.reason,
          matches: gate.scan.matches.length,
        },
      };
    }

    case "CHAT_PROMPT": {
      const settings = engine.getSettings();
      const gate = engine.gateCloudPrompt(message.text, message.approved);

      // Always PII-scan; block send when cloud enabled and not approved
      if (settings.allowCloudModels && !gate.allowed) {
        return {
          ok: true,
          gate: {
            allowed: false,
            payload: gate.payload,
            reason: gate.reason,
            matches: gate.scan.matches.length,
          },
        };
      }

      if (
        settings.allowCloudModels &&
        !engine.cloudUploadAllowedForUrl(message.pageUrl)
      ) {
        return { ok: false, error: "cloud_blocked_sensitive" };
      }

      // Local backends use redacted text when PII was present
      const text =
        gate.scan.matches.length > 0 && !message.approved
          ? gate.payload
          : message.approved
            ? gate.payload
            : message.text;

      // Force redaction for local path when PII found and not approved
      if (gate.scan.matches.length > 0 && !message.approved) {
        return {
          ok: true,
          gate: {
            allowed: false,
            payload: gate.payload,
            reason: "pii_blocked",
            matches: gate.scan.matches.length,
          },
        };
      }

      const reply = await ports.model.chat([
        {
          role: "system",
          content:
            "You are GCSA-aegis local privacy assistant. Keep answers concise. Never ask for secrets.",
        },
        { role: "user", content: text },
      ]);
      return { ok: true, reply };
    }

    case "PHISH_FEEDBACK": {
      engine.markPhishFeedback(message.host, message.vote);
      await savePhishFeedback(engine.getPhishFeedback());
      if (message.vote === "safe") {
        sessionBypass.add(message.host.toLowerCase());
        const settings = engine.getSettings();
        if (!settings.phishAllowlist.includes(message.host)) {
          await engine.updateSettings({
            phishAllowlist: [...settings.phishAllowlist, message.host],
          });
        }
      }
      return { ok: true };
    }

    case "ENFORCE_COOKIES":
      return {
        ok: true,
        removed: await engine.enforceCookiePolicy(message.pageUrl),
      };

    case "GET_LOCALE": {
      const settings = await loadSettings();
      return {
        ok: true,
        locale: resolveLocale(settings.locale, chrome.i18n.getUILanguage()),
      };
    }

    case "PAGE_SNAPSHOT_RESULT": {
      const assessment = await engine.assessPageAsync(message.snapshot);
      const tabId = sender.tab?.id ?? message.tabId;
      if (assessment.shouldBlock && tabId >= 0) {
        let host = "";
        try {
          host = new URL(message.snapshot.url).hostname;
        } catch {
          host = "";
        }
        if (host && !sessionBypass.has(host)) {
          const blockedUrl = chrome.runtime.getURL(
            `src/blocked/index.html?url=${encodeURIComponent(message.snapshot.url)}&score=${assessment.score}`,
          );
          await chrome.tabs.update(tabId, { url: blockedUrl });
        }
      }
      return { ok: true, assessment };
    }

    default:
      return { ok: false, error: "unknown_message" };
  }
}

chrome.alarms.create("aegis-keepalive", { periodInMinutes: 4 });
chrome.alarms.onAlarm.addListener(() => {
  void ready;
});
