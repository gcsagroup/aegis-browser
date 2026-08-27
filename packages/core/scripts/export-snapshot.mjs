#!/usr/bin/env node
/**
 * Export packages/core policy snapshot JSON by parsing TS source arrays.
 * No tsup/dist required.
 *
 * Usage: node packages/core/scripts/export-snapshot.mjs [out.json]
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const defaultOut = resolve(
  root,
  "../../apps/browser/overlay/third_party/aegis_policy/policy_snapshot.json",
);
const outPath = resolve(process.argv[2] ?? defaultOut);

function parseStringArray(source, exportName) {
  const re = new RegExp(
    `export const ${exportName}\\s*=\\s*\\[([\\s\\S]*?)\\]\\s*as const`,
  );
  const m = source.match(re);
  if (!m) {
    throw new Error(`Failed to parse ${exportName}`);
  }
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

const trackerSrc = readFileSync(
  resolve(root, "src/tracker/builtin-rules.ts"),
  "utf8",
);
const phishSrc = readFileSync(
  resolve(root, "src/phish/builtin-hosts.ts"),
  "utf8",
);

const snapshot = {
  version: 1,
  generatedAt: new Date().toISOString(),
  source: "@gcsa-aegis/core",
  trackerHosts: parseStringArray(trackerSrc, "BUILTIN_TRACKER_HOSTS"),
  trackingQueryParams: parseStringArray(trackerSrc, "TRACKING_QUERY_PARAMS"),
  firstPartyCollectPaths: parseStringArray(
    trackerSrc,
    "FIRST_PARTY_COLLECT_PATHS",
  ),
  phishHosts: parseStringArray(phishSrc, "BUILTIN_PHISH_HOSTS"),
  suspiciousTlds: parseStringArray(phishSrc, "SUSPICIOUS_PHISH_TLDS"),
  phishBrandKeywords: parseStringArray(phishSrc, "PHISH_BRAND_KEYWORDS"),
};

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, `${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
console.log(`Wrote ${outPath}`);
console.log(
  `  trackers=${snapshot.trackerHosts.length} phish=${snapshot.phishHosts.length} params=${snapshot.trackingQueryParams.length} collect=${snapshot.firstPartyCollectPaths.length}`,
);
