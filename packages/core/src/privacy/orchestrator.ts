import type { ModelRuntimePort } from "../ports.js";
import type {
  LocaleCode,
  PageSnapshot,
  SummarizeRequest,
  SummarizeResult,
  ModelBackend,
} from "../types.js";
import { scanPii } from "./pii.js";

const SYSTEM_PROMPTS: Record<Exclude<LocaleCode, "auto">, string> = {
  "zh-CN":
    "你是 GCSA-aegis 本地隐私助手。根据页面摘录给出简洁摘要、要点列表和隐私/安全风险。不要编造页面中没有的事实。用简体中文回答。",
  "zh-TW":
    "你是 GCSA-aegis 本地隱私助手。根據頁面摘錄給出簡潔摘要、要點列表與隱私/安全風險。不要編造頁面中沒有的事實。用繁體中文回答。",
  en: "You are the GCSA-aegis local privacy assistant. Summarize the page excerpt, list key points, and note privacy/security risks. Do not invent facts. Answer in English.",
};

const MAX_PROMPT_URL_CHARS = 2048;
const MAX_PROMPT_TITLE_CHARS = 512;
const MAX_PROMPT_TEXT_CHARS = 6000;

export interface PreparedSummary {
  schemaVersion: 1;
  sanitizedSnapshot: PageSnapshot;
  heuristic: {
    summary: string;
    bullets: string[];
    risks: string[];
  };
}

function redactUrlPath(pathname: string): string {
  return pathname
    .split("/")
    .map((segment) => {
      if (!segment) return segment;
      try {
        return encodeURIComponent(scanPii(decodeURIComponent(segment)).redacted);
      } catch {
        return encodeURIComponent(scanPii(segment).redacted);
      }
    })
    .join("/");
}

/**
 * Preserve only non-sensitive URL structure for the local model. Query and
 * fragment values are always replaced because tokens are not reliably
 * distinguishable from ordinary identifiers.
 */
export function redactUrlForModel(rawUrl: string): string {
  try {
    const url = new URL(rawUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") {
      return "[UNSUPPORTED_URL]";
    }
    url.username = "";
    url.password = "";
    url.pathname = redactUrlPath(url.pathname);

    const queryKeys = [...new Set(url.searchParams.keys())];
    url.search = "";
    for (const key of queryKeys) {
      url.searchParams.append(scanPii(key).redacted, "[REDACTED]");
    }
    if (url.hash) {
      url.hash = "[REDACTED]";
    }
    return scanPii(url.toString()).redacted.slice(0, MAX_PROMPT_URL_CHARS);
  } catch {
    return "[INVALID_URL]";
  }
}

/** The only snapshot shape allowed to cross the model-request boundary. */
export function redactPageSnapshotForModel(
  snapshot: PageSnapshot,
): PageSnapshot {
  return {
    url: redactUrlForModel(snapshot.url),
    title: scanPii(snapshot.title).redacted.slice(0, MAX_PROMPT_TITLE_CHARS),
    textSample: scanPii(snapshot.textSample).redacted.slice(
      0,
      MAX_PROMPT_TEXT_CHARS,
    ),
    forms: Math.max(0, Math.trunc(snapshot.forms ?? 0)),
    passwordFields: Math.max(0, Math.trunc(snapshot.passwordFields ?? 0)),
  };
}

export function buildSummarizePrompt(req: SummarizeRequest): {
  system: string;
  user: string;
} {
  const locale = req.locale;
  const snap = redactPageSnapshotForModel(req.snapshot);

  return {
    system: SYSTEM_PROMPTS[locale],
    user: [
      `URL: ${snap.url}`,
      `Title: ${snap.title}`,
      `Forms: ${snap.forms ?? 0}, password fields: ${snap.passwordFields ?? 0}`,
      "--- Page excerpt (PII redacted) ---",
      snap.textSample || "(empty)",
      "---",
      "Respond as JSON: {\"summary\":string,\"bullets\":string[],\"risks\":string[]}",
    ].join("\n"),
  };
}

