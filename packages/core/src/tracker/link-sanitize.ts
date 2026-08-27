import { TRACKING_QUERY_PARAMS } from "./builtin-rules.js";

export interface SanitizeResult {
  original: string;
  cleaned: string;
  removed: string[];
  changed: boolean;
}

export function sanitizeUrlDecorations(
  rawUrl: string,
  extraParams: readonly string[] = [],
): SanitizeResult {
  let url: URL;
  try {
    url = new URL(rawUrl);
  } catch {
    return {
      original: rawUrl,
      cleaned: rawUrl,
      removed: [],
      changed: false,
    };
  }

  const block = new Set(
    [...TRACKING_QUERY_PARAMS, ...extraParams].map((p) => p.toLowerCase()),
  );
  const removed: string[] = [];

  for (const key of [...url.searchParams.keys()]) {
    if (block.has(key.toLowerCase())) {
      removed.push(key);
      url.searchParams.delete(key);
    }
  }

  // Strip common hash trackers like #utm_...
  if (url.hash && /utm_|fbclid|gclid/i.test(url.hash)) {
    url.hash = "";
    removed.push("#tracking-hash");
  }

  const cleaned = url.toString();
  return {
    original: rawUrl,
    cleaned,
    removed,
    changed: cleaned !== rawUrl,
  };
}
