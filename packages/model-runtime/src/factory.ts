import type { ModelBackend, ModelRuntimePort } from "@gcsa-aegis/core";
import { createMockModelRuntime } from "./mock.js";
import { createOllamaRuntime } from "./ollama.js";
import { createWebLLMRuntime } from "./webllm.js";

export interface RuntimeFactoryOptions {
  backend: ModelBackend;
  ollamaBaseUrl?: string;
  ollamaModel?: string;
  webllmModelId?: string;
}

export function createModelRuntime(options: RuntimeFactoryOptions): ModelRuntimePort {
  switch (options.backend) {
    case "ollama":
      return createOllamaRuntime({
        baseUrl: options.ollamaBaseUrl ?? "http://127.0.0.1:11434",
        model: options.ollamaModel ?? "llama3.2:3b",
      });
    case "webllm":
      return createWebLLMRuntime({ modelId: options.webllmModelId });
    case "mock":
    default:
      return createMockModelRuntime();
  }
}
