import type { CookieCategory } from "../types.js";
import type { StorageCookie } from "../ports.js";

/** High-confidence names (CookieBlock-style exact table). */
const EXACT_ADVERTISING = new Set([
  "ide",
  "dsid",
  "anid",
  "fr",
  "_fbp",
  "_fbc",
  "personalization_id",
  "muc_ads",
  "muid",
  "muidb",
  "tuuid",
  "tuuid_lu",
  "cto_bundle",
  "_gcl_au",
  "_gcl_aw",
]);

const EXACT_ANALYTICS = new Set([
  "_ga",
  "_gid",
  "_gat",
  "__utma",
  "__utmb",
  "__utmc",
  "__utmz",
  "__utmt",
  "_hjid",
  "ajs_anonymous_id",
  "ajs_user_id",
  "ajs_group_id",
  "_clck",
  "_clsk",
  "_pk_id",
  "_pk_ses",
  "_ym_uid",
  "_ym_d",
  "_vwo_uuid",
]);

const PREFIX_ADVERTISING = ["_gcl_"];
const PREFIX_ANALYTICS = ["_ga_", "_gat_", "__utm", "mp_", "_hj", "amp_"];

const AD_NETWORK_DOMAINS = [
  "doubleclick.net",
  "googlesyndication.com",
  "adnxs.com",
  "criteo.com",
  "taboola.com",
  "outbrain.com",
  "amazon-adsystem.com",
  "adsrvr.org",
  "pubmatic.com",
  "casalemedia.com",
  "scorecardresearch.com",
  "quantserve.com",
  "moatads.com",
  "openx.net",
  "rubiconproject.com",
];

const AD_HINTS = ["ads", "ad_", "_ad", "advert", "doubleclick", "personalization_id", "muc_ads"];

const ANALYTICS_HINTS = [
  "_ga",
  "_gid",
  "_gat",
  "mixpanel",
  "amplitude",
  "hotjar",
  "optimizely",
  "segment",
  "analytics",
];

const FUNCTIONALITY_HINTS = [
  "lang",
  "locale",
  "theme",
  "timezone",
  "prefs",
  "preference",
  "sidebar",
  "consent",
  "cookie_consent",
];

const NECESSARY_HINTS = [
  "session",
  "sess",
  "csrf",
  "xsrf",
  "auth",
  "token",
  "sid",
  "login",
  "secure",
  "__host-",
  "__secure-",
];

function scoreHints(blob: string, hints: string[]): number {
  return hints.reduce((acc, h) => (blob.includes(h) ? acc + 1 : acc), 0);
}

function hasPrefix(name: string, prefixes: string[]): boolean {
  return prefixes.some((p) => name.startsWith(p));
}

const LOGIN_PRESERVED_NAMES = new Set([
  "c_user",
  "datr",
  "sb",
  "xs",
  "presence",
]);

const LOGIN_PRESERVED_DOMAINS = ["facebook.com", "messenger.com"];

export function isAdNetworkDomain(domain: string): boolean {
  const d = (domain.startsWith(".") ? domain.slice(1) : domain).toLowerCase();
  return AD_NETWORK_DOMAINS.some((n) => d === n || d.endsWith(`.${n}`));
}

export function isLoginPreservedCookie(name: string, domain: string): boolean {
  const n = name.toLowerCase();
  if (!LOGIN_PRESERVED_NAMES.has(n)) {
    return false;
  }
  const d = domain.startsWith(".") ? domain.slice(1).toLowerCase() : domain.toLowerCase();
  return LOGIN_PRESERVED_DOMAINS.some((host) => d === host || d.endsWith(`.${host}`));
}

export function cookieNameHitsTrackingTable(name: string): boolean {
  const n = name.toLowerCase();
  return (
    EXACT_ADVERTISING.has(n) ||
    EXACT_ANALYTICS.has(n) ||
    hasPrefix(n, PREFIX_ADVERTISING) ||
    hasPrefix(n, PREFIX_ANALYTICS)
  );
}

/** Heuristic cookie purpose classifier (CookieBlock-inspired lookup + hints). */
export function classifyCookie(cookie: StorageCookie): CookieCategory {
  const name = cookie.name.toLowerCase();
  const domain = cookie.domain.toLowerCase();

  if (isLoginPreservedCookie(name, domain)) {
    return "necessary";
  }
  if (EXACT_ADVERTISING.has(name) || hasPrefix(name, PREFIX_ADVERTISING)) {
    return "advertising";
  }
  if (EXACT_ANALYTICS.has(name) || hasPrefix(name, PREFIX_ANALYTICS)) {
    return "analytics";
  }
  if (isAdNetworkDomain(domain)) {
    return "advertising";
  }

  const blob = `${name} ${domain}`;
  const scores: Record<Exclude<CookieCategory, "unknown">, number> = {
    necessary: scoreHints(blob, NECESSARY_HINTS),
    functionality: scoreHints(blob, FUNCTIONALITY_HINTS),
    analytics: scoreHints(blob, ANALYTICS_HINTS),
    advertising: scoreHints(blob, AD_HINTS),
  };

  let best: CookieCategory = "unknown";
  let bestScore = 0;
  for (const [cat, score] of Object.entries(scores) as [
    Exclude<CookieCategory, "unknown">,
    number,
  ][]) {
    if (score > bestScore) {
      best = cat;
      bestScore = score;
    }
  }

  if (bestScore === 0) {
    return "unknown";
  }

  return best;
}

export function shouldRejectCookie(
  category: CookieCategory,
  rejected: CookieCategory[],
): boolean {
  if (category === "necessary") return false;
  return rejected.includes(category);
}
