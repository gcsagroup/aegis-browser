import type { NetRule } from "@gcsa-aegis/core";

/**
 * Fetch a simple remote host list (one hostname per line, # comments allowed)
 * and convert to DNR-oriented NetRules. Caps to MV3-friendly size.
 */
export async function fetchRemoteHostRules(
  url: string,
  startId = 5000,
  limit = 2000,
): Promise<NetRule[]> {
  if (!url) return [];
  const res = await fetch(url);
  if (!res.ok) throw new Error(`rule_fetch_${res.status}`);
  const text = await res.text();
  const hosts = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith("#") && !line.includes(" "))
    .map((line) => line.replace(/^\|\|/, "").replace(/\^$/, ""))
    .slice(0, limit);

  return hosts.map((host, index) => ({
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
      "other",
    ],
  }));
}
