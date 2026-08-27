import {
  BUILTIN_PHISH_HOSTS,
  PHISH_BRAND_KEYWORDS,
  SUSPICIOUS_PHISH_TLDS,
} from "./phish/builtin-hosts.js";
import {
  BUILTIN_TRACKER_HOSTS,
  FIRST_PARTY_COLLECT_PATHS,
  TRACKING_QUERY_PARAMS,
} from "./tracker/builtin-rules.js";

/** Portable policy snapshot consumed by the Chromium fork / tooling. */
export interface AegisPolicySnapshot {
  version: 1;
  generatedAt: string;
  source: "@gcsa-aegis/core";
  trackerHosts: string[];
  trackingQueryParams: string[];
  firstPartyCollectPaths: string[];
  phishHosts: string[];
  suspiciousTlds: string[];
  phishBrandKeywords: string[];
}

export function createPolicySnapshot(
  now: Date = new Date(),
): AegisPolicySnapshot {
  return {
    version: 1,
    generatedAt: now.toISOString(),
    source: "@gcsa-aegis/core",
    trackerHosts: [...BUILTIN_TRACKER_HOSTS],
    trackingQueryParams: [...TRACKING_QUERY_PARAMS],
    firstPartyCollectPaths: [...FIRST_PARTY_COLLECT_PATHS],
    phishHosts: [...BUILTIN_PHISH_HOSTS],
    suspiciousTlds: [...SUSPICIOUS_PHISH_TLDS],
    phishBrandKeywords: [...PHISH_BRAND_KEYWORDS],
  };
}
