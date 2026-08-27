import type {
  PageSnapshot,
  PhishAssessment,
  PhishReason,
  PhishSeverity,
} from "../types.js";
import {
  PHISH_BRAND_KEYWORDS,
  SUSPICIOUS_PHISH_TLDS,
} from "./builtin-hosts.js";

const SUSPICIOUS_TLDS = SUSPICIOUS_PHISH_TLDS;
const BRAND_KEYWORDS = PHISH_BRAND_KEYWORDS;

const SHORTENER_HOSTS = new Set([
  "bit.ly",
  "buff.ly",
  "cutt.ly",
  "is.gd",
  "ow.ly",
  "rb.gy",
  "rebrand.ly",
  "shorturl.at",
  "t.co",
  "tinyurl.com",
]);

const CREDENTIAL_PATH_WORDS = [
  "account",
  "auth",
  "confirm",
  "login",
  "password",
  "secure",
  "signin",
  "verify",
  "wallet",
];

/** Navigation-time block threshold; mirrored by chrome/common/aegis/phish_score.cc. */
export const PHISH_BLOCK_THRESHOLD = 55;

const URGENCY_PHRASES = [
  "verify your account",
  "confirm your identity",
  "suspend",
  "unusual activity",
  "act now",
  "password expired",
  "login immediately",
  "账户异常",
  "立即验证",
  "密码过期",
  "異常登入",
  "立即驗證",
];

function severityFromScore(score: number): PhishSeverity {
  if (score >= 80) return "critical";
  if (score >= 55) return "high";
  if (score >= 30) return "medium";
  return "low";
}

function looksLikeIpHost(host: string): boolean {
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(host) || host.includes(":");
}

function hasPunycode(host: string): boolean {
  return host.includes("xn--");
}

function normalizeLookalike(label: string): string {
  return label.replace(/0/g, "o").replace(/1/g, "i").replace(/3/g, "e")
    .replace(/4/g, "a").replace(/5/g, "s").replace(/7/g, "t");
}

function isEditDistanceAtMostOne(left: string, right: string): boolean {
  if (Math.abs(left.length - right.length) > 1) return false;
  if (left === right) return true;
  let i = 0;
  let j = 0;
  let edits = 0;
  while (i < left.length && j < right.length) {
    if (left[i] === right[j]) {
      i += 1;
      j += 1;
      continue;
    }
    edits += 1;
    if (edits > 1) return false;
    if (left.length > right.length) i += 1;
    else if (right.length > left.length) j += 1;
    else {
      i += 1;
      j += 1;
    }
  }
  return edits + Number(i < left.length || j < right.length) <= 1;
}

function registrableLabel(host: string): string {
  const labels = host.toLowerCase().split(".");
  const commonSecondLevelSuffixes = new Set([
    "co.uk", "com.au", "com.br", "com.cn", "com.hk", "co.jp", "co.kr",
  ]);
  const suffix = labels.slice(-2).join(".");
  const index = commonSecondLevelSuffixes.has(suffix) ? labels.length - 3 : labels.length - 2;
  return labels[Math.max(0, index)] ?? "";
}

function safeDecodePath(pathname: string): string {
  try {
    return decodeURIComponent(pathname);
  } catch {
    return pathname;
  }
}

function brandSpoofInHost(
  host: string,
): { brand: string; reason: "brand_spoof_host" | "brand_lookalike_host" } | null {
  const labels = host.toLowerCase().split(".");
  const sld = registrableLabel(host);
  for (const brand of BRAND_KEYWORDS) {
    // Official-looking apex (paypal.com / www.paypal.com)
    if (sld === brand) continue;
    const embedded = labels.some(
      (label) =>
        label === brand ||
        label.startsWith(`${brand}-`) ||
        label.endsWith(`-${brand}`) ||
        label.includes(`-${brand}-`),
    );
    if (embedded) return { brand, reason: "brand_spoof_host" };
    if (brand.length < 5) continue;
    const lookalike = labels.some((label) => {
      if (label.length < 5 || label === brand) return false;
      const normalized = normalizeLookalike(label);
      return normalized === brand || isEditDistanceAtMostOne(normalized, brand);
    });
    if (lookalike) return { brand, reason: "brand_lookalike_host" };
  }
  return null;
}

