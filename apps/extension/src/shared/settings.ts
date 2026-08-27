import { DEFAULT_SETTINGS, type AegisSettings } from "@gcsa-aegis/core";

const KEY = "aegis.settings";
const FEEDBACK_KEY = "aegis.phishFeedback";

export async function loadSettings(): Promise<AegisSettings> {
  const data = await chrome.storage.local.get(KEY);
  return { ...DEFAULT_SETTINGS, ...(data[KEY] as Partial<AegisSettings> | undefined) };
}

export async function saveSettings(
  patch: Partial<AegisSettings>,
): Promise<AegisSettings> {
  const current = await loadSettings();
  const next = { ...current, ...patch };
  if (patch.modules) {
    next.modules = { ...current.modules, ...patch.modules };
  }
  await chrome.storage.local.set({ [KEY]: next });
  return next;
}

export async function loadPhishFeedback(): Promise<Record<string, "safe" | "phish">> {
  const data = await chrome.storage.local.get(FEEDBACK_KEY);
  return (data[FEEDBACK_KEY] as Record<string, "safe" | "phish">) ?? {};
}

export async function savePhishFeedback(
  feedback: Record<string, "safe" | "phish">,
): Promise<void> {
  await chrome.storage.local.set({ [FEEDBACK_KEY]: feedback });
}
