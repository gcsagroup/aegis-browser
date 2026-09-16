# Roadmap

**English** | [简体中文](roadmap.zh-CN.md) | [繁體中文](roadmap.zh-TW.md)

## Product order

Aegis follows one explicit platform sequence:

> **macOS first → iOS / iPadOS next → other platforms later**

The existing iOS codebase is not discarded while macOS is the active milestone. Shared security fixes and contract maintenance may continue, but macOS release qualification is the current product goal. A macOS release does not wait for iOS distribution readiness.

## Evidence vocabulary

- **In source:** code exists; build and runtime status are separate.
- **Verified:** the named source and stated test scope passed together.
- **Simulator-qualified:** the named iOS source and test scope passed on the designated Simulators; real-device and distribution status remain separate.
- **Release-qualified:** the same distributable artifact passed identity, build, runtime, privacy, signing, installation and rollout gates for that platform.

Badges and historical audit records are supporting evidence for their stated scope only. They do not automatically grant release qualification.

## Current focus — macOS

Aegis for macOS is the active product line. The Chromium source, repository quality gates, standalone native C++ tests and selected integration tests exist, but the project is still **not release-qualified**. Full current-source Chromium runtime evidence and the final signed/notarized distribution chain remain separate work.

### MAC-1 — Core browser and Access Service

**Goal:** close the current browser-integration and network-routing gaps without weakening fail-closed behavior.

Exit criteria:

- Access routing, Profile/StoragePartition ownership and NetworkContext integration are covered by unit/regression tests.
- Required Chromium targets compile against the current pinned source and the relevant GoogleTest/browser scenarios run in a qualified environment.
- Selected HTTP/HTTPS proxy, unavailable-proxy and native-direct scenarios demonstrate the intended behavior without silent DIRECT fallback.
- Browser Agent, privacy controls and native browser surfaces keep their explicit security and user-consent boundaries.

### MAC-2 — Stability and release candidate

**Goal:** turn the integrated source into a reproducible, identity-bound macOS candidate.

Exit criteria:

- Clean replay/build from the pinned Chromium source and ordered patch series is reproducible.
- Representative browsing, profile isolation, downloads, Agent flows, update behavior, crash/restart handling and real-network scenarios pass on the same candidate.
- Performance, privacy/egress and regression review cover the candidate rather than historical patch heads.
- The installed application identity and evidence map back to the exact repository, Chromium, V8, patch-series and build inputs.

### MAC-3 — macOS distribution

**Goal:** qualify the first stable Aegis distribution for macOS.

Exit criteria:

- Developer ID signing and notarization succeed for the exact candidate.
- Packaging, clean installation, launch, upgrade and rollback are tested on representative supported systems.
- Release notes, third-party notices, privacy boundaries and distribution authorization are reviewed for that exact artifact.
- A separate explicit release decision authorizes publication. Source merge or CI success alone is not publication authorization.

## Next focus — iOS / iPadOS

The native iOS product already contains a SwiftUI/WKWebView browser, standard/private profile isolation, embedded Safari/Share extensions, AgentKit and an established Simulator test baseline. The next phase starts from that code and refreshes its evidence against current source; it is not a restart from zero.

### IOS-1 — Current-source real-device baseline

**Goal:** bind the existing native product to current committed source and move beyond Simulator-only evidence.

Exit criteria:

- Reproducible Debug/Release builds and regenerated Xcode project inputs are reviewed against current source.
- iPhone and iPad real-device navigation, private mode, lifecycle, accessibility and representative-site behavior pass.
- Safari extension, Share/App Group and standard/private isolation are validated end to end on device.

### IOS-2 — Product completion

**Goal:** complete the privacy, policy and Agent path required for an iOS product rather than a Simulator demo.

Exit criteria:

- PolicyKit protections cover the intended live navigation/outbound paths with privacy regression tests.
- Agent authorization, consent, recovery and embedded-extension boundaries are verified on real devices.
- Production model routing, live-site behavior and any newly enabled network/download capability receive explicit security and privacy review.

### IOS-3 — Distribution

**Goal:** qualify Aegis for TestFlight and App Store delivery.

Exit criteria:

- Required entitlement, Development Team and provisioning configuration are approved and reproducible.
- Formal signing and Archive pass for the exact candidate.
- TestFlight installation/upgrade testing, Privacy Manifest, App Store privacy metadata and required compliance material are complete.
- App Store submission remains an explicit release decision, separate from source readiness.

## Later platforms

Windows, Android and Linux remain later evaluation tracks. Existing code and manual test/build entry points are preserved, but they do not block the macOS → iOS roadmap and currently carry no release-date commitment.

## Shared engineering work

Some work spans platforms and continues throughout the roadmap:

- shared policy and Agent Contract compatibility;
- CI, test evidence and source-identity integrity;
- security reviews and dependency/license maintenance;
- documentation that separates source status, test evidence and release claims.

Historical patch counts, old test totals and dated acceptance records remain in [audit records](audit/README.md); they are not kept as moving roadmap milestones.

## Release rule

Each platform qualifies independently. For any release candidate, the evidence must describe the **same exact source and artifact** through build, runtime, privacy, signing, installation and distribution review. Passing one platform never grants release status to another.