function brandInPath(pathname: string, host: string): string | null {
  const sld = registrableLabel(host);
  const tokens = safeDecodePath(pathname).toLowerCase().split(/[^a-z0-9]+/);
  for (const brand of BRAND_KEYWORDS) {
    if (brand !== sld && tokens.includes(brand)) return brand;
  }
  return null;
}

function finish(
  url: string,
  score: number,
  reasons: PhishReason[],
): PhishAssessment {
  const clamped = Math.min(100, score);
  return {
    score: clamped,
    severity: severityFromScore(clamped),
    reasons,
    shouldBlock: clamped >= PHISH_BLOCK_THRESHOLD,
    url,
  };
}

/**
 * URL-only phishing score used at navigation intercept (no page body).
 * Chromium `AssessPhishingUrl()` must stay in lockstep with this function.
 */
export function scorePhishingUrl(
  urlString: string,
  allowlist: string[] = [],
): PhishAssessment {
  let url: URL;
  try {
    url = new URL(urlString);
  } catch {
    return {
      score: 100,
      severity: "critical",
      reasons: [{ code: "invalid_url", weight: 100, detail: urlString }],
      shouldBlock: true,
      url: urlString,
    };
  }

  const host = url.hostname.toLowerCase();
  if (
    allowlist.some((h) => host === h.toLowerCase() || host.endsWith(`.${h.toLowerCase()}`))
  ) {
    return {
      score: 0,
      severity: "low",
      reasons: [{ code: "allowlisted", weight: 0 }],
      shouldBlock: false,
      url: urlString,
    };
  }

  const reasons: PhishReason[] = [];
  let score = 0;

  if (url.protocol === "http:") {
    score += 12;
    reasons.push({ code: "insecure_http", weight: 12 });
  }

  if (looksLikeIpHost(host)) {
    score += 35;
    reasons.push({ code: "ip_hostname", weight: 35, detail: host });
  }

  if (hasPunycode(host)) {
    score += 25;
    reasons.push({ code: "punycode_host", weight: 25, detail: host });
  }

  if (host.split(".").length >= 5) {
    score += 15;
    reasons.push({ code: "deep_subdomain", weight: 15, detail: host });
  }

  const tld = host.split(".").pop() ?? "";
  if ((SUSPICIOUS_TLDS as readonly string[]).includes(tld)) {
    score += 18;
    reasons.push({ code: "suspicious_tld", weight: 18, detail: tld });
  }

  const spoofBrand = brandSpoofInHost(host);
  if (spoofBrand) {
    const weight = spoofBrand.reason === "brand_lookalike_host" ? 40 : 30;
    score += weight;
    reasons.push({
      code: spoofBrand.reason,
      weight,
      detail: spoofBrand.brand,
    });
  }

  const pathBrand = brandInPath(url.pathname, host);
  if (pathBrand) {
    score += 15;
    reasons.push({ code: "brand_in_path", weight: 15, detail: pathBrand });
  }

  const path = safeDecodePath(url.pathname).toLowerCase();
  const credentialWord = CREDENTIAL_PATH_WORDS.find((word) =>
    path.split(/[^a-z0-9]+/).includes(word)
  );
  if (credentialWord) {
    score += 10;
    reasons.push({ code: "credential_path", weight: 10, detail: credentialWord });
  }

  if (SHORTENER_HOSTS.has(host)) {
    score += 15;
    reasons.push({ code: "shortened_url", weight: 15, detail: host });
  }

  if (url.username || urlString.includes("@")) {
    score += 20;
    reasons.push({ code: "at_symbol_trick", weight: 20 });
  }

  return finish(urlString, score, reasons);
}

