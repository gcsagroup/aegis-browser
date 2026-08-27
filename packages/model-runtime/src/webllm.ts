import type { ModelRuntimePort } from "@gcsa-aegis/core";

/**
 * WebLLM adapter.
 * Loads @mlc-ai/web-llm dynamically when available in the extension bundle.
 * Falls back to not-ready if the dependency or WebGPU is missing.
 */
export interface WebLLMOptions {
  modelId?: string;
}

type WebLLMEngine = {
  chat: {
    completions: {
      create: (req: {
        messages: { role: string; content: string }[];
        stream?: boolean;
      }) => Promise<{ choices: { message: { content: string } }[] }>;
    };
  };
};

export function createWebLLMRuntime(options: WebLLMOptions = {}): ModelRuntimePort {
  let engine: WebLLMEngine | null = null;
  let initError: string | null = null;
  let initPromise: Promise<void> | null = null;

  const modelId = options.modelId ?? "Llama-3.2-1B-Instruct-q4f16_1-MLC";

  async function ensure(): Promise<void> {
    if (engine || initError) return;
    if (initPromise) return initPromise;
    initPromise = (async () => {
      try {
        // Optional peer: resolve at runtime without a hard dependency.
        const dynamicImport = new Function(
          "m",
          "return import(m)",
        ) as (m: string) => Promise<{ CreateMLCEngine?: (id: string) => Promise<WebLLMEngine> }>;
        const mod = await dynamicImport("@mlc-ai/web-llm").catch(() => null);
        if (!mod || typeof mod.CreateMLCEngine !== "function") {
          initError = "webllm_not_installed";
          return;
        }
        engine = await mod.CreateMLCEngine(modelId);
      } catch (err) {
        initError = err instanceof Error ? err.message : "webllm_init_failed";
      }
    })();
    return initPromise;
  }

  return {
    async ready() {
      await ensure();
      return engine !== null;
    },
    async chat(messages) {
      await ensure();
      if (!engine) {
        throw new Error(initError ?? "WebLLM not ready");
      }
      const result = await engine.chat.completions.create({
        messages,
        stream: false,
      });
      return result.choices[0]?.message?.content ?? "";
    },
  };
}
