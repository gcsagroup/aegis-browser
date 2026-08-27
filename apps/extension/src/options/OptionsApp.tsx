import { useEffect, useState } from "react";
import type { AegisSettings, CookieCategory, ModelBackend } from "@gcsa-aegis/core";
import type { LocalePreference, SupportedLocale } from "@gcsa-aegis/i18n";
import { resolveLocale } from "@gcsa-aegis/i18n";
import { Brand, ToggleRow } from "@gcsa-aegis/ui";
import { sendMessage } from "../shared/messages";
import { translate } from "../shared/locale";

export function OptionsApp() {
  const [settings, setSettings] = useState<AegisSettings | null>(null);
  const [saved, setSaved] = useState(false);
  const [locale, setLocale] = useState<SupportedLocale>("zh-CN");

  useEffect(() => {
    void (async () => {
      const res = await sendMessage<{ ok: true; settings: AegisSettings }>({
        type: "GET_SETTINGS",
      });
      if (res.ok) {
        setSettings(res.settings);
        setLocale(resolveLocale(res.settings.locale, chrome.i18n.getUILanguage()));
      }
    })();
  }, []);

  const tt = (key: string) => translate(locale, key);

  async function save(next: AegisSettings) {
    const res = await sendMessage<{ ok: true; settings: AegisSettings }>({
      type: "SET_SETTINGS",
      patch: next,
    });
    if (res.ok) {
      setSettings(res.settings);
      setLocale(resolveLocale(res.settings.locale, chrome.i18n.getUILanguage()));
      setSaved(true);
      setTimeout(() => setSaved(false), 1500);
    }
  }

  if (!settings) return <div className="aegis-shell">…</div>;

  function toggleCookie(cat: CookieCategory, on: boolean) {
    const set = new Set(settings!.rejectedCookieCategories);
    if (on) set.add(cat);
    else set.delete(cat);
    setSettings({ ...settings!, rejectedCookieCategories: [...set] });
  }

  return (
    <div className="aegis-shell" style={{ maxWidth: 720, margin: "0 auto" }}>
      <Brand title={tt("options.title")} tagline={tt("appTagline")} />

      <div className="aegis-card">
        <div className="aegis-field">
          <label htmlFor="locale">{tt("options.language")}</label>
          <select
            id="locale"
            value={settings.locale}
            onChange={(e) =>
              setSettings({
                ...settings,
                locale: e.target.value as LocalePreference,
              })
            }
          >
            <option value="zh-CN">{tt("options.language.zh-CN")}</option>
            <option value="zh-TW">{tt("options.language.zh-TW")}</option>
            <option value="en">{tt("options.language.en")}</option>
            <option value="auto">{tt("options.language.auto")}</option>
          </select>
        </div>
      </div>

      <div className="aegis-card">
        <h3 style={{ marginTop: 0 }}>{tt("options.modules")}</h3>
        <ToggleRow
          label={tt("module.tracker")}
          checked={settings.modules.tracker}
          onChange={(v) =>
            setSettings({
              ...settings,
              modules: { ...settings.modules, tracker: v },
            })
          }
        />
        <ToggleRow
          label={tt("module.phish")}
          checked={settings.modules.phish}
          onChange={(v) =>
            setSettings({
              ...settings,
              modules: { ...settings.modules, phish: v },
            })
          }
        />
        <ToggleRow
          label={tt("module.privacyAi")}
          checked={settings.modules.privacyAi}
          onChange={(v) =>
            setSettings({
              ...settings,
              modules: { ...settings.modules, privacyAi: v },
            })
          }
        />
      </div>

      <div className="aegis-card">
        <div className="aegis-field">
          <label htmlFor="model">{tt("options.model")}</label>
          <select
            id="model"
            value={settings.modelBackend}
            onChange={(e) =>
              setSettings({
                ...settings,
                modelBackend: e.target.value as ModelBackend,
              })
            }
          >
            <option value="mock">{tt("options.model.mock")}</option>
            <option value="webllm">{tt("options.model.webllm")}</option>
            <option value="ollama">{tt("options.model.ollama")}</option>
          </select>
        </div>
        <div className="aegis-field">
          <label htmlFor="ollamaUrl">{tt("options.ollamaBaseUrl")}</label>
          <input
            id="ollamaUrl"
            value={settings.ollamaBaseUrl}
            onChange={(e) =>
              setSettings({ ...settings, ollamaBaseUrl: e.target.value })
            }
          />
        </div>
        <div className="aegis-field">
          <label htmlFor="ollamaModel">{tt("options.ollamaModel")}</label>
          <input
            id="ollamaModel"
            value={settings.ollamaModel}
            onChange={(e) =>
              setSettings({ ...settings, ollamaModel: e.target.value })
            }
          />
        </div>
        <ToggleRow
          label={tt("options.allowCloud")}
          checked={settings.allowCloudModels}
          onChange={(v) => setSettings({ ...settings, allowCloudModels: v })}
        />
      </div>

      <div className="aegis-card">
        <ToggleRow
          label={tt("options.sanitizeLinks")}
          checked={settings.sanitizeLinkDecorations}
          onChange={(v) =>
            setSettings({ ...settings, sanitizeLinkDecorations: v })
          }
        />
        <div className="aegis-field">
          <label htmlFor="rules">{tt("options.ruleSource")}</label>
          <input
            id="rules"
            value={settings.ruleSourceUrl}
            onChange={(e) =>
              setSettings({ ...settings, ruleSourceUrl: e.target.value })
            }
            placeholder="https://..."
          />
        </div>
        <div>
          <div className="aegis-muted" style={{ marginBottom: 8 }}>
            {tt("options.cookiePolicy")}
          </div>
          {(["analytics", "advertising", "functionality"] as CookieCategory[]).map(
            (cat) => (
              <ToggleRow
                key={cat}
                label={tt(`options.cookie.${cat}`)}
                checked={settings.rejectedCookieCategories.includes(cat)}
                onChange={(v) => toggleCookie(cat, v)}
              />
            ),
          )}
        </div>
        <div className="aegis-field">
          <label htmlFor="wl">{tt("options.whitelist")}</label>
          <textarea
            id="wl"
            value={settings.trackerWhitelist.join("\n")}
            onChange={(e) =>
              setSettings({
                ...settings,
                trackerWhitelist: e.target.value
                  .split("\n")
                  .map((s) => s.trim())
                  .filter(Boolean),
              })
            }
          />
        </div>
        <div className="aegis-field">
          <label htmlFor="phishWl">{tt("options.phishAllowlist")}</label>
          <textarea
            id="phishWl"
            value={settings.phishAllowlist.join("\n")}
            onChange={(e) =>
              setSettings({
                ...settings,
                phishAllowlist: e.target.value
                  .split("\n")
                  .map((s) => s.trim())
                  .filter(Boolean),
              })
            }
          />
        </div>
      </div>

      <button className="aegis-btn" type="button" onClick={() => void save(settings)}>
        {saved ? tt("options.saved") : tt("options.save")}
      </button>
    </div>
  );
}
