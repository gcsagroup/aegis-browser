/** Built-in phishing seed hosts/paths for interstitial demos (not a full blocklist). */
export const BUILTIN_PHISH_HOSTS = [
  "testsafebrowsing.appspot.com/s/phishing",
  "paypal-secure-login.com",
  "appleid-verify-account.com",
  "microsoft-account-security.com",
  "ic1oud-login.com",
  "google-secure-signin.com",
  "aegis-phish-demo.test",
] as const;

/** Suspicious TLDs used by the lightweight phishing heuristic. */
export const SUSPICIOUS_PHISH_TLDS = [
  "zip",
  "mov",
  "tk",
  "ml",
  "ga",
  "cf",
  "gq",
  "top",
  "xyz",
  "icu",
  "click",
  "country",
] as const;

/** Brand tokens that look suspicious when embedded in non-official hosts. */
export const PHISH_BRAND_KEYWORDS = [
  "paypal",
  "apple",
  "microsoft",
  "google",
  "amazon",
  "facebook",
  "instagram",
  "netflix",
  "bank",
  "chase",
  "wellsfargo",
  "icloud",
  "outlook",
  "office365",
  "binance",
  "coinbase",
  "alipay",
  "taobao",
  "wechat",
] as const;
