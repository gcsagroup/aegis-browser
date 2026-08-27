/** EasyList / EasyPrivacy compiler used by the Chromium filter-list updater. */

export const DEFAULT_FILTER_LIST_URLS = [
  "https://easylist.to/easylist/easylist.txt",
  "https://easylist.to/easylist/easyprivacy.txt",
] as const;

export interface CompiledFilterList {
  version: 1;
  source: string;
  generatedAt: string;
  /** Host-only rules (`||example.com^`). */
  hosts: string[];
  /** Host+path rules (`||example.com/ads`). */
  pathRules: string[];
  /** Exception hosts (`@@||example.com^`). */
  exceptions: string[];
  parsed: number;
  skipped: number;
}

const COSMETIC_RE = /##|#@#|#\?#/;

function isPlausibleHost(host: string): boolean {
  if (host.length < 3 || host.length > 253) {
    return false;
  }
  if (!host.includes(".")) {
    return false;
  }
  if (host.startsWith(".") || host.endsWith(".") || host.includes("..")) {
    return false;
  }
  return /^[a-z0-9.-]+$/i.test(host);
}

/**
 * Parse one EasyList network rule into a host or host/path token.
 * Cosmetic, regex, and site-specific (`domain=`) rules are skipped.
 */
export function parseEasyListRule(
  line: string,
): { kind: "block" | "exception"; rule: string; path: boolean } | null {
  let s = line.trim();
  if (!s || s.startsWith("!") || s.startsWith("[") || s.startsWith("#")) {
    return null;
  }
  if (COSMETIC_RE.test(s)) {
    return null;
  }

  let kind: "block" | "exception" = "block";
  if (s.startsWith("@@")) {
    kind = "exception";
    s = s.slice(2);
  }
  if (!s.startsWith("||")) {
    return null;
  }
  s = s.slice(2);

  const dollar = s.indexOf("$");
  if (dollar >= 0) {
    const options = s.slice(dollar + 1).split(",");
    s = s.slice(0, dollar);
    if (
      options.some(
        (opt) => opt.startsWith("domain=") || opt.startsWith("~domain="),
      )
    ) {
      return null;
    }
  }

  if (s.endsWith("^")) {
    s = s.slice(0, -1);
  }
  if (s.includes("*") || s.includes("^") || s.includes("|")) {
    return null;
  }

  const slash = s.indexOf("/");
  const host = (slash < 0 ? s : s.slice(0, slash)).toLowerCase();
  if (!isPlausibleHost(host)) {
    return null;
  }
  const path = slash < 0 ? "" : s.slice(slash);
  return { kind, rule: path ? `${host}${path}` : host, path: Boolean(path) };
}

export function compileEasyList(
  text: string,
  source = "easylist",
  now: Date = new Date(),
): CompiledFilterList {
  const hosts = new Set<string>();
  const pathRules = new Set<string>();
  const exceptions = new Set<string>();
  let parsed = 0;
  let skipped = 0;

  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    const parsedRule = parseEasyListRule(trimmed);
    if (!parsedRule) {
      skipped += 1;
      continue;
    }
    parsed += 1;
    if (parsedRule.kind === "exception") {
      const host = parsedRule.rule.split("/")[0] ?? parsedRule.rule;
      exceptions.add(host);
      continue;
    }
    if (parsedRule.path) {
      pathRules.add(parsedRule.rule);
    } else {
      hosts.add(parsedRule.rule);
    }
  }

  const sort = (values: Set<string>) => [...values].sort();
  return {
    version: 1,
    source,
    generatedAt: now.toISOString(),
    hosts: sort(hosts),
    pathRules: sort(pathRules),
    exceptions: sort(exceptions),
    parsed,
    skipped,
  };
}

export function mergeCompiledFilterLists(
  lists: CompiledFilterList[],
  source: string,
  now: Date = new Date(),
): CompiledFilterList {
  const hosts = new Set<string>();
  const pathRules = new Set<string>();
  const exceptions = new Set<string>();
  let parsed = 0;
  let skipped = 0;
  for (const list of lists) {
    for (const host of list.hosts) {
      hosts.add(host);
    }
    for (const rule of list.pathRules) {
      pathRules.add(rule);
    }
    for (const host of list.exceptions) {
      exceptions.add(host);
    }
    parsed += list.parsed;
    skipped += list.skipped;
  }
  return {
    version: 1,
    source,
    generatedAt: now.toISOString(),
    hosts: [...hosts].sort(),
    pathRules: [...pathRules].sort(),
    exceptions: [...exceptions].sort(),
    parsed,
    skipped,
  };
}
