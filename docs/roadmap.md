# Roadmap

**English** | [简体中文](roadmap.zh-CN.md) | [繁體中文](roadmap.zh-TW.md)

## Status vocabulary

- **Historical prototype:** useful evidence of direction, not a current deliverable.
- **In source:** code or a patch exists; build and runtime status are separate.
- **Source synchronized:** patch lineage, overlay, and the external checkout agree.
- **Simulator-qualified:** the named iOS source and test scope ran together on the designated iPhone and iPad Simulators; real-device, signing, distribution, and store status remain separate.
- **Gate passed:** the named source, artifact, platform, and representative test scope passed together.
- **Release-qualified:** the same distributable artifact passed identity, trust, signing, installation, privacy, platform, and rollout gates.

## Current conclusion — 2026-08-29

The combined Chromium source contains 67 top-level patches plus 2 nested V8 patches. The earlier 57-patch diagnostic manifest and 65-patch Agent acceptance remain historical snapshots; neither binds or qualifies the current 67-patch head. Fresh exact replay, identity-bound build, and affected runtime acceptance remain open.

The native iOS product has a SwiftUI/WKWebView browser, isolated standard/private profiles, embedded Safari/Share extensions, Agent Broker, four offline deterministic workflows, shared Agent Contract v1 vectors, and an iPhone/iPad Simulator chain. Its current ceiling is **SIMULATOR_QUALIFIED**. Real-device validation is `NOT_RUN`; default-browser entitlement is `PENDING`; formal signing, Archive, TestFlight, and App Store delivery are `NOT_RUN`.

Project status is **release No-Go**. Neither product line has a trusted current-source distribution package and completed release gate set.

## Historical phases

### Phase 0 — Scaffold

The monorepo, trilingual product page, and core policy prototype established the product direction.

### Phase 1 — Extension prototype

The MV3 extension demonstrated selected tracker, phishing, and privacy-summary ideas. It is no longer a standalone product or release target.

### Phase 2 — Core prototype

Link sanitization, cookie classification, PII redaction, phishing heuristics, and generated policy assets moved into reusable, testable code. Research-only evaluators remain separate from browser decisions.

## Phase 3 — Chromium product line

### M0: Baseline and recovery — complete

- Chromium is pinned to version `151.0.7922.77` and base commit `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`.
- Local recovery points and evidence-preservation boundaries exist.

### M1: Chromium convergence and fast gates — complete

- The historical browser-only convergence retired the separate extension product and concentrated Chromium capability in `apps/browser`.
- This boundary prohibits a standalone `apps/extension`; it does not prohibit a later native platform browser with embedded extensions.
- The workspace has frozen JavaScript dependencies and repeatable fast quality gates.

### M2: Chromium integration and local build identity — partial

- The ordered source now contains 67 top-level Chromium patches and 2 nested V8 patches.
- The 57-patch diagnostic manifest and 65-patch Agent candidate retain their recorded local evidence, but only for those historical heads.
- The 65-patch candidate passed its named native, browser, fixture, lifecycle, and local UI scope; it was not a signed, notarized, installed distribution package.
- The combined 67-patch head still needs a fresh clean replay, exact identity manifest, affected tests, and runtime acceptance.

### M3–M4: Security boundaries and stability — partial

- Chromium-native tracker, link, cookie, phishing, fingerprint, download, summary, and local-automation controls exist in source.
- Selected historical native, browser, and runtime gates passed for named earlier patch heads.
- MinerGuard and the V8 bytecode shadow remain observe-only. Research evaluators do not authorize blocking or production security claims.
- A fixed-research-protocol bytecode-shadow v5 pilot passed 4/4 runs across two public sites on the current diagnostic artifact; its report remains `research-only` with `releaseEligible=false`.
- Complete product-wide egress attribution, telemetry/update/crash-reporting review, representative feature-behavior matrices, startup stress, false-positive evaluation, and broader current-head reruns remain open.

### M5: Android — deferred

- A qualified x86-64 Linux build environment is not available in the current evidence set.
- There is no identity-bound current-source APK/AAB or real-device acceptance for the current source.
- Android page summary and platform-specific behavior need current-source verification.

### M6: Chromium internal release candidate — pending

A Chromium internal RC requires a clean, identity-bound current-source build; affected tests and runtime gates; product identity; signing and notarization preparation; packaging; installed-App acceptance; privacy/egress review; and rollback evidence. None may be inferred from source synchronization.