export function heuristicSummary(
  snapshot: PageSnapshot,
  locale: Exclude<LocaleCode, "auto">,
): SummarizeResult {
  const safeSnapshot = redactPageSnapshotForModel(snapshot);
  const text = safeSnapshot.textSample.replace(/\s+/g, " ").trim();
  const summary =
    text.slice(0, 220) ||
    (locale === "en"
      ? "No readable page text was captured."
      : locale === "zh-TW"
        ? "未能擷取可讀頁面文字。"
        : "未能提取可读页面文本。");

  const risks: string[] = [];
  if ((safeSnapshot.passwordFields ?? 0) > 0) {
    risks.push(
      locale === "en"
        ? "Page contains password fields — verify the domain before signing in."
        : locale === "zh-TW"
          ? "頁面含密碼欄位，登入前請確認網域。"
          : "页面含密码字段，登录前请确认域名。",
    );
  }
  try {
    if (new URL(safeSnapshot.url).protocol === "http:") {
      risks.push(
        locale === "en"
          ? "Connection is not HTTPS."
          : locale === "zh-TW"
            ? "連線未使用 HTTPS。"
            : "连接未使用 HTTPS。",
      );
    }
  } catch {
    /* ignore */
  }

  const bullets = text
    .split(/[.。！？!?]/)
    .map((s) => s.trim())
    .filter((s) => s.length > 20)
    .slice(0, 3);

  return {
    summary,
    bullets:
      bullets.length > 0
        ? bullets
        : [
            locale === "en"
              ? "Open the side panel on a content-heavy page for better results."
              : locale === "zh-TW"
                ? "請在內容較多的頁面開啟側欄以獲得更好摘要。"
                : "请在内容较多的页面打开侧栏以获得更好摘要。",
          ],
    risks,
    backend: "mock",
    modelReady: true,
  };
}

/**
 * Renderer-to-browser contract for page summaries. It intentionally contains
 * neither a model prompt nor system/user messages; the browser owns those.
 */
export function prepareSummary(
  snapshot: PageSnapshot,
  locale: Exclude<LocaleCode, "auto">,
): PreparedSummary {
  const sanitizedSnapshot = redactPageSnapshotForModel(snapshot);
  const local = heuristicSummary(sanitizedSnapshot, locale);
  return {
    schemaVersion: 1,
    sanitizedSnapshot,
    heuristic: {
      summary: local.summary,
      bullets: local.bullets,
      risks: local.risks,
    },
  };
}

function parseModelJson(raw: string): {
  summary: string;
  bullets: string[];
  risks: string[];
} | null {
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try {
    const obj = JSON.parse(raw.slice(start, end + 1)) as {
      summary?: string;
      bullets?: string[];
      risks?: string[];
    };
    return {
      summary: obj.summary ?? "",
      bullets: Array.isArray(obj.bullets) ? obj.bullets : [],
      risks: Array.isArray(obj.risks) ? obj.risks : [],
    };
  } catch {
    return null;
  }
}

export async function summarizePage(
  model: ModelRuntimePort,
  backend: ModelBackend,
  req: SummarizeRequest,
): Promise<SummarizeResult> {
  if (backend === "mock") {
    return heuristicSummary(req.snapshot, req.locale);
  }

  const ready = await model.ready();
  if (!ready) {
    const fallback = heuristicSummary(req.snapshot, req.locale);
    return { ...fallback, modelReady: false, backend };
  }

  const { system, user } = buildSummarizePrompt(req);
  const raw = await model.chat([
    { role: "system", content: system },
    { role: "user", content: user },
  ]);
  const parsed = parseModelJson(raw);
  if (!parsed) {
    return {
      summary: raw.slice(0, 500),
      bullets: [],
      risks: [],
      backend,
      modelReady: true,
    };
  }
  return { ...parsed, backend, modelReady: true };
}

/** Sensitive origins where cloud upload capabilities should stay disabled. */
export function isSensitiveOrigin(url: string): boolean {
  try {
    const u = new URL(url);
    const host = u.hostname.toLowerCase();
    if (u.protocol === "chrome:" || u.protocol === "edge:" || u.protocol === "about:") {
      return true;
    }
    return /(^|\.)(bank|paypal|alipay|gov|irs|healthcare|hospital|clinic)/.test(
      host,
    );
  } catch {
    return true;
  }
}
