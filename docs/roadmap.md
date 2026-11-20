# Roadmap

**English** | [简体中文](roadmap.zh-CN.md) | [繁體中文](roadmap.zh-TW.md)

## Platform tracks

Three tracks run at once, with different goals. Progress on one platform does not grant release status to another.

| Track | Goal now |
| --- | --- |
| iOS / iPadOS | Shipped. App Store 1.0.0 is public. Current work is maintenance of that line plus Access acceptance. |
| macOS | Release qualification. Chromium integration is in source; runtime and distribution qualification are still open. |
| Windows | A colleague owns the Windows source port and native acceptance. Runner admission and native build, test, browser and installer acceptance remain paused under the recorded decision. Android and Linux stay later evaluation tracks, with no release-date commitment. |

macOS release qualification does not wait for the next iOS store submission. iOS maintenance and Access acceptance do not wait for macOS release qualification. The Access order is in [TODO.md](../TODO.md#access-roadmap-todo): close [#157](https://github.com/gcsagroup/aegis-browser/issues/157) and [#158](https://github.com/gcsagroup/aegis-browser/issues/158), then webpage evidence for [#136](https://github.com/gcsagroup/aegis-browser/issues/136) and [#155](https://github.com/gcsagroup/aegis-browser/issues/155), then iPhone [#137](https://github.com/gcsagroup/aegis-browser/issues/137), [#160](https://github.com/gcsagroup/aegis-browser/issues/160) and [#138](https://github.com/gcsagroup/aegis-browser/issues/138). In parallel, clear macOS [#165](https://github.com/gcsagroup/aegis-browser/issues/165) and [#179](https://github.com/gcsagroup/aegis-browser/issues/179), then [#140](https://github.com/gcsagroup/aegis-browser/issues/140) and [#141](https://github.com/gcsagroup/aegis-browser/issues/141).

## Evidence vocabulary

- **In source:** code exists; build and runtime status are separate.
- **Verified:** the named source and stated test scope passed together.
- **Simulator-qualified:** the named iOS source and test scope passed on the designated Simulators; real-device and distribution status remain separate.
- **Release-qualified:** the same distributable artifact passed identity, build, runtime, privacy, signing, installation and rollout gates for that platform.

Badges and historical audit records are supporting evidence for their stated scope only. They do not automatically grant release qualification.

## Current focus — macOS release qualification

macOS is the track competing for desktop release qualification. The Chromium source, repository quality gates, standalone native C++ tests and selected integration tests exist, but the project is still **not release-qualified**. Full current-source Chromium runtime evidence and the final signed/notarized distribution chain remain separate work.

Clear [#165](https://github.com/gcsagroup/aegis-browser/issues/165) and [#179](https://github.com/gcsagroup/aegis-browser/issues/179) before the combined browser pass. Then take [#140](https://github.com/gcsagroup/aegis-browser/issues/140) and [#141](https://github.com/gcsagroup/aegis-browser/issues/141). Those defects are fixed on this track in parallel with the iOS Access sequence; they do not move Windows work onto this track.

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

## Current focus — iOS maintenance and Access acceptance

iPhone and iPad App Store 1.0.0 is public, with an external [TestFlight](https://testflight.apple.com/join/EwUW1VDx) beta. The native app is SwiftUI/WKWebView, with standard/private profile isolation, embedded Safari/Share extensions, AgentKit and a Simulator baseline. Current iOS work maintains that shipped line and accepts Access on device. It is not a restart, and it is not a first-time store launch.

Access acceptance order: close [#157](https://github.com/gcsagroup/aegis-browser/issues/157) and [#158](https://github.com/gcsagroup/aegis-browser/issues/158), then webpage evidence for [#136](https://github.com/gcsagroup/aegis-browser/issues/136) and [#155](https://github.com/gcsagroup/aegis-browser/issues/155), then iPhone [#137](https://github.com/gcsagroup/aegis-browser/issues/137), [#160](https://github.com/gcsagroup/aegis-browser/issues/160) and [#138](https://github.com/gcsagroup/aegis-browser/issues/138). IOS-3 below is the bar for any later store candidate. Shipping 1.0.0 does not close those Access issues, and source readiness does not authorize the next submission.

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

## Windows and later platforms

A colleague owns the Windows track: source alignment in [#170](https://github.com/gcsagroup/aegis-browser/issues/170) and native build, test and runner acceptance in [#182](https://github.com/gcsagroup/aegis-browser/issues/182). The [2026-11-18 decision](https://github.com/gcsagroup/aegis-browser/issues/182#issuecomment-6977894606) keeps Windows runner admission, GN, compilation, native tests, browser and installer acceptance paused until the colleague resumes authorized execution. This roadmap records that ownership. It does not schedule Windows work on the iOS or macOS tracks, and it does not treat Windows as release-qualified.

Android and Linux remain later evaluation tracks. Existing source and manual entry points stay. They do not block iOS maintenance or macOS release qualification, and they carry no release-date commitment.

## Shared engineering work

Some work spans platforms and continues throughout the roadmap:

- shared policy and Agent Contract compatibility;
- CI, test evidence and source-identity integrity;
- security reviews and dependency/license maintenance;
- documentation that separates source status, test evidence and release claims.

Historical patch counts, old test totals and dated acceptance records remain in [audit records](audit/README.md); they are not kept as moving roadmap milestones.

## Release rule

Each platform qualifies independently. For any release candidate, the evidence must describe the **same exact source and artifact** through build, runtime, privacy, signing, installation and distribution review. Passing one platform never grants release status to another.
