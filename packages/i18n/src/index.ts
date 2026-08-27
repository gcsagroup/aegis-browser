import en from "../locales/en.json";
import zhCN from "../locales/zh-CN.json";
import zhTW from "../locales/zh-TW.json";

export type MessageKey = keyof typeof zhCN;
export type SupportedLocale = "zh-CN" | "zh-TW" | "en";
export type LocalePreference = SupportedLocale | "auto";

const CATALOGS: Record<SupportedLocale, Record<string, string>> = {
  "zh-CN": zhCN,
  "zh-TW": zhTW,
  en,
};

export const DEFAULT_LOCALE: SupportedLocale = "zh-CN";

export function normalizeLocale(input?: string | null): SupportedLocale {
  if (!input) return DEFAULT_LOCALE;
  const lower = input.toLowerCase();
  if (lower === "zh-cn" || lower === "zh" || lower.startsWith("zh-hans")) {
    return "zh-CN";
  }
  if (
    lower === "zh-tw" ||
    lower === "zh-hk" ||
    lower === "zh-mo" ||
    lower.startsWith("zh-hant")
  ) {
    return "zh-TW";
  }
  if (lower.startsWith("en")) return "en";
  return DEFAULT_LOCALE;
}

export function resolveLocale(
  preference: LocalePreference,
  browserLocale?: string,
): SupportedLocale {
  if (preference === "auto") {
    return normalizeLocale(browserLocale);
  }
  return preference;
}

export function t(
  locale: SupportedLocale,
  key: MessageKey | string,
  vars?: Record<string, string | number>,
): string {
  const catalog = CATALOGS[locale] ?? CATALOGS[DEFAULT_LOCALE];
  let text = catalog[key] ?? CATALOGS.en[key] ?? key;
  if (vars) {
    for (const [k, v] of Object.entries(vars)) {
      text = text.replace(new RegExp(`\\{${k}\\}`, "g"), String(v));
    }
  }
  return text;
}

export function getCatalog(locale: SupportedLocale): Record<string, string> {
  return CATALOGS[locale];
}

export { en, zhCN, zhTW };
