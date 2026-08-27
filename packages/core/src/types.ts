export type LocaleCode = "zh-CN" | "zh-TW" | "en" | "auto";

export type ModuleId = "tracker" | "phish" | "privacyAi";

export interface ModuleToggles {
  tracker: boolean;
  phish: boolean;
  privacyAi: boolean;
}

export type ModelBackend = "mock" | "webllm" | "ollama";

export type CookieCategory =
  | "necessary"
  | "functionality"
  | "analytics"
  | "advertising"
  | "unknown";

export interface AegisSettings {
  locale: LocaleCode;
  modules: ModuleToggles;
  modelBackend: ModelBackend;
  ollamaBaseUrl: string;
  ollamaModel: string;
  /** When true, cloud API keys may be used after PII gate approval. */
  allowCloudModels: boolean;
  cloudApiBaseUrl: string;
  /** EasyList-compatible remote rule pack URL (optional). */
  ruleSourceUrl: string;
  /** Hostnames allowed to bypass tracker blocking. */
  trackerWhitelist: string[];
  /** Cookie categories the user rejects (deleted when possible). */
  rejectedCookieCategories: CookieCategory[];
  /** Strip known tracking query params from navigations / links. */
  sanitizeLinkDecorations: boolean;
  /** Local false-positive feedback hostnames for phishing. */
  phishAllowlist: string[];
}

export const DEFAULT_SETTINGS: AegisSettings = {
  locale: "zh-CN",
  modules: {
    tracker: true,
    phish: true,
    privacyAi: true,
  },
  modelBackend: "mock",
  ollamaBaseUrl: "http://127.0.0.1:11434",
  ollamaModel: "llama3.2:3b",
  allowCloudModels: false,
  cloudApiBaseUrl: "",
  ruleSourceUrl: "",
  trackerWhitelist: [],
  rejectedCookieCategories: ["analytics", "advertising"],
  sanitizeLinkDecorations: true,
  phishAllowlist: [],
};

export interface BlockEvent {
  id: string;
  tabId: number;
  url: string;
  type: "ad" | "tracker" | "other";
  timestamp: number;
  ruleId?: number;
}

export interface TabStats {
  tabId: number;
  blocked: number;
  ads: number;
  trackers: number;
  lastUrl?: string;
}

export type PhishSeverity = "low" | "medium" | "high" | "critical";

export interface PhishReason {
  code: string;
  weight: number;
  detail?: string;
}

export interface PhishAssessment {
  score: number;
  severity: PhishSeverity;
  reasons: PhishReason[];
  shouldBlock: boolean;
  url: string;
}

export interface PageSnapshot {
  url: string;
  title: string;
  textSample: string;
  forms?: number;
  passwordFields?: number;
}

export type PiiKind =
  | "email"
  | "phone"
  | "idCard"
  | "creditCard"
  | "ssn"
  | "addressHint";

export interface PiiMatch {
  kind: PiiKind;
  value: string;
  start: number;
  end: number;
}

export interface PiiScanResult {
  matches: PiiMatch[];
  redacted: string;
  blocked: boolean;
}

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface SummarizeRequest {
  locale: Exclude<LocaleCode, "auto">;
  snapshot: PageSnapshot;
}

export interface SummarizeResult {
  summary: string;
  bullets: string[];
  risks: string[];
  backend: ModelBackend;
  modelReady: boolean;
}
