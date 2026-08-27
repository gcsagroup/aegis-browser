/**
 * Execution ports — implemented by apps/extension today and apps/browser later.
 * Core never imports chrome.* or Blink APIs.
 */

import type { AegisSettings, BlockEvent, CookieCategory } from "./types.js";

export interface NetRule {
  id: number;
  priority?: number;
  action: "block" | "allow" | "upgradeScheme";
  urlFilter: string;
  resourceTypes?: string[];
  domains?: string[];
  excludedDomains?: string[];
}

export interface NetPolicyPort {
  applyRules(rules: NetRule[]): Promise<void>;
  clearRules(ids?: number[]): Promise<void>;
  onBlocked?(handler: (event: BlockEvent) => void): void;
}

export interface StorageCookie {
  name: string;
  value: string;
  domain: string;
  path: string;
  secure: boolean;
  httpOnly: boolean;
  sameSite?: string;
  expirationDate?: number;
  session: boolean;
}

export interface StoragePolicyPort {
  listCookies(url?: string): Promise<StorageCookie[]>;
  removeCookie(cookie: StorageCookie): Promise<void>;
  classifyCookie?(cookie: StorageCookie): CookieCategory;
}

export interface PageSensePort {
  getSnapshot(tabId: number): Promise<{
    url: string;
    title: string;
    textSample: string;
    forms: number;
    passwordFields: number;
  }>;
  sanitizeLinks?(tabId: number, params: string[]): Promise<number>;
}

export interface ModelRuntimePort {
  ready(): Promise<boolean>;
  chat(messages: { role: string; content: string }[]): Promise<string>;
  classify?(text: string, labels: string[]): Promise<string>;
}

export interface FingerprintGuardPort {
  /** Extension: limited spoofing; Browser fork: engine-level farbling. */
  applyProfile(profileId: string): Promise<void>;
  clear(): Promise<void>;
}

export interface SettingsPort {
  get(): Promise<AegisSettings>;
  set(patch: Partial<AegisSettings>): Promise<AegisSettings>;
  subscribe?(listener: (settings: AegisSettings) => void): () => void;
}

export interface AegisPorts {
  net: NetPolicyPort;
  storage: StoragePolicyPort;
  page: PageSensePort;
  model: ModelRuntimePort;
  fingerprint?: FingerprintGuardPort;
  settings: SettingsPort;
}
