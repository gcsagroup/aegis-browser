import type {
  AegisPorts,
  ModelRuntimePort,
  NetPolicyPort,
  NetRule,
  PageSensePort,
  StorageCookie,
  StoragePolicyPort,
} from "@gcsa-aegis/core";
import { classifyCookie } from "@gcsa-aegis/core";
import { createModelRuntime } from "@gcsa-aegis/model-runtime";
import { loadSettings, saveSettings } from "../shared/settings";

function toDnrRule(rule: NetRule): chrome.declarativeNetRequest.Rule {
  return {
    id: rule.id,
    priority: rule.priority ?? 1,
    action: {
      type:
        rule.action === "block"
          ? chrome.declarativeNetRequest.RuleActionType.BLOCK
          : rule.action === "allow"
            ? chrome.declarativeNetRequest.RuleActionType.ALLOW
            : chrome.declarativeNetRequest.RuleActionType.UPGRADE_SCHEME,
    },
    condition: {
      urlFilter: rule.urlFilter,
      resourceTypes: (rule.resourceTypes ?? [
        "script",
        "image",
        "xmlhttprequest",
        "sub_frame",
        "ping",
        "other",
      ]) as chrome.declarativeNetRequest.ResourceType[],
      ...(rule.excludedDomains?.length
        ? { excludedRequestDomains: rule.excludedDomains }
        : {}),
      ...(rule.domains?.length ? { requestDomains: rule.domains } : {}),
    },
  };
}

export function createNetPort(): NetPolicyPort {
  return {
    async applyRules(rules) {
      const existing = await chrome.declarativeNetRequest.getDynamicRules();
      const removeRuleIds = existing.map((r) => r.id);
      await chrome.declarativeNetRequest.updateDynamicRules({
        removeRuleIds,
        addRules: rules.map(toDnrRule),
      });
    },
    async clearRules(ids) {
      if (ids?.length) {
        await chrome.declarativeNetRequest.updateDynamicRules({
          removeRuleIds: ids,
        });
        return;
      }
      const existing = await chrome.declarativeNetRequest.getDynamicRules();
      await chrome.declarativeNetRequest.updateDynamicRules({
        removeRuleIds: existing.map((r) => r.id),
      });
    },
  };
}

export function createStoragePort(): StoragePolicyPort {
  return {
    async listCookies(url) {
      const cookies = url
        ? await chrome.cookies.getAll({ url })
        : await chrome.cookies.getAll({});
      return cookies.map(
        (c): StorageCookie => ({
          name: c.name,
          value: c.value,
          domain: c.domain,
          path: c.path,
          secure: c.secure,
          httpOnly: c.httpOnly,
          sameSite: c.sameSite,
          expirationDate: c.expirationDate,
          session: c.session,
        }),
      );
    },
    async removeCookie(cookie) {
      const protocol = cookie.secure ? "https" : "http";
      const domain = cookie.domain.startsWith(".")
        ? cookie.domain.slice(1)
        : cookie.domain;
      await chrome.cookies.remove({
        url: `${protocol}://${domain}${cookie.path}`,
        name: cookie.name,
      });
    },
    classifyCookie,
  };
}

export function createPagePort(): PageSensePort {
  return {
    async getSnapshot(tabId) {
      const [result] = await chrome.scripting.executeScript({
        target: { tabId },
        func: () => {
          const text = document.body?.innerText?.slice(0, 8000) ?? "";
          const forms = document.querySelectorAll("form").length;
          const passwordFields = document.querySelectorAll(
            'input[type="password"]',
          ).length;
          return {
            url: location.href,
            title: document.title,
            textSample: text,
            forms,
            passwordFields,
          };
        },
      });
      return (
        result?.result ?? {
          url: "",
          title: "",
          textSample: "",
          forms: 0,
          passwordFields: 0,
        }
      );
    },
    async sanitizeLinks(tabId, params) {
      const [result] = await chrome.scripting.executeScript({
        target: { tabId },
        args: [params],
        func: (blockParams: string[]) => {
          const set = new Set(blockParams.map((p) => p.toLowerCase()));
          let count = 0;
          for (const a of Array.from(document.querySelectorAll("a[href]"))) {
            try {
              const url = new URL((a as HTMLAnchorElement).href, location.href);
              let changed = false;
              for (const key of [...url.searchParams.keys()]) {
                if (set.has(key.toLowerCase())) {
                  url.searchParams.delete(key);
                  changed = true;
                }
              }
              if (changed) {
                (a as HTMLAnchorElement).href = url.toString();
                count += 1;
              }
            } catch {
              /* ignore */
            }
          }
          return count;
        },
      });
      return (result?.result as number) ?? 0;
    },
  };
}

export async function createPorts(): Promise<{
  ports: AegisPorts;
  refreshModel: () => Promise<void>;
}> {
  let model: ModelRuntimePort = createModelRuntime({ backend: "mock" });

  const refreshModel = async () => {
    const settings = await loadSettings();
    model = createModelRuntime({
      backend: settings.modelBackend,
      ollamaBaseUrl: settings.ollamaBaseUrl,
      ollamaModel: settings.ollamaModel,
    });
  };

  await refreshModel();

  const ports: AegisPorts = {
    net: createNetPort(),
    storage: createStoragePort(),
    page: createPagePort(),
    get model() {
      return model;
    },
    settings: {
      get: loadSettings,
      set: saveSettings,
    },
  };

  return { ports, refreshModel };
}
