# Architecture

**English** | [简体中文](architecture.zh-CN.md) | [繁體中文](architecture.zh-TW.md)

## Product shape

GCSA-aegis is an integrated Chromium fork. It is not an Electron shell and does not ship its core capability as a separate extension.

```text
packages/core
  policies, detectors, generated resources, research-only evaluators
        │
        ▼
Chromium patch stack and overlay
        │
        ▼
AegisService / throttles / storage hooks / WebUI / native surfaces
        │
        ├── local browser decisions and on-device heuristic summary
        └── optional user-configured compatible model API
```

`packages/core` is a build-time source for testable TypeScript logic and generated resources. `apps/browser` owns the Chromium pin, patch stack, overlay, build scripts, verification tools, and platform packaging boundaries.

## Runtime paths

1. **Network and navigation:** Chromium throttles apply tracker rules, selected first-party collection-path rules, link sanitization, phishing checks, and local threat-feed lookups.
2. **Storage:** cookie classification and bounce-tracking cleanup run behind browser-owned lifecycle and profile boundaries.
3. **Fingerprint surfaces:** Blink and related hooks reduce stable cross-site signals on selected Canvas, OffscreenCanvas, Audio, WebGL, and WebGPU surfaces. This is mitigation, not anonymity.
4. **Downloads:** Chromium's download UI remains the user surface. The integration adds bounded parallel HTTP(S), Metalink, and BT/Magnet paths with explicit resource and safety limits.
5. **Page summary:** the renderer supplies a bounded candidate snapshot; the browser validates and redacts it again. Sensitive pages fall back to the on-device heuristic. A user may configure an OpenAI-, Claude (Anthropic)-, or Gemini-compatible endpoint; non-loopback use requires an explicit destination and confirmation.
6. **Local automation:** selected desktop CDP paths add loopback, provenance, and exact-document authorization controls. An authorized local agent can still read page DOM, so this is not a general data-loss-prevention boundary.

## Research-only paths

Node-only AST analysis, bounded behavior/provenance functions, local federated simulation, and the V8 Ignition bytecode shadow are research tools or observe-only instrumentation. They are not a deployed model, full browser information-flow system, script blocker, or proof of general malicious-JavaScript protection.

## Current source and artifact identity

- The live source integration contains 56 top-level Chromium patches plus 2 nested V8 patches; the external checkout matches the overlay and patch lineage.
- The latest identity-bound local build-tree manifest covers only 54 top-level patches plus the 2 V8 patches and is marked `diagnostic-only` because the root repository was dirty.
- Patches 0055 and 0056 are synchronized in source but are not covered by that artifact identity. Their presence cannot be combined with older runtime counts to claim current release qualification.

## Privacy and trust boundaries

- API credentials are optional, stored through the operating system's encryption, separated by API format and normalized endpoint, and not echoed in the UI.
- Remote summary text is bounded and redacted, but a complete Chromium egress, telemetry, update, crash-reporting, and error-path audit is still pending.
- Local build-tree signing or structural verification is not equivalent to product identity, Developer ID signing, notarization, stapling, or installed-App acceptance.
- Android remains blocked on a qualified x86-64 Linux build, a current-source package, and real-device acceptance.

## Release status

The architecture is implemented in source and partially validated locally, but the product remains **release No-Go**. See the [roadmap](roadmap.md) for the remaining gates and the [Browser guide](../apps/browser/README.md) for developer operations.