## Phase 4 — Native iOS product line

### I0: Project and product topology — simulator-qualified scope

- The native Xcode project defines the Aegis app, BrowserKit, AegisPolicyKit, AgentKit, embedded Safari/Share extensions, and unit/UI test targets for iPhone and iPad.
- The iOS app is a product line; its extension targets remain embedded components, not standalone products.

### I1: Browser shell and profile isolation — simulator-qualified scope

- SwiftUI/WKWebView tabs, navigation, standard history/bookmarks, iPhone compact UI, and iPad sidebar exist.
- Standard and private profiles separate data stores, user-content controllers, and extension state. Private mode is non-persistent and disables history, bookmarks, and Agent use.
- Minimum-OS, multi-runtime, lifecycle, real-site, and real-device matrices remain open.

### I2: Embedded extensions and policy path — partial

- Safari has a gesture/lease-bound read-only snapshot gate whose authorization is bound to a document token and navigation epoch; Share has a bounded, expiring, single-consumption HTTP(S) URL inbox.
- BrowserSession main-frame navigation now applies LinkSanitizer and PhishingScorer for tracking-parameter cleanup and high-risk URL blocking. PII outbound enforcement is not connected to a live data path.
- Real Safari permissions, App Group behavior, Share-to-app lifecycle, and device end-to-end acceptance remain open.

### I3: Agent Contract v1 and four workflows — simulator-qualified offline scope

- AgentKit implements the shared contract codec/vectors, grants, document leases, resource registry, one-time capabilities, Broker, consent states, and recovery boundaries. R1/R2 approval uses a random ID, a TTL of at most 60 seconds, a complete action digest, exact resume checks, and burn-before-validation issuance.
- Deep research, browser manager, safe download, and shopping assistant are deterministic and offline-verifiable.
- Local bookmark apply/undo transactions, an authenticated encrypted journal, crash-recovery resolution, and an Agent double-confirmation entry point after restart are implemented in Simulator scope. Live DOM extraction, actual downloads, production model routing, payment, and order submission are not implemented release evidence.
- Final named evidence uses Aegis-Debug, Xcode 26.6, and iOS Simulator 26.5: iPhone 17 passed 80 of 81 with the iPad-only sidebar test skipped; iPad Air 11-inch (M4) passed 81 of 81. The 39/39 focused security unit tests and 2/2 critical UI tests are subsets of those full suites, not additional totals.

### I4: Device and distribution — pending

- Real-device browser, private-mode, Safari, Share, lifecycle, performance, accessibility, and privacy acceptance are `NOT_RUN`.
- Default-browser entitlement and approval are `PENDING`.
- Development Team/provisioning, formal signing, Archive, TestFlight, App Store metadata/privacy declarations, installation, upgrade, and rollback are `NOT_RUN`.

## Cross-product work
### M6: macOS local release candidate — complete; distribution qualification pending

The exact current source has a clean, identity-bound macOS local build, affected tests, fixture runtime evidence, A1–A10 acceptance, a completed fixed-range security review, and verified fixes for all 11 findings. Product identity, trusted build attestation, Developer ID signing, notarization, distribution packaging, installed-App acceptance, full Chromium outbound review, Android, and release authorization remain open; therefore formal release remains No-Go.

### M7: Documentation and publication boundaries — in progress

- Public README, architecture, and roadmap describe both product lines in English, Simplified Chinese, and Traditional Chinese.
- Dated audit records remain historical snapshots and do not override this roadmap.
- Source publication, package publication, TestFlight, App Store, and production deployment remain distinct decisions.

## GitHub source synchronization

The 2026-08-28 authorization covers SSH synchronization of source branches to `git@github.com:gcsagroup/aegis-browser.git`. It does not cover Git tags, GitHub Releases, binaries, signing credentials, notarization, Play uploads, TestFlight, App Store submission, or production deployment.

## Release exit criteria

1. Commit and reproduce the exact current source and nested lineages for both product lines from a clean state.
2. Produce identity-bound current-source Chromium and iOS distribution candidates on qualified hosts.
3. Pass affected unit, browser, runtime, privacy, egress, performance, representative-site, Simulator, and real-device gates on those exact candidates.
4. Complete Chromium identity/signing/notarization/packaging gates and iOS entitlement/provisioning/signing/Archive/TestFlight/App Store gates as applicable.
5. Complete installation, upgrade, rollback, privacy/egress, third-party notice, documentation, and distribution-authorization review for the exact release candidate.
