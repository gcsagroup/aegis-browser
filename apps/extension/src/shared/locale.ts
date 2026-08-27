import { resolveLocale, t, type SupportedLocale } from "@gcsa-aegis/i18n";
import { sendMessage } from "./messages";

export async function getUiLocale(): Promise<SupportedLocale> {
  const res = await sendMessage<{ ok: true; locale: string }>({
    type: "GET_LOCALE",
  });
  if (res.ok) {
    return resolveLocale(res.locale as SupportedLocale, chrome.i18n.getUILanguage());
  }
  return resolveLocale("zh-CN");
}

export function translate(locale: SupportedLocale, key: string): string {
  return t(locale, key);
}
