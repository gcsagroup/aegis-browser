import { sanitizeUrlDecorations } from "@gcsa-aegis/core";
import { sendMessage } from "../shared/messages";

function collectSnapshot() {
  const text = document.body?.innerText?.slice(0, 8000) ?? "";
  return {
    url: location.href,
    title: document.title,
    textSample: text,
    forms: document.querySelectorAll("form").length,
    passwordFields: document.querySelectorAll('input[type="password"]').length,
  };
}

async function reportSnapshot() {
  try {
    await sendMessage({
      type: "PAGE_SNAPSHOT_RESULT",
      tabId: -1,
      snapshot: collectSnapshot(),
    });
  } catch {
    /* ignore */
  }
}

function sanitizeCurrentUrl() {
  const result = sanitizeUrlDecorations(location.href);
  if (result.changed && result.cleaned !== location.href) {
    history.replaceState(null, "", result.cleaned);
  }
}

function bindLinkSanitizer() {
  document.addEventListener(
    "click",
    (event) => {
      const target = event.target as HTMLElement | null;
      const anchor = target?.closest?.("a[href]") as HTMLAnchorElement | null;
      if (!anchor) return;
      const cleaned = sanitizeUrlDecorations(anchor.href);
      if (cleaned.changed) {
        anchor.href = cleaned.cleaned;
      }
    },
    true,
  );
}

void (async () => {
  sanitizeCurrentUrl();
  bindLinkSanitizer();
  // Delay content assessment so title/body exist
  setTimeout(() => {
    void reportSnapshot();
  }, 600);
})();

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "COLLECT_SNAPSHOT") {
    sendResponse({ ok: true, snapshot: collectSnapshot() });
    return true;
  }
  return false;
});
