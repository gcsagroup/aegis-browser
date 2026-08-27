# Chromium fork architecture

## Product shape

```text
┌─────────────────────────────────────────────┐
│  GCSA-aegis (forked Chromium)               │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │ Browser UI  │  │ chrome://aegis WebUI │  │
│  └──────┬──────┘  └──────────┬───────────┘  │
│         │                    │              │
│         ▼                    ▼              │
│  ┌──────────────────────────────────────┐   │
│  │ AegisBrowserService (C++)            │   │
│  │  - NetPolicy via URLLoaderThrottle   │   │
│  │  - StoragePolicy via CookieMonster   │   │
│  │  - FingerprintGuard (Blink/farbling) │   │
│  │  - PageSense / Safe browsing hooks   │   │
│  └──────────────────┬───────────────────┘   │
│                     │ rules / events        │
│                     ▼                       │
│  ┌──────────────────────────────────────┐   │
│  │ Policy worker (JS/WASM)              │   │
│  │  bundles packages/core logic         │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

Extension MV3 APIs are **not** the product surface. They remain a research harness under `apps/extension`.

## Port mapping (from packages/core)

| Port | Chromium integration point |
|------|----------------------------|
| `NetPolicy` | `network::URLLoaderThrottle` / request cancel |
| `StoragePolicy` | Cookie settings + deletion hooks |
| `PageSense` | RenderFrame observers / Prefetch |
| `ModelRuntime` | Utility process or local sidecar (Ollama) |
| `FingerprintGuard` | Blink canvas/audio/WebGL/WebGPU farbling |

## Patch plan (ordered)

1. **Stub service + flag** — `chrome/browser/aegis/` skeleton, `kAegisEnabled`
2. **Net throttle** — block hosts from rule snapshot (seed from built-in list)
3. **WebUI** — `chrome://aegis` for module toggles / locale
4. **Phish interstitial** — navigation throttle → interstitial with reason codes
5. **FingerprintGuard** — farbling seeded per profile/eTLD+1
6. **Bundle core** — ship serialized rules + optional WASM policy worker
7. **EasyList updater** — compile EasyList/EasyPrivacy at runtime, push host tables to renderer
8. **First-party tracking** — strip tracking query params on navigations; delete analytics/advertising cookies
9. **CNAME + bounce tracking** — uncloak DNS CNAME tracker aliases on subresources; immediately clear cookies on BTM bounce hops that match tracker rules
10. **Phish URL heuristics** — port `scorePhishingUrl()` to C++; show reason codes on the interstitial
11. **Phish page-sense** — after DOMContentLoaded, count password fields / scan copy and reload into the interstitial if the blended score crosses the threshold
12. **Policy worker + Privacy AI** — bundle `packages/core` as JS, run in a jitless gin isolate; `chrome://aegis` summarizes the current tab (heuristic, optional loopback Ollama)
13. **WebGPU farbling** — stabilize `GPUAdapter.info` strings and a few numeric limits (`maxBufferSize`, workgroup storage, 3D texture, subgroup sizes) per eTLD+1; never raise hardware, never go below spec minima, keep subgroup sizes as powers of two
14. **Android** — same pin, `chrome_public_apk`, package `app.gcsa.aegis`; build on Linux only. Sideload first; Play listing identity reserved. No iOS engine fork.

## Why not Electron

Electron cannot own URLLoader/CookieMonster/Blink fingerprint surfaces.  
A privacy/security browser that matches the research roadmap requires engine patches.
