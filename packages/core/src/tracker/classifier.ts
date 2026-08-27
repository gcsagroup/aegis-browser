import { buildBuiltinNetRules } from "./builtin-rules.js";
import type { NetRule } from "../ports.js";

export function hostnameFromUrl(url: string): string | null {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

export function isWhitelisted(url: string, whitelist: string[]): boolean {
  const host = hostnameFromUrl(url);
  if (!host) return false;
  return whitelist.some(
    (entry) => host === entry.toLowerCase() || host.endsWith(`.${entry.toLowerCase()}`),
  );
}

export function classifyBlockedUrl(url: string): "ad" | "tracker" | "other" {
  const lower = url.toLowerCase();
  if (
    /doubleclick|googlesyndication|adservice|adnxs|amazon-adsystem|criteo|taboola|outbrain|adsrvr|advertising\.com/.test(
      lower,
    )
  ) {
    return "ad";
  }
  if (
    /google-analytics|googletagmanager|scorecardresearch|hotjar|clarity|mixpanel|amplitude|segment|facebook\.net|connect\.facebook/.test(
      lower,
    )
  ) {
    return "tracker";
  }
  return "other";
}

export function rulesForSettings(whitelist: string[]): NetRule[] {
  const rules = buildBuiltinNetRules(1000);
  if (whitelist.length === 0) return rules;
  return rules.map((rule) => ({
    ...rule,
    excludedDomains: whitelist.map((h) => h.toLowerCase()),
  }));
}
