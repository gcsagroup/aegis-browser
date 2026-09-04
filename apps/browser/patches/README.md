[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# Patches

Patches in this directory are applied on top of the pinned Chromium commit
(`../CHROMIUM_COMMIT`) inside the local checkout.

## Conventions

1. Name files `0001-short-title.patch`, `0002-...`
2. List them in `series` in apply order
3. Prefer small, reviewable diffs that call into `aegis/` glue rather than rewriting Blink wholesale
4. Never vendor the full Chromium tree in this git repo

## Current local patch series

The status “in series” means only that the patch file is listed in the current local `series`; it does not mean that the patch has landed upstream, passed release gates, or is publishable. The 49-, 67-, and 95-patch records are retained only as historical snapshots. The current integrated source contains **97 Chromium patches plus 2 nested V8 patches**: 0057–0065 contain the original Browser Agent integration, 0066–0067 contain Settings/update and visual branding, and 0068–0097 replace and harden the v1 execution path with the Browser Agent v2 runtime, cross-platform entry points, scheduled automation, named-site routing, profile isolation, bounded recovery, browser-bound tab/document capabilities, committed-navigation waiting, and deterministic service registration. Patches 0079–0095 replay to Chromium source commit `c930fa41ef7e9522f145848f3080ee0cc1edc4d8`; patch 0096 replays that tree to `f8dff6e3a5dd02527c093b57cde78fc4b0dcb34f`, and patch 0097 produces committed source `a3040bb0dea05e87c2a141b9a29a237a96953620` (tree `d7e560e4803c14a9239c9a9f511f46516f8e1cda`). Artifact qualification remains platform-specific and requires acceptance evidence for that exact source.

| ID | Intent | Status |
|----|--------|--------|
| 0001 | Add the `chrome/browser/aegis/` stub and feature flag | in series |
| 0002 | Wire network throttling and tracker-host request cancellation | in series |
| 0003 | Embed the `chrome://aegis` WebUI settings surface | in series |
| 0004 | Add a phishing interstitial through a navigation throttle | in series |
| 0005 | Add FingerprintGuard farbling hooks for Canvas, Audio, and WebGL | in series |
| 0006 | Bundle the `packages/core` policy snapshot into C++ `.inc` files and JSON | in series |
| 0007 | Add an EasyList compiler and runtime filter-list updater | in series |
| 0008 | Strip tracking query parameters and add a cookie janitor | in series |
| 0009 | Uncloak CNAMEs and clear bounce-tracker cookies | in series |
| 0010 | Add phishing URL heuristics and an explainable interstitial | in series |
| 0011 | Add phishing page-sense for password forms and urgency copy | in series |
| 0012 | Add the JavaScript policy worker through gin and the Privacy AI/Ollama sidecar | in series |
| 0013 | Farble WebGPU `adapter.info` | in series |
| 0014 | Fix the startup DCHECK and run the policy worker under `chrome://aegis` | in series |
| 0015 | Add `chrome://aegis` entries to Settings and the menu | in series |
| 0016 | Add module descriptions and Ollama model settings | in series |
| 0017 | Delay filter-list and cookie cleanup after startup | in series |
| 0018 | Use the local `compiled.json` cache when EasyList starts | in series |
| 0019 | Refresh the EasyList cache with a 24-hour check, HTTP 304 handling, and failure backoff | in series |
| 0020 | Add human-readable interstitial copy, summaries, and a session-cleanup checklist | in series |
| 0021 | Add an exact cookie list and first-party collection-path blocking | in series |
| 0022 | Add live session-list refresh, Canvas self-checks, and a GA4 collection decoy | in series |
| 0023 | Make blocking visible; strip Referer parameters; label cookies; add local CDP/AI controls | in series |
| 0024 | Hide internal pages from the remote CDP target list and show Agent connections in the session list | in series |
| 0025 | Show an in-browser banner for local CDP connections and add a button for `chrome://aegis` | in series |
| 0026 | Run one-time Canvas, WebGL, Audio, and WebGPU checks in `chrome://aegis` | in series |
| 0027 | Perturb Audio fingerprints once per site and cover `copyFromChannel` | in series |
| 0028 | Stabilize WebGPU limits and subgroup values per site | in series |
| 0029 | Package `chrome://aegis` on Android and reserve the display/package identity for Play | in series |
| 0030 | Open `chrome://aegis` from Android Settings and disable CDP/Ollama on mobile | in series |
| 0031 | Harden summary/Ollama, phishing, and local CDP security boundaries and regression tests | in series |
| 0032 | Preserve remote-CDP production wiring and security-test checkpoints | in series |
| 0033 | Unify remote-CDP origin propagation, target authorization, and sensitive-protocol blocking | in series |
| 0034 | Preserve initial blank-document ownership semantics across hash navigation | in series |
| 0035 | Fix Aegis WebUI TypeScript lint failures | in series |
| 0036 | Fix CDP browser-test notification matcher types | in series |
| 0037 | Stabilize Aegis browser unit-test builds and threshold assertions | in series |
| 0038 | Preserve and authorize the initial document once when a remote target is created | in series |
| 0039 | Capture the final Ollama HTTP request body and verify that raw PII is not sent | in series |
| 0040 | Release Aegis components, callbacks, and raw pointers before Profile destruction | in series |
| 0041 | Disable Google AIM eligibility server requests in production while retaining a positive test-factory gate | in series |
| 0042 | Avoid creating policy FM/GCM listeners for ordinary unregistered Profiles and start once after enterprise registration | in series |
| 0043 | Return Aegis block, CNAME, Referer, and parameter events to the Remote-owned sequence and guard shutdown lifetime | in series |
| 0044 | Index path rules by domain, shorten the list-replacement critical section, and remove the full-image double copy from Canvas farbling | in series |
| 0045 | Add structured page-protection events, site aggregation, privacy trimming, and temporary per-site pause | in series |
| 0046 | Add a browser-native shield entry, current-site bubble, and one-time awareness onboarding | in series |
| 0047 | Add a protection overview, pre-summary confirmation, phishing-clue-first explanations, and event-driven state | in series |
| 0048 | Limit summary sources to the Settings page's own window and reject cross-window/Profile tabs | in series |
| 0049 | Add bounded phishing-page collection, brand-impersonation/path/short-link signals, and a local multi-source SHA-256 threat index | in series |
| 0050 | Integrate multi-connection accelerated downloads and BT downloads | in series |
| 0051 | Add native download settings and secure defaults | in series |
| 0052 | Harden Canvas, OffscreenCanvas, Audio, WebGL, and WebGPU fingerprint protection | in series |
| 0053 | Add observe-only, non-blocking MinerGuard | in series |
| 0054 | Add default-off V8 bytecode-shadow observation | in series |
| 0055 | Support user-editable OpenAI, Claude (Anthropic), and Gemini-compatible API endpoints, model lists, and endpoint-scoped credentials | in series |
| 0056 | Complete in-place AI-summary confirmation and results in the current-site bubble, with exact document-session API lifecycle handling | in series |
| 0057 | Pin the V8 bytecode-shadow observation revision used by Agent | in series |
| 0058 | Add task contracts, state machine, policy broker, model protocol, task store, and fixed tool registry | in series |
| 0059 | Connect Aegis exact scope, document binding, and task lifetime to the Actor execution layer | in series |
| 0060 | Add the native side panel, menu, shortcut, Settings entry, and desktop Browser/UI tests | in series |
| 0061 | Fix the bounded security-audit findings and harden resource packaging, real shortcuts, and desktop integration | in series |
| 0062 | Show the Browser Agent entry by default and add regression coverage | in series |
| 0063 | Migrate the Agent toolbar entry for existing Profiles | in series |
| 0064 | Signal side-panel readiness explicitly and fix entry state | in series |
| 0065 | Open task pages automatically and support tasks from blank tabs | in series |
| 0066 | Remove upstream AI/Google entries from GCSA Settings, restore search-engine management, and rebuild About/update status | in series |
| 0067 | Integrate the GCSA logo and cross-platform app icons while preserving Chromium's internal identity and user-data directory | in series |
| 0068 | Add the Browser Agent v2 native hybrid runtime spike | in series |
| 0069 | Harden the autonomous v2 runtime and policy boundaries | in series |
| 0070 | Simplify Browser Agent v2 onboarding and task entry | in series |
| 0071 | Harden the model-planning and execution flow | in series |
| 0072 | Route goals through model understanding before browsing | in series |
| 0073 | Require provider-native tools and deterministic named-site routing | in series |
| 0074 | Bind implicit current-page tasks to the active document | in series |
| 0075 | Add common task shortcuts and scheduled automation | in series |
| 0076 | Correct cross-platform build integration and branding | in series |
| 0077 | Complete the cross-platform Browser Agent v2 runtime and entry points | in series |
| 0078 | Recover safe read-only plans after bounded model-format failures | in series |
| 0079 | Support isolated primary Incognito Aegis/Agent/Actor/UI; fail closed for Guest/System/auxiliary OTR; latch desktop/Android remote CDP; redact default NetLog API-key headers and private Actor diagnostics; partition CNAME and Advanced/Torrent ownership with close cancellation | in series |
| 0080 | Harden current-page planning for local Qwen models | in series |
| 0081 | Validate model plan ordering before execution | in series |
| 0082 | Reject redundant entry navigation after the browser opens a target | in series |
| 0083 | Reduce latency for local Qwen native-tool turns | in series |
| 0084 | Require durable browser-owned scheduled automations | in series |
| 0085 | Repair evidence-bound execution turns once without broadening scope | in series |
| 0086 | Block non-public URLs proposed by the model router | in series |
| 0087 | Use the product logo in the Agent workspace | in series |
| 0088 | Add the branded Android Agent entry and composer | in series |
| 0089 | Recover named-site searches from weak model routing | in series |
| 0090 | Keep bookmark and other browser-data tasks on native tools | in series |
| 0091 | Tolerate and discard harmless redundant targets on browser-only routes | in series |
| 0092 | Validate explicit bookmark goals, repair omitted steps, and keep preview-only tasks read-only | in series |
| 0093 | Support explicit local-fixture URL validity checks | in series |
| 0094 | Normalize native task-completion evidence | in series |
| 0095 | Preserve verified completion and bookmark undo | in series |
| 0096 | Bind model browser capabilities to live task context | in series |
| 0097 | Wait for scoped navigation to commit and register Aegis services before profile initialization | in series |

Apply with `pnpm --filter @gcsa-aegis/browser apply-patches` on a clean pinned checkout. Every series change requires a fresh offline replay, cold and incremental builds, and the affected tests.
