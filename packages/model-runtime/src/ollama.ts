import type { ModelRuntimePort } from "@gcsa-aegis/core";

export interface OllamaOptions {
  baseUrl: string;
  model: string;
}

export function createOllamaRuntime(options: OllamaOptions): ModelRuntimePort {
  const base = options.baseUrl.replace(/\/$/, "");

  return {
    async ready() {
      try {
        const res = await fetch(`${base}/api/tags`, { method: "GET" });
        return res.ok;
      } catch {
        return false;
      }
    },
    async chat(messages) {
      const res = await fetch(`${base}/api/chat`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          model: options.model,
          stream: false,
          messages: messages.map((m) => ({
            role: m.role,
            content: m.content,
          })),
        }),
      });
      if (!res.ok) {
        throw new Error(`Ollama error: ${res.status}`);
      }
      const data = (await res.json()) as {
        message?: { content?: string };
      };
      return data.message?.content ?? "";
    },
  };
}
