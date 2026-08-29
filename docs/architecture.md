# Architecture

**English** | [简体中文](architecture.zh-CN.md) | [繁體中文](architecture.zh-TW.md)

## Product shape

GCSA-aegis has two integrated browser product lines. The Chromium fork is the desktop and Android-track product; the native iOS app uses SwiftUI and WKWebView. The retired standalone-extension product remains out of scope.

```text
                         packages/core
        policies, generated assets, Agent Contract v1 and golden vectors
                               │
             ┌─────────────────┴─────────────────┐
             ▼                                   ▼
apps/browser: Chromium fork             apps/ios: native iOS app
patch stack + browser services          SwiftUI + WKWebView
             │                          BrowserKit / PolicyKit / AgentKit
             ▼                                   │
native surfaces and packaging           embedded Safari + Share extensions
```

`packages/core` is a build-time source for testable TypeScript logic, generated resources, and the shared Agent Contract v1. `apps/browser` owns the Chromium pin, patch stack, overlay, build scripts, and platform packaging boundaries. `apps/ios` owns the native Xcode project and embedded extensions; they are not a new standalone extension product.

## Chromium runtime paths

1. **Network and navigation:** Chromium throttles apply tracker rules, selected first-party collection-path rules, link sanitization, phishing checks, and local threat-feed lookups.
2. **Storage:** cookie classification and bounce-tracking cleanup run behind browser-owned lifecycle and profile boundaries.
3. **Fingerprint surfaces:** Blink and related hooks reduce stable cross-site signals on selected Canvas, OffscreenCanvas, Audio, WebGL, and WebGPU surfaces. This is mitigation, not anonymity.
4. **Downloads:** Chromium's download UI remains the user surface. The integration adds bounded parallel HTTP(S), Metalink, and BT/Magnet paths with explicit resource and safety limits.
5. **Page summary:** the renderer supplies a bounded candidate snapshot; the browser validates and redacts it again. Sensitive pages fall back to the on-device heuristic. A user may configure an OpenAI-, Claude (Anthropic)-, or Gemini-compatible endpoint; non-loopback use requires an explicit destination and confirmation.
6. **Local automation:** selected desktop CDP paths add loopback, provenance, and exact-document authorization controls. An authorized local agent can still read page DOM, so this is not a general data-loss-prevention boundary.
7. **Browser Agent:** a browser-owned policy broker plans and executes bookmark maintenance, URL health checks, bounded page actions, downloads, workflows, monitors, and checkout preparation. Observe/Ask/Act modes, per-action policy, approval receipts, document binding, secret redaction, cancellation, and audit history remain enforced below the model layer; v1 does not authorize an unattended final purchase.

## Native iOS runtime paths

1. **Browser shell:** SwiftUI provides iPhone compact navigation and iPad sidebar layouts around WKWebView tabs, address/search input, navigation controls, history, and bookmarks.
2. **Profile isolation:** the standard and private profiles use separate WKWebsiteDataStore, WKUserContentController, and extension-runtime state. Private browsing is non-persistent and disables history, bookmarks, and Agent access.
3. **Embedded extensions:** SafariWebExtension exposes a gesture-bound, short-lived read-only page snapshot path whose authorization and result are bound to an isolated-world document token, navigation epoch, tab/frame/origin, and worker instance. ShareExtension accepts a bounded HTTP(S) URL into a dedicated, expiring, single-consumption App Group inbox. Real Safari permissions and real-device App Group behavior remain unverified.
4. **Policy modules:** Before a main-frame network load, BrowserSession invokes AegisPolicyKit's LinkSanitizer and PhishingScorer to rewrite tracking URLs or block high-risk navigation and display a visible intervention. PII scanning and policy snapshot parsing exist in source and tests but are not connected to a live outbound-data path.
5. **Agent Broker:** AgentKit implements the shared Agent Contract v1, immutable task grants, document leases, resource registration, and one-time action capabilities. R1/R2 actions require a separate confirmation: a random approval ID, a TTL of at most 60 seconds, and a digest bind the complete grant, tool, canonical parameters, sequence, final target, and risk. Resume checks ID/digest/TTL; issuance burns the approval before validation, and the resulting capability remains single-use. Pre-consent work is restricted to local deterministic scope; the private profile denies Agent use.
6. **Offline workflows:** all four workflows remain offline-verifiable. After a separate R1 action confirmation, browser manager performs a real transaction against the local Aegis bookmark store. Before/after tree hashes, an authenticated encrypted journal, crash-transition resolution, and state-drift checks protect apply and undo. Undo discovered after an app restart never runs automatically; it requires a new task grant and a separate R1 action confirmation. Deep research, safe download, and shopping still do not perform live DOM extraction, actual downloads, remote-model calls, payment, or order submission.
7. **Simulator chain:** the checked-in Xcode project and test runner address dedicated iPhone and iPad Simulators. This supports `SIMULATOR_QUALIFIED` evidence only.

## Research-only paths

Node-only AST analysis, bounded behavior/provenance functions, local federated simulation, and the V8 Ignition bytecode shadow are research tools or observe-only instrumentation. They are not a deployed model, full browser information-flow system, script blocker, or proof of general malicious-JavaScript protection.

## Current source and artifact identity

- The combined Chromium source contains 67 top-level patches plus 2 nested V8 patches.
- The 57-patch diagnostic manifest and 65-patch Agent acceptance are historical snapshots; neither binds or qualifies the current 67-patch head.
- The combined head requires a fresh exact replay, identity-bound build, and affected runtime acceptance before it can become a current local candidate.
- The native iOS source contains the app, BrowserKit, AegisPolicyKit, AgentKit, Safari/Share extension targets, shared contract vectors, and iPhone/iPad Simulator test chain. Its current ceiling is `SIMULATOR_QUALIFIED`.
- Simulator qualification cannot be combined with unrun real-device or distribution gates to claim iOS release qualification.

## Privacy and trust boundaries

- Chromium API credentials are optional, stored through operating-system encryption, separated by API format and normalized endpoint, and not echoed in the UI.
- Remote summary text is bounded and redacted, but a complete Chromium egress, telemetry, update, crash-reporting, and error-path audit is still pending.
- The current iOS Agent workflows are offline and do not establish a production remote-model path. Safari access is read-only and gesture/lease-bound; the Share inbox is URL-only, bounded, expiring, and single-consumption.
- Local or Simulator signing and structural checks are not equivalent to product identity, distribution signing, notarization, provisioning, Archive, TestFlight, or installed-device acceptance.
- Chromium Android remains blocked on a qualified x86-64 Linux build, a current-source package, and real-device acceptance.
- iOS real-device validation is `NOT_RUN`; default-browser entitlement is `PENDING`; formal signing, Archive, TestFlight, and App Store delivery are `NOT_RUN`.

## Release status

Both product lines are implemented in source and have different local evidence ceilings, but the project remains **release No-Go**. See the [roadmap](roadmap.md), [Chromium Browser guide](../apps/browser/README.md), and [iOS engineering guide](../apps/ios/README.md).
