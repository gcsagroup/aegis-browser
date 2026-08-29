[**English**](./fork-architecture.md) | [简体中文](./fork-architecture.zh-CN.md) | [繁體中文](./fork-architecture.zh-TW.md)

# Chromium fork architecture

GCSA-aegis is a Chromium fork. The browser, network, storage, Blink, and selected V8 integration points are the product; there is no separate Extension or Electron deliverable.

## Status boundary

- Current combined source: **67 top-level Chromium patches + 2 nested V8 patches**.
- The 57-patch diagnostic manifest and 65-patch Agent acceptance are historical snapshots; neither binds or qualifies the 67-patch head.
- The combined source still needs a fresh exact replay, identity-bound build, and affected runtime acceptance. There is no product-signed, notarized, installed, or published release.
- Android has not been built from the current source.

## Product shape

```text
┌──────────────────────────────────────────────┐
│ GCSA-aegis Chromium fork                     │
│                                              │
│ Browser UI / chrome://aegis / native pages  │
│                    │                         │
│                    ▼                         │
│ Aegis browser services and policy bridge     │
│   ├─ navigation and network controls         │
│   ├─ cookie, bounce, and phishing controls   │
│   ├─ download and summary orchestration      │
│   └─ local event and preference handling     │
│                    │                         │
│                    ▼                         │
│ Blink protections + optional V8 research     │
└──────────────────────────────────────────────┘
```

## Architecture principles

1. Policy models and generated inputs originate in `packages/core`.
2. Enforcement that requires browser or engine ownership lives in Chromium C++ and Blink.
3. Generated snapshots and the embedded policy worker bridge TypeScript policy into the fork.
4. User-facing settings live in native Chromium surfaces such as `chrome://aegis`, `chrome://downloads`, and `chrome://settings/downloads`.
5. Local evidence, a successful build, and a distributable release are separate states.

## Integration map

| Capability | Primary integration | Current boundary |
|---|---|---|
| Network and navigation | URL loader and navigation throttles | Requires fresh replay and representative browser regression |
| Storage protection | Cookie and bounce hooks | Must preserve expected first-party login behavior |
| Phishing protection | URL/page signals and native interstitial | Local detection does not establish universal coverage |
| Fingerprint protection | Blink Canvas, Audio, WebGL, and WebGPU hooks | Reduces selected stable surfaces; does not prevent all fingerprinting |
| Downloads | Chromium download UI plus isolated torrent service | HTTPS tracker support and release qualification remain gated |
| Page summaries | Heuristic path and user-configured compatible APIs | Remote use requires redaction and confirmation; Android page capture is unavailable |
| Browser Agent | Policy broker, fixed tool registry, Actor/side panel/WebUI, task store | Model cannot expand scope or bypass approvals; final purchase requires user takeover |
| MinerGuard | Browser/renderer signals and reporting | Observe-only; does not block execution or traffic |
| Bytecode shadow | Disabled-by-default nested V8 instrumentation | Research-only; historical identities cover both V8 patches, but neither qualifies the current 67-patch head or distribution |
| Local automation | Loopback CDP controls and document authorization | Selected desktop paths have local evidence; signed-install and Android evidence are separate |

## Patch delivery model

`apps/browser/patches/series` orders the 67 Chromium patches. `apps/browser/patches/v8/series` orders the 2 patches applied in the nested V8 checkout. The replay script validates both bases before applying them.

`overlay/` records expected integration source for development and review. It is not independently applied and cannot replace the patch series. A source change must be exported to an ordered patch, replayed on the pinned base, built, and tested.

Patches 0057–0065 implement and harden Browser Agent v1. Patch 0066 tailors settings and update-status surfaces, and 0067 adds GCSA cross-platform branding. Historical 57-patch and 65-patch identities do not cover the combined 67-patch head; a fresh replay and build identity are required.

Being listed in a series proves only ordering and presence. It does not prove a clean replay, build freshness, signing, packaging, installation acceptance, Android support, or release approval.

## Summary and credential boundary

Desktop users may configure OpenAI-, Claude (Anthropic)-, or Gemini-compatible API formats with an explicit service URL. HTTPS is allowed; plain HTTP is restricted to numeric loopback addresses. API keys are optional and stored with operating-system encryption for the current profile.

Before a remote summary request, the browser prepares a redacted payload, performs a second validation, and shows the target format, model, and destination for confirmation. Sensitive pages and pages with password fields stay on the local heuristic path. Android cannot currently obtain a normal page tab for this workflow.

## Download boundary

HTTP(S) downloads remain Chromium `DownloadItem` operations. Metalink, Torrent, and Magnet jobs are integrated into the native downloads surface, while torrent work runs through an isolated service. Global connection settings and new-task defaults live in `chrome://settings/downloads`.

Video extraction, media conversion, FFmpeg, and a bundled download extension are outside this architecture.

## Platform and release boundaries

The non-component macOS Release build-tree is an input to release qualification, not the result. Full diagnostic patch coverage does not make it an RC. Publication additionally requires a clean committed root identity and trusted build evidence for both patch series, affected native and runtime tests, product identity, signing, notarization, packaging, install acceptance, and a passed release gate.

Android wiring exists in source, but there is no current-source APK or AAB. A supported x86-64 Linux build, device acceptance, Android page-summary behavior, and Play compliance remain open gates.

## Development-internal references

These documents are intentionally not translated:

- [Overlay synchronization rules](./overlay.md)
- [Chromium tree layout](./tree-layout.md)
- [Patch maintenance notes](../patches/README.md)

Public companion documents:

- [Browser README](../README.md)
- [Android status](./android.md)
- [Play Store readiness](./play-store.md)

## Why not Electron

Electron does not own every Chromium network, CookieMonster, Blink, and V8 surface used by this design. The project therefore integrates at Chromium browser and engine layers while keeping all release claims behind explicit evidence gates.
