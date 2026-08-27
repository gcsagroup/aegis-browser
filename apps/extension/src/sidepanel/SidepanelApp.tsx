import { useEffect, useState } from "react";
import type { PageSnapshot, SummarizeResult } from "@gcsa-aegis/core";
import type { SupportedLocale } from "@gcsa-aegis/i18n";
import { Brand } from "@gcsa-aegis/ui";
import { sendMessage } from "../shared/messages";
import { getUiLocale, translate } from "../shared/locale";

async function collectActiveSnapshot(): Promise<PageSnapshot | null> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) return null;
  try {
    const [{ result }] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => ({
        url: location.href,
        title: document.title,
        textSample: document.body?.innerText?.slice(0, 8000) ?? "",
        forms: document.querySelectorAll("form").length,
        passwordFields: document.querySelectorAll('input[type="password"]').length,
      }),
    });
    return result as PageSnapshot;
  } catch {
    return {
      url: tab.url ?? "",
      title: tab.title ?? "",
      textSample: "",
      forms: 0,
      passwordFields: 0,
    };
  }
}

export function SidepanelApp() {
  const [locale, setLocale] = useState<SupportedLocale>("zh-CN");
  const [summary, setSummary] = useState<SummarizeResult | null>(null);
  const [loading, setLoading] = useState(false);
  const [prompt, setPrompt] = useState("");
  const [reply, setReply] = useState("");
  const [pendingRedacted, setPendingRedacted] = useState<string | null>(null);
  const [pageUrl, setPageUrl] = useState("");

  useEffect(() => {
    void getUiLocale().then(setLocale);
  }, []);

  const tt = (key: string) => translate(locale, key);

  async function summarize() {
    setLoading(true);
    setSummary(null);
    const snapshot = await collectActiveSnapshot();
    if (!snapshot) {
      setLoading(false);
      return;
    }
    setPageUrl(snapshot.url);
    const res = await sendMessage<{ ok: true; summary: SummarizeResult }>({
      type: "SUMMARIZE_PAGE",
      snapshot,
    });
    if (res.ok) setSummary(res.summary);
    setLoading(false);
  }

  async function send(approved = false, text = prompt) {
    const snapshot = await collectActiveSnapshot();
    const url = snapshot?.url ?? pageUrl;
    const res = await sendMessage<
      | { ok: true; reply: string }
      | {
          ok: true;
          gate: {
            allowed: boolean;
            payload: string;
            reason: string;
            matches: number;
          };
        }
      | { ok: false; error: string }
    >({
      type: "CHAT_PROMPT",
      text,
      approved,
      pageUrl: url,
    });

    if (!res.ok) {
      setReply(tt("sidepanel.cloudBlocked"));
      return;
    }
    if ("gate" in res && res.gate && !res.gate.allowed) {
      setPendingRedacted(res.gate.payload);
      return;
    }
    if ("reply" in res) {
      setReply(res.reply);
      setPendingRedacted(null);
      setPrompt("");
    }
  }

  return (
    <div className="aegis-shell">
      <Brand title={tt("sidepanel.title")} tagline={tt("appTagline")} />

      <button
        className="aegis-btn"
        type="button"
        disabled={loading}
        onClick={() => void summarize()}
        style={{ width: "100%", marginBottom: 12 }}
      >
        {loading ? tt("sidepanel.summarizing") : tt("sidepanel.summarize")}
      </button>

      {summary ? (
        <div className="aegis-card">
          {!summary.modelReady ? (
            <div className="aegis-badge" style={{ marginBottom: 8 }}>
              {tt("sidepanel.modelNotReady")}
            </div>
          ) : null}
          <h3 style={{ marginTop: 0 }}>{tt("sidepanel.summary")}</h3>
          <p>{summary.summary}</p>
          <h4>{tt("sidepanel.bullets")}</h4>
          <ul className="aegis-list">
            {summary.bullets.map((b) => (
              <li key={b}>{b}</li>
            ))}
          </ul>
          {summary.risks.length > 0 ? (
            <>
              <h4>{tt("sidepanel.risks")}</h4>
              <ul className="aegis-list">
                {summary.risks.map((r) => (
                  <li key={r}>{r}</li>
                ))}
              </ul>
            </>
          ) : null}
        </div>
      ) : null}

      <div className="aegis-card">
        <div className="aegis-field">
          <label htmlFor="prompt">{tt("sidepanel.prompt")}</label>
          <textarea
            id="prompt"
            value={prompt}
            onChange={(e) => setPrompt(e.target.value)}
          />
        </div>
        <button
          className="aegis-btn"
          type="button"
          onClick={() => void send(false)}
          disabled={!prompt.trim()}
        >
          {tt("sidepanel.send")}
        </button>
      </div>

      {pendingRedacted ? (
        <div className="aegis-card">
          <p>{tt("sidepanel.piiGate")}</p>
          <pre
            style={{
              whiteSpace: "pre-wrap",
              fontFamily: "var(--aegis-mono)",
              fontSize: 12,
              background: "rgba(0,0,0,.25)",
              padding: 8,
              borderRadius: 8,
            }}
          >
            {pendingRedacted}
          </pre>
          <div className="aegis-row">
            <button
              className="aegis-btn"
              type="button"
              onClick={() => void send(true, pendingRedacted)}
            >
              {tt("sidepanel.approveRedacted")}
            </button>
            <button
              className="aegis-btn secondary"
              type="button"
              onClick={() => setPendingRedacted(null)}
            >
              {tt("sidepanel.cancel")}
            </button>
          </div>
        </div>
      ) : null}

      {reply ? (
        <div className="aegis-card">
          <p style={{ whiteSpace: "pre-wrap" }}>{reply}</p>
        </div>
      ) : null}
    </div>
  );
}
