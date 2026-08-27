# Roadmap

**English** | [简体中文](roadmap.zh-CN.md) | [繁體中文](roadmap.zh-TW.md)

## Status vocabulary

- **Historical prototype:** useful evidence of direction, not a current deliverable.
- **In source:** code or a patch exists; build and runtime status are separate.
- **Source synchronized:** patch lineage, overlay, and the external checkout agree.
- **Gate passed:** the named source, artifact, platform, and representative test scope passed together.
- **Release-qualified:** the same distributable artifact passed identity, trust, signing, installation, privacy, platform, and rollout gates.

## Current conclusion — 2026-08-28

The source integration is synchronized to 56 top-level Chromium patches plus 2 nested V8 patches. The latest identity-bound local build-tree manifest covers only 54 top-level patches plus the 2 V8 patches and is `diagnostic-only`; patches 0055 and 0056 do not yet have matching artifact evidence.

Project status is **release No-Go**. There is no trusted current-source distribution package, product identity, Developer ID signature, notarization, installed-App acceptance, or current-source Android package.

## Historical phases

### Phase 0 — Scaffold

The monorepo, trilingual product page, and core policy prototype established the product direction.

### Phase 1 — Extension prototype

The MV3 extension demonstrated selected tracker, phishing, and privacy-summary ideas. It is no longer a product or release target.

### Phase 2 — Core prototype

Link sanitization, cookie classification, PII redaction, phishing heuristics, and generated policy assets moved into reusable, testable code. Research-only evaluators remain separate from browser decisions.

## Phase 3 — Chromium fork

### M0: Baseline and recovery — complete

- Chromium is pinned to version `151.0.7922.77` and base commit `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`.
- Local recovery points and evidence-preservation boundaries exist.

### M1: Browser-only convergence and fast gates — complete

- The Chromium browser is the only product line.
- The workspace has frozen JavaScript dependencies and repeatable fast quality gates.

### M2: Chromium integration and build identity — partial

- The external Chromium checkout matches all 56 top-level patches and the 2 nested V8 patches.
- The latest finalized identity manifest covers the 54-patch Chromium head plus 2 nested V8 patches, not the current 0056 source head.
- Current-source 0055/0056 build, affected native tests, representative runtime, and a new identity-bound artifact remain required.
- Existing build-tree output is local development evidence, not an RC or distribution package.

### M3–M4: Security boundaries and stability — partial

- Chromium-native tracker, link, cookie, phishing, fingerprint, download, summary, and local-automation controls exist in source.
- Selected historical native, browser, and runtime gates passed for named earlier patch heads.
- MinerGuard and the V8 bytecode shadow remain observe-only. Research evaluators do not authorize blocking or production security claims.
- Complete egress attribution, telemetry/update/crash-reporting review, representative feature-behavior matrices, startup stress, false-positive evaluation, and current-head reruns remain open.

### M5: Android — blocked

- A qualified x86-64 Linux build environment is not available in the current evidence set.
- There is no identity-bound current-source APK/AAB or real-device acceptance for the current source.
- Android page summary and platform-specific behavior need current-source verification.

### M6: Internal release candidate — pending

An internal RC requires a clean, identity-bound current-source build; affected tests and runtime gates; product identity; signing and notarization preparation; packaging; installed-App acceptance; privacy/egress review; and rollback evidence. None of these may be inferred from source synchronization.

### M7: Documentation and publication boundaries — in progress

- Public README, changelog, architecture, roadmap, and research map are maintained in English, Simplified Chinese, and Traditional Chinese.
- Dated audit records remain historical snapshots and do not override this roadmap.
- Source publication, package publication, and production deployment remain distinct decisions.

## GitHub source synchronization

The 2026-08-28 authorization covers SSH synchronization of source branches to `git@github.com:gcsagroup/aegis-browser.git`. It does not cover Git tags, GitHub Releases, binaries, signing credentials, notarization, Play uploads, or production deployment.

## Release exit criteria

1. Commit and reproduce the exact current source and all nested patch lineages from a clean state.
2. Produce an identity-bound current-source macOS artifact and current-source Android artifact on qualified hosts.
3. Pass affected unit, browser, runtime, privacy, egress, performance, and representative-site gates on those exact artifacts.
4. Complete product identity, signing, notarization, packaging, installation, upgrade, rollback, and real-device acceptance.
5. Review documentation, third-party notices, security/privacy statements, and distribution authorization for the exact release candidate.
