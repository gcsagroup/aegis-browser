[**English**](./README.md) | [简体中文](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# Aegis Native iOS Project

This directory contains the native iOS product line for GCSA-aegis. It is neither a WebKit wrapper for Chromium nor a standalone extension product. The current source includes a SwiftUI/WKWebView browser, isolated regular and private modes, embedded Safari and Share extensions, an Agent Broker, the shared Agent Contract v1, and four deterministic offline workflows.

> **Evidence status — 2026-08-28: `SIMULATOR_QUALIFIED_HARDENED`.** This status covers only the currently named iPhone/iPad Simulator paths and is bound to the latest local hardening evidence. Physical-device validation is `NOT_RUN`; the default-browser entitlement is `PENDING`; production signing, Archive, TestFlight, and App Store delivery are all `NOT_RUN`. The project as a whole remains a **release No-Go**.

## Environment and project generation

The project declares an iOS 18.4 deployment target, Swift 6 strict concurrency, the iPhone/iPad device family, and Xcode 26. It requires the Xcode 26 series, an available iOS Simulator runtime, Node.js, and XcodeGen.

XcodeGen does not provide a read-only generation mode. Check the tool and the committed project first. Run the third command only when regeneration is explicitly required, then review the generated diff:

```bash
xcodegen --version
xcodebuild -list -project apps/ios/Aegis.xcodeproj
xcodegen --spec apps/ios/project.yml
```

Example unsigned Simulator Debug build:

```bash
xcodebuild \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/aegis-ios-build-NEW-ID \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Replace `/tmp/aegis-ios-build-NEW-ID` with a new temporary path. This command produces only local Simulator build evidence; it is not an Archive, a production-signed build, or a distributable package.

## Simulator testing

Verify the offline fixtures separately, then run the default dry run:

```bash
node apps/ios/scripts/verify-fixtures.mjs
bash apps/ios/scripts/run-simulator-tests.sh \
  --dry-run \
  --output-dir /tmp/aegis-ios-NEW-ID
```

The dry run validates the fixtures and the Safari document-identity Node harness, reads the Simulator runtime and device type, and prints the planned commands. It does not create a device, start tests, or create the output directory.

When iPhone/iPad tests explicitly need to run, use a `/tmp/aegis-ios-*` directory that does not yet exist:

```bash
bash apps/ios/scripts/run-simulator-tests.sh \
  --execute \
  --output-dir /tmp/aegis-ios-NEW-ID-EXECUTE
```

Execution mode selects the latest available iOS runtime by default and uses the dedicated `Aegis QA iPhone 17` and `Aegis QA iPad Air 11-inch (M4)` Simulators in sequence, creating only missing devices when necessary. The script does not erase, delete, shut down, uninstall from, or clean up any Simulator, and it does not overwrite existing output. Results are stored in named logs, metadata, summaries, and `.xcresult` bundles.

Available options include `--project`, `--workspace`, `--scheme`, `--test-plan`, `--runtime`, and `--output-dir`. The default scheme is `Aegis`; the repository also declares `Aegis-Debug` and `Aegis-Release`. The native iOS project is not part of the pnpm workspace, so `pnpm run quality:fast` must not be treated as a substitute for Xcode tests.

## Module layout

- `AegisApp`: SwiftUI App, iPhone/iPad layouts, browser and Agent task center, and the Share inbox consumption entry point.
- `BrowserKit`: WKWebView tabs, navigation, regular/private configurations, history, bookmarks, and WebExtension resource loading.
- `AegisPolicyKit`: link sanitization, PII scanning, phishing scoring, and policy-snapshot parsing.
- `AgentKit`: Agent Contract v1 codec, authorization and leases, resource registration, one-time action capabilities, Broker, and four offline workflows.
- `SafariWebExtension` and `SharedWebExtension`: read-only page-observation paths constrained by user gestures and short leases.
- `ShareExtension` and `Shared/ShareInbox.swift`: a dedicated App Group handoff for constrained HTTP(S) URLs.
- `Tests` and `scripts`: unit/UI test sources, offline fixture validation, and the iPhone/iPad Simulator execution entry point.
- `project.yml` and `Aegis.xcodeproj`: the XcodeGen source of truth and the currently generated project.

## Agent and security boundaries

- Regular and private configurations use separate WKWebsiteDataStore, WKUserContentController, and extension state. The private configuration is not persisted and disables history, bookmarks, and Agent functionality.
- AgentKit constrains actions with immutable task authorization, document leases, non-reusable resource-ID registration, and one-time capabilities. Before user consent, only local deterministic work is allowed.
- Protected R1/R2 actions require a second confirmation independent of task authorization. Approvals use random IDs, a maximum 60-second TTL, and a complete action-scope summary. Restoration and issuance must match exactly. Once issuance starts, the approval is destroyed before either success or rejection and cannot be replayed.
- The four workflows remain offline and controlled. After a separate R1 action confirmation, Browser Steward removes tracking parameters from the current local Aegis bookmarks, performs exact deduplication, and applies stable sorting. Transactions use before/after tree hashes, a Keychain-key-backed AES-GCM journal, File Protection, crash-transition decisions, and state-drift protection. After an app restart, only an “undo available” entry is restored; a new task authorization and a separate R1 action confirmation are still required, and writes are never applied automatically. Deep Research still does not read real sites, Safe Download does not initiate real downloads, and Shopping Assistant does not pay or place orders. There is currently no production remote-model path.
- The Safari path currently observes only bounded page information and is bound to the profile, tab, frame, origin, route, worker instance, gesture nonce, isolated-world document token, navigation epoch, and a short lease. It does not read the DOM or location before authorization. After authorization, a one-shot script task verifies the full URL and document identity before pinning a snapshot; navigation changes fail safely or actively burn the lease. Results do not yet form a complete product pipeline into the main App/Agent, and real Safari native messaging, Private Browsing, and worker lifecycles have not been exercised end to end.
- The Share inbox accepts only credential-free HTTP(S) URLs and limits size, lifetime, and consumption count. The main App currently navigates after consumption; the full PolicyKit scan has not yet been inserted before navigation on this path.
- BrowserSession main-frame navigation now applies AegisPolicyKit's LinkSanitizer and PhishingScorer before network loading, and shows prompts when tracking parameters are removed or a high-risk URL is blocked. PII Scanner is still not connected to a real outbound/model network path. The current delegate and UI tests are not equivalent to zero-request network instrumentation and do not cover a real redirect hop-by-hop matrix.
- The shared contract schema and golden vectors are in [`packages/core/src/agent/contracts/v1`](../../packages/core/src/agent/contracts/v1/agent-contract-v1.schema.json), and Swift tests read the same vectors; this demonstrates the contract-compatibility scope. Bookmark transactions also have real local Store tests, but none of this evidence constitutes physical-device or release-security proof.

## Current acceptance evidence

The 2026-08-28 build of the current local worktree used Xcode 26.6 and iOS Simulator 26.5: iPhone 17 ran 113 tests, with 112 passed, 0 failed, and 1 skipped by design (iPad split view only); iPad Air 11-inch (M4) ran 113 tests, with 113 passed and 0 failed. Security-focused unit/integration tests passed 70/70 and critical UI tests passed 4/4; the Safari Node document-identity tests and Release test-entry isolation check also passed.

Visible acceptance through Computer Use completed high-risk navigation blocking, tracking-parameter removal, cross-restart undo recovery for bookmark organization, and a second restart without replay. See the [iOS Simulator Hardening Acceptance Record](../../docs/audit/ios-simulator-hardening-2026-08-28.md) for the full scope, result-bundle paths, screenshots, and residual risks. The older [qualification record](../../docs/audit/ios-simulator-qualification-2026-08-28.md) is retained as a historical baseline. The current result is still bound to a dirty local worktree; it is not evidence for a clean commit, signed artifact, or release candidate.

## Known release gates

- Freeze and commit the exact iOS source identity, then review XcodeGen regeneration differences.
- Complete Debug/Release builds and the minimum-OS, multi-runtime, real-site, lifecycle, performance, accessibility, and privacy matrices.
- Complete physical-device installation and end-to-end acceptance for Safari permissions, the Share App Group, regular/private isolation, and Agent security boundaries.
- Extend and verify PolicyKit's outbound PII enforcement path. If the scope expands to real DOM access, real downloads, or remote models, perform separate permission, consent, DLP, recovery, and outbound validation. Main-frame URL navigation policy and the cross-restart bookmark-undo journal are now within Simulator scope, but real-site and physical-device matrices remain required.
- Prepare and obtain the default-browser entitlement; complete the Privacy Manifest, privacy labels, third-party notices, and export-compliance materials.
- Configure the Development Team and provisioning, then complete production signing, Archive, TestFlight, App Store, installation/upgrade/rollback, and distribution authorization.

## Related documentation

- [iOS Simulator Qualification Record](../../docs/audit/ios-simulator-qualification-2026-08-28.md)
- [iOS Simulator Hardening Acceptance Record](../../docs/audit/ios-simulator-hardening-2026-08-28.md)
- [Product Architecture and Agent Integration Plan](../../docs/ios-product-architecture-and-agent-integration-2026-08-28.md)
- [iOS Project Execution Plan](../../docs/ios-project-execution-plan-2026-08-28.md)
- [Aegis Browser Agent v1 Implementation Plan](../../docs/aegis-browser-agent-v1-implementation-plan-2026-08-28.md)
- [Aegis Browser Agent v1 Development Execution Plan](../../docs/aegis-browser-agent-v1-development-execution-plan-2026-08-28.md)
- [Repository architecture](../../docs/architecture.md) and [roadmap](../../docs/roadmap.md)
