import type {
  AegisSettings,
  PageSnapshot,
  PhishAssessment,
  SummarizeResult,
  TabStats,
} from "@gcsa-aegis/core";

export type ExtensionRequest =
  | { type: "GET_SETTINGS" }
  | { type: "SET_SETTINGS"; patch: Partial<AegisSettings> }
  | { type: "GET_TAB_STATS"; tabId: number }
  | { type: "TOGGLE_WHITELIST"; host: string; enabled: boolean }
  | { type: "ASSESS_PAGE"; snapshot: PageSnapshot }
  | { type: "SUMMARIZE_PAGE"; snapshot: PageSnapshot }
  | { type: "GATE_PROMPT"; text: string; approved: boolean; pageUrl: string }
  | { type: "CHAT_PROMPT"; text: string; approved: boolean; pageUrl: string }
  | { type: "PHISH_FEEDBACK"; host: string; vote: "safe" | "phish" }
  | { type: "ENFORCE_COOKIES"; pageUrl?: string }
  | { type: "GET_LOCALE" }
  | { type: "PAGE_SNAPSHOT_RESULT"; tabId: number; snapshot: PageSnapshot };

export type ExtensionResponse =
  | { ok: true; settings: AegisSettings }
  | { ok: true; stats: TabStats }
  | { ok: true; assessment: PhishAssessment }
  | { ok: true; summary: SummarizeResult }
  | {
      ok: true;
      gate: {
        allowed: boolean;
        payload: string;
        reason: string;
        matches: number;
      };
    }
  | { ok: true; reply: string }
  | { ok: true; removed: number }
  | { ok: true; locale: string }
  | { ok: true }
  | { ok: false; error: string };

export async function sendMessage<T extends ExtensionResponse>(
  msg: ExtensionRequest,
): Promise<T> {
  return chrome.runtime.sendMessage(msg) as Promise<T>;
}
