# Architecture

## Product principle

**GCSA-aegis 的产品是 Chromium fork 浏览器，不是扩展，也不是 Electron 壳。**

- 策略逻辑：`packages/core`（可单测、可复用）
- 产品宿主：`apps/browser`（fork Chromium + patches）
- 参考宿主：`apps/extension`（MV3 原型，验证策略；非发货形态）

```text
packages/core  ──►  Chromium AegisService / throttles / WebUI
       │
       └──►  apps/extension (prototype only)
```

## Data flow (fork)

1. **Fast path** — URLLoaderThrottle / 启发式规则（毫秒级）
2. **Slow path** — 本地模型摘要与解释（Utility process / sidecar）
3. **Privacy default** — 页面内容默认不上云；无遥测

## Packages

| Package | Role |
|---------|------|
| `core` | Pure TS policy, detectors, ports |
| `i18n` | zh-CN / zh-TW / en |
| `model-runtime` | mock / WebLLM / Ollama adapters |
| `ui` | Shared React primitives (WebUI can reuse patterns) |
| `browser` | Chromium fork scripts, GN args, patches |
| `extension` | Optional MV3 prototype |

## Chromium integration map

见 [apps/browser/docs/fork-architecture.md](../apps/browser/docs/fork-architecture.md)。
