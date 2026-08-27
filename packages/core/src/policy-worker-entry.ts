/**
 * Isolated JS policy worker entry.
 * Bundled as IIFE and evaluated in a gin isolate (no DOM / no fetch).
 */
import { scorePhishingUrl, assessPhishing } from "./phish/detector.js";
import { scanPii, gateOutboundText } from "./privacy/pii.js";
import {
  buildSummarizePrompt,
  heuristicSummary,
  isSensitiveOrigin,
} from "./privacy/orchestrator.js";
import { sanitizeUrlDecorations } from "./tracker/link-sanitize.js";
import { classifyCookie } from "./tracker/cookie-classify.js";
import type { LocaleCode, PageSnapshot } from "./types.js";

export interface WorkerRequest {
  op: string;
  url?: string;
  text?: string;
  locale?: Exclude<LocaleCode, "auto">;
  snapshot?: PageSnapshot;
  cookie?: {
    name: string;
    value: string;
    domain: string;
    path: string;
    secure: boolean;
    httpOnly: boolean;
    session: boolean;
    expirationDate?: number;
  };
  userApproved?: boolean;
}

export function evaluateRequest(req: WorkerRequest): unknown {
  switch (req.op) {
    case "ping":
      return { ok: true, worker: "aegis-policy" };
    case "scorePhish":
      return scorePhishingUrl(req.url ?? "");
    case "assessPhish":
      return assessPhishing(
        req.snapshot ?? {
          url: req.url ?? "",
          title: "",
          textSample: req.text ?? "",
        },
      );
    case "scanPii":
      return scanPii(req.text ?? "");
    case "gateOutbound":
      return gateOutboundText(req.text ?? "", Boolean(req.userApproved));
    case "sanitizeUrl":
      return sanitizeUrlDecorations(req.url ?? "");
    case "classifyCookie":
      return {
        category: classifyCookie({
          name: req.cookie?.name ?? "",
          value: req.cookie?.value ?? "",
          domain: req.cookie?.domain ?? "",
          path: req.cookie?.path ?? "/",
          secure: Boolean(req.cookie?.secure),
          httpOnly: Boolean(req.cookie?.httpOnly),
          session: req.cookie?.session ?? true,
          expirationDate: req.cookie?.expirationDate,
        }),
      };
    case "isSensitive":
      return { sensitive: isSensitiveOrigin(req.url ?? "") };
    case "summarize": {
      const locale = req.locale ?? "zh-CN";
      const snapshot = req.snapshot ?? {
        url: req.url ?? "",
        title: "",
        textSample: req.text ?? "",
      };
      return heuristicSummary(snapshot, locale);
    }
    case "buildPrompt": {
      const locale = req.locale ?? "zh-CN";
      const snapshot = req.snapshot ?? {
        url: req.url ?? "",
        title: "",
        textSample: req.text ?? "",
      };
      return buildSummarizePrompt({ locale, snapshot });
    }
    default:
      return { error: `unknown op: ${req.op}` };
  }
}

export function aegisEvaluate(requestJson: string): string {
  try {
    const req = JSON.parse(requestJson) as WorkerRequest;
    if (!req || typeof req.op !== "string") {
      return JSON.stringify({ error: "missing op" });
    }
    return JSON.stringify(evaluateRequest(req));
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return JSON.stringify({ error: message });
  }
}

const g = globalThis as typeof globalThis & {
  aegisEvaluate?: typeof aegisEvaluate;
};
g.aegisEvaluate = aegisEvaluate;
