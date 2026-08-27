import type { NetRule } from "../ports.js";

/** Built-in blocklist for MVP demos (common ad/tracker hosts). */
export const BUILTIN_TRACKER_HOSTS = [
  "doubleclick.net",
  "googleadservices.com",
  "googlesyndication.com",
  "google-analytics.com",
  "googletagmanager.com",
  "facebook.net",
  "facebook.com/tr",
  "connect.facebook.net",
  "adservice.google.com",
  "adsystem.amazon.com",
  "amazon-adsystem.com",
  "adnxs.com",
  "adsrvr.org",
  "advertising.com",
  "scorecardresearch.com",
  "hotjar.com",
  "clarity.ms",
  "taboola.com",
  "outbrain.com",
  "criteo.com",
  "pubmatic.com",
  "openx.net",
  "rubiconproject.com",
  "moatads.com",
  "quantserve.com",
  "chartbeat.com",
  "segment.io",
  "segment.com",
  "mixpanel.com",
  "amplitude.com",
  "sentry-cdn.com",
] as const;

export function buildBuiltinNetRules(startId = 1000): NetRule[] {
  return BUILTIN_TRACKER_HOSTS.map((host, index) => ({
    id: startId + index,
    priority: 1,
    action: "block" as const,
    urlFilter: `||${host}^`,
    resourceTypes: [
      "script",
      "image",
      "xmlhttprequest",
      "sub_frame",
      "ping",
      "media",
      "font",
      "websocket",
      "other",
    ],
  }));
}

/** Query params commonly used for cross-site tracking (PURL-inspired). */
export const TRACKING_QUERY_PARAMS = [
  "fbclid",
  "gclid",
  "gclsrc",
  "dclid",
  "msclkid",
  "mc_eid",
  "mc_cid",
  "igshid",
  "twclid",
  "ttclid",
  "yclid",
  "ybclid",
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_term",
  "utm_content",
  "utm_id",
  "_ga",
  "_gl",
  "vero_id",
  "wickedid",
  "oly_anon_id",
  "oly_enc_id",
  "gbraid",
  "wbraid",
  "gad_source",
  "gad_campaignid",
  "srsltid",
  "li_fat_id",
  "_hsenc",
  "_hsmi",
  "mkt_tok",
] as const;

/** First-party copies of known measurement endpoints (SST / first-party tags). */
export const FIRST_PARTY_COLLECT_PATHS = [
  "/g/collect",
  "/j/collect",
  "/r/collect",
  "/ccm/collect",
  "/amp/collect",
  "/gtag/js",
  "/gtm.js",
  "/analytics.js",
  "/ga.js",
  "/fbevents.js",
  "/fbevents.php",
  "/ag/g/c",
  "/sgtm/g/collect",
  "/_sgtm/g/collect",
] as const;

function looksLikeGa4CollectQuery(url: URL): boolean {
  const version = url.searchParams.get("v");
  const tid = (url.searchParams.get("tid") ?? "").toLowerCase();
  const en = url.searchParams.get("en");
  const cid = url.searchParams.get("cid");
  return (
    version === "2" &&
    (tid.startsWith("g-") || tid.startsWith("gt-")) &&
    !!en &&
    !!cid
  );
}

export function isFirstPartyCollectPath(pathname: string): boolean {
  const path = pathname.toLowerCase();
  return FIRST_PARTY_COLLECT_PATHS.some((rule) => pathMatchesCollect(path, rule));
}

function pathMatchesCollect(path: string, rule: string): boolean {
  if (path === rule || path.startsWith(`${rule}/`)) {
    return true;
  }
  return (rule.endsWith(".js") || rule.endsWith(".php")) && path.endsWith(rule);
}

export function isFirstPartyCollectUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      return false;
    }
    return (
      isFirstPartyCollectPath(parsed.pathname) || looksLikeGa4CollectQuery(parsed)
    );
  } catch {
    return false;
  }
}
