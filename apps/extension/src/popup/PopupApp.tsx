import { useEffect, useState } from "react";
import type { AegisSettings, TabStats } from "@gcsa-aegis/core";
import type { SupportedLocale } from "@gcsa-aegis/i18n";
import { Brand, StatGrid, ToggleRow } from "@gcsa-aegis/ui";
import { sendMessage } from "../shared/messages";
import { getUiLocale, translate } from "../shared/locale";

export function PopupApp() {
  const [locale, setLocale] = useState<SupportedLocale>("zh-CN");
  const [settings, setSettings] = useState<AegisSettings | null>(null);
  const [stats, setStats] = useState<TabStats>({
    tabId: -1,
    blocked: 0,
    ads: 0,
    trackers: 0,
  });
  const [host, setHost] = useState("");

  useEffect(() => {
    void (async () => {
      setLocale(await getUiLocale());
      const settingsRes = await sendMessage<{ ok: true; settings: AegisSettings }>({
        type: "GET_SETTINGS",
      });
      if (settingsRes.ok) setSettings(settingsRes.settings);

      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (tab?.id != null) {
        try {
          setHost(tab.url ? new URL(tab.url).hostname : "");
        } catch {
          setHost("");
        }
        const statsRes = await sendMessage<{ ok: true; stats: TabStats }>({
          type: "GET_TAB_STATS",
          tabId: tab.id,
        });
        if (statsRes.ok) setStats(statsRes.stats);

        // Supplement counts from DNR matched rules when debug listener unavailable
        try {
          const matched = await chrome.declarativeNetRequest.getMatchedRules({
            tabId: tab.id,
          });
          const count = matched.rulesMatchedInfo?.length ?? 0;
          if (count > 0) {
            setStats((prev) => ({
              ...prev,
              blocked: Math.max(prev.blocked, count),
            }));
          }
        } catch {
          /* ignore */
        }
      }
    })();
  }, []);

  const tt = (key: string) => translate(locale, key);

  async function patchModules(key: keyof AegisSettings["modules"], value: boolean) {
    if (!settings) return;
    const res = await sendMessage<{ ok: true; settings: AegisSettings }>({
      type: "SET_SETTINGS",
      patch: { modules: { ...settings.modules, [key]: value } },
    });
    if (res.ok) setSettings(res.settings);
  }

  async function toggleWhitelist() {
    if (!host) return;
    const enabled = !settings?.trackerWhitelist.includes(host);
    const res = await sendMessage<{ ok: true; settings: AegisSettings }>({
      type: "TOGGLE_WHITELIST",
      host,
      enabled,
    });
    if (res.ok) setSettings(res.settings);
  }

  if (!settings) {
    return <div className="aegis-shell aegis-muted">…</div>;
  }

  const whitelisted = settings.trackerWhitelist.some(
    (h) => h.toLowerCase() === host.toLowerCase(),
  );

  return (
    <div className="aegis-shell">
      <Brand title={tt("popup.title")} tagline={tt("appTagline")} />

      <div className="aegis-card">
        <StatGrid
          items={[
            { label: tt("popup.blocked"), value: stats.blocked },
            { label: tt("popup.ads"), value: stats.ads },
            { label: tt("popup.trackers"), value: stats.trackers },
          ]}
        />
      </div>

      <div className="aegis-card">
        <ToggleRow
          label={tt("module.tracker")}
          checked={settings.modules.tracker}
          onChange={(v) => void patchModules("tracker", v)}
          hint={settings.modules.tracker ? tt("module.enabled") : tt("module.disabled")}
        />
        <ToggleRow
          label={tt("module.phish")}
          checked={settings.modules.phish}
          onChange={(v) => void patchModules("phish", v)}
        />
        <ToggleRow
          label={tt("module.privacyAi")}
          checked={settings.modules.privacyAi}
          onChange={(v) => void patchModules("privacyAi", v)}
        />
      </div>

      <div className="aegis-row" style={{ gap: 8, marginBottom: 8 }}>
        <button
          className="aegis-btn"
          type="button"
          onClick={() => {
            void (async () => {
              const win = await chrome.windows.getCurrent();
              if (win.id != null) {
                await chrome.sidePanel.open({ windowId: win.id });
              }
            })();
          }}
        >
          {tt("popup.openSidepanel")}
        </button>
        <button
          className="aegis-btn secondary"
          type="button"
          onClick={() => void chrome.runtime.openOptionsPage()}
        >
          {tt("popup.openOptions")}
        </button>
      </div>

      {host ? (
        <button className="aegis-btn secondary" type="button" onClick={() => void toggleWhitelist()}>
          {whitelisted ? tt("popup.removeWhitelist") : tt("popup.whitelistSite")}
          <div className="aegis-muted">{host}</div>
        </button>
      ) : null}
    </div>
  );
}
