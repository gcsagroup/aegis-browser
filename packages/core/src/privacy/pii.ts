import type { PiiKind, PiiMatch, PiiScanResult } from "../types.js";

interface PatternDef {
  kind: PiiKind;
  regex: RegExp;
  mask: (m: string) => string;
}

const PATTERNS: PatternDef[] = [
  {
    kind: "secret",
    regex:
      /\b(?:bearer\s+[A-Z0-9._~+\/-]{8,}={0,2}|eyJ[A-Z0-9_-]{5,}\.[A-Z0-9_-]{5,}\.[A-Z0-9_-]{5,}|AKIA[0-9A-Z]{16}|(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?|secret|password|passwd|token)\s*[:=]\s*(?:bearer\s+)?["']?[A-Z0-9._~+\/-]{8,}={0,2}["']?)/gi,
    mask: () => "[REDACTED_SECRET]",
  },
  {
    kind: "email",
    regex: /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi,
    mask: (m) => {
      const [user, domain] = m.split("@");
      return `${user.slice(0, 1)}***@${domain}`;
    },
  },
  {
    kind: "phone",
    regex: /(?<!\d)(?:\+?86[-\s]?)?1[3-9]\d{9}(?!\d)|\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/g,
    mask: (m) => `${m.slice(0, 3)}****${m.slice(-2)}`,
  },
  {
    kind: "idCard",
    regex: /\b[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx]\b/g,
    mask: (m) => `${m.slice(0, 4)}**********${m.slice(-4)}`,
  },
  {
    kind: "ssn",
    regex: /\b\d{3}-\d{2}-\d{4}\b/g,
    mask: () => "***-**-****",
  },
  {
    kind: "creditCard",
    regex: /\b(?:\d[ -]*?){13,19}\b/g,
    mask: (m) => {
      const digits = m.replace(/\D/g, "");
      if (digits.length < 13 || digits.length > 19) return m;
      return `${digits.slice(0, 4)} **** **** ${digits.slice(-4)}`;
    },
  },
  {
    kind: "addressHint",
    regex: /\b\d{1,5}\s+[\w.\u4e00-\u9fff]+(?:\s+[\w.\u4e00-\u9fff]+){0,4}\s+(?:street|st|road|rd|ave|avenue|blvd|lane|ln|drive|dr|路|街|巷|号)\b/gi,
    mask: () => "[REDACTED_ADDRESS]",
  },
];

function luhnOk(num: string): boolean {
  let sum = 0;
  let alt = false;
  for (let i = num.length - 1; i >= 0; i--) {
    let n = Number(num[i]);
    if (alt) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
    alt = !alt;
  }
  return sum % 10 === 0;
}

export function scanPii(text: string): PiiScanResult {
  const matches: PiiMatch[] = [];

  for (const pattern of PATTERNS) {
    pattern.regex.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = pattern.regex.exec(text)) !== null) {
      const value = m[0];
      if (pattern.kind === "creditCard") {
        const digits = value.replace(/\D/g, "");
        if (digits.length < 13 || digits.length > 19 || !luhnOk(digits)) {
          continue;
        }
      }
      matches.push({
        kind: pattern.kind,
        value,
        start: m.index,
        end: m.index + value.length,
      });
    }
  }

  matches.sort((a, b) => a.start - b.start);
  // Deduplicate overlaps (prefer earlier / longer)
  const deduped: PiiMatch[] = [];
  let cursor = -1;
  for (const match of matches) {
    if (match.start < cursor) continue;
    deduped.push(match);
    cursor = match.end;
  }

  let redacted = text;
  // Replace from end to keep indices stable
  for (let i = deduped.length - 1; i >= 0; i--) {
    const match = deduped[i];
    const def = PATTERNS.find((p) => p.kind === match.kind)!;
    redacted =
      redacted.slice(0, match.start) +
      def.mask(match.value) +
      redacted.slice(match.end);
  }

  return {
    matches: deduped,
    redacted,
    blocked: deduped.length > 0,
  };
}

export function gateOutboundText(
  text: string,
  userApproved: boolean,
): { allowed: boolean; payload: string; scan: PiiScanResult } {
  const scan = scanPii(text);
  if (!scan.blocked) {
    return { allowed: true, payload: text, scan };
  }
  if (userApproved) {
    return { allowed: true, payload: scan.redacted, scan };
  }
  return { allowed: false, payload: scan.redacted, scan };
}
