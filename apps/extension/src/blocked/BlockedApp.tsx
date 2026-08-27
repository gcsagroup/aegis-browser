import { useEffect, useMemo, useState } from "react";
import { assessPhishing, type PhishReason } from "@gcsa-aegis/core";
import type { SupportedLocale } from "@gcsa-aegis/i18n";
import { Brand } from "@gcsa-aegis/ui";
import { sendMessage } from "../shared/messages";
import { getUiLocale, translate } from "../shared/locale";

function reasonLabel(locale: SupportedLocale, reason: PhishReason): string {
  const key = `phish.reason.${reason.code}`;
  const label = translate(locale, key);
  return reason.detail ? `${label} (${reason.detail})` : label;
}

export function BlockedApp() {
  const params = useMemo(() => new URLSearchParams(location.search), []);
  const target = params.get("url") ?? "";
  const scoreParam = Number(params.get("score") ?? "0");
  const [locale, setLocale] = useState<SupportedLocale>("zh-CN");

  const assessment = useMemo(
    () =>
      assessPhishing({
        url: target || "https://invalid.local",
        title: "",
        textSample: "verify your account",
        passwordFields: 1,
        forms: 1,
      }),
    [target],
  );

  useEffect(() => {
    void getUiLocale().then(setLocale);
  }, []);

  const tt = (key: string) => translate(locale, key);
  const score = Math.max(scoreParam, assessment.score);

  async function continueAnyway() {
    try {
      const host = new URL(target).hostname;
      await sendMessage({ type: "PHISH_FEEDBACK", host, vote: "safe" });
    } catch {
      /* ignore */
    }
    location.href = target;
  }

  async function markSafe() {
    try {
      const host = new URL(target).hostname;
      await sendMessage({ type: "PHISH_FEEDBACK", host, vote: "safe" });
      location.href = target;
    } catch {
      history.back();
    }
  }

  return (
    <div className="aegis-shell" style={{ maxWidth: 720, margin: "40px auto" }}>
      <Brand title={tt("appName")} tagline={tt("phish.title")} />
      <div className="aegis-card">
        <p>{tt("phish.subtitle")}</p>
        <p>
          <span className="aegis-badge">
            {tt("phish.score")}: {score}
          </span>
        </p>
        <p className="aegis-muted" style={{ wordBreak: "break-all" }}>
          {target}
        </p>
        <ul className="aegis-list">
          {assessment.reasons.map((r) => (
            <li key={`${r.code}-${r.detail ?? ""}`}>{reasonLabel(locale, r)}</li>
          ))}
        </ul>
        <div className="aegis-row" style={{ marginTop: 16 }}>
          <button className="aegis-btn" type="button" onClick={() => history.back()}>
            {tt("phish.back")}
          </button>
          <button
            className="aegis-btn secondary"
            type="button"
            onClick={() => void markSafe()}
          >
            {tt("phish.reportSafe")}
          </button>
          <button
            className="aegis-btn danger"
            type="button"
            onClick={() => void continueAnyway()}
          >
            {tt("phish.continue")}
          </button>
        </div>
      </div>
    </div>
  );
}
