import type { ModelRuntimePort } from "@gcsa-aegis/core";

export function createMockModelRuntime(): ModelRuntimePort {
  return {
    async ready() {
      return true;
    },
    async chat(messages) {
      const last = messages[messages.length - 1]?.content ?? "";
      return JSON.stringify({
        summary: last.slice(0, 180),
        bullets: ["Mock backend active — switch to WebLLM or Ollama in Settings."],
        risks: [],
      });
    },
    async classify(text, labels) {
      const lower = text.toLowerCase();
      for (const label of labels) {
        if (lower.includes(label.toLowerCase())) return label;
      }
      return labels[0] ?? "unknown";
    },
  };
}