/** Lightweight phishing risk scorer (PhishLang-inspired feature surface). */
export function assessPhishing(
  snapshot: PageSnapshot,
  allowlist: string[] = [],
): PhishAssessment {
  const urlOnly = scorePhishingUrl(snapshot.url, allowlist);
  if (
    urlOnly.reasons[0]?.code === "allowlisted" ||
    urlOnly.reasons[0]?.code === "invalid_url"
  ) {
    return urlOnly;
  }

  let score = urlOnly.score;
  const reasons = [...urlOnly.reasons];
  const spoofBrand =
    urlOnly.reasons.find((r) =>
      r.code === "brand_spoof_host" || r.code === "brand_lookalike_host"
    )?.detail ?? null;
  const isIp = urlOnly.reasons.some((r) => r.code === "ip_hostname");
  const isPunycode = urlOnly.reasons.some((r) => r.code === "punycode_host");
  let parsed: URL | null = null;
  try {
    parsed = new URL(snapshot.url);
  } catch {
    parsed = null;
  }
  const isHttp = parsed?.protocol === "http:";

  // URL-only already counted @; page path reuses that score.
  const text = `${snapshot.title}\n${snapshot.textSample}`.toLowerCase();
  for (const phrase of URGENCY_PHRASES) {
    if (text.includes(phrase.toLowerCase())) {
      score += 10;
      reasons.push({ code: "urgency_language", weight: 10, detail: phrase });
      break;
    }
  }

  const passwordFields = snapshot.passwordFields ?? 0;
  const forms = snapshot.forms ?? 0;
  const crossSiteFormActions = snapshot.crossSiteFormActions ?? 0;
  if (passwordFields > 0 && crossSiteFormActions > 0) {
    score += 45;
    reasons.push({
      code: "cross_site_credential_submit",
      weight: 45,
      detail: `crossSiteForms=${crossSiteFormActions}`,
    });
  } else if (passwordFields > 0 && (spoofBrand || isIp || isHttp || isPunycode)) {
    const weight = isPunycode ? 30 : 25;
    score += weight;
    reasons.push({
      code: "password_on_risky_origin",
      weight,
      detail: `passwordFields=${passwordFields}`,
    });
  } else if (passwordFields > 0 && forms > 0 && score >= 20) {
    score += 12;
    reasons.push({ code: "credential_form", weight: 12 });
  }


  if (passwordFields > 0) {
    const pageBrand = BRAND_KEYWORDS.find((brand) => text.includes(brand));
    if (pageBrand && !spoofBrand) {
      score += 15;
      reasons.push({ code: "brand_credential_page", weight: 15, detail: pageBrand });
    }
  }

  return finish(snapshot.url, score, reasons);
}

/** Tiny online-ish adjuster using local false-positive feedback (host → dampen). */
export function applyLocalFeedback(
  assessment: PhishAssessment,
  feedbackHosts: Record<string, "safe" | "phish">,
): PhishAssessment {
  let host: string;
  try {
    host = new URL(assessment.url).hostname.toLowerCase();
  } catch {
    return assessment;
  }

  const vote = feedbackHosts[host];
  if (vote === "safe") {
    const score = Math.max(0, assessment.score - 40);
    return {
      ...assessment,
      score,
      severity: severityFromScore(score),
      shouldBlock: score >= PHISH_BLOCK_THRESHOLD,
      reasons: [
        ...assessment.reasons,
        { code: "local_feedback_safe", weight: -40 },
      ],
    };
  }
  if (vote === "phish") {
    const score = Math.min(100, assessment.score + 40);
    return {
      ...assessment,
      score,
      severity: severityFromScore(score),
      shouldBlock: true,
      reasons: [
        ...assessment.reasons,
        { code: "local_feedback_phish", weight: 40 },
      ],
    };
  }
  return assessment;
}
