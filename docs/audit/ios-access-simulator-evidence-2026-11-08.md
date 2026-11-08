# iOS Access — simulator evidence matrix (F14)

Date: 2026-11-08 (Asia/Shanghai)  
Baseline: fork `develop` at `e700ac3d4d3ea46abbb7afab4786cab47837559b`  
Plan: [ios-access-feat-split-2026-11-08.zh-CN.md](../plans/ios-access-feat-split-2026-11-08.zh-CN.md)  
NOTES: [ios-access-simulator-evidence-NOTES.md](../plans/ios-access-simulator-evidence-NOTES.md)

## Purpose

Engineering evidence pack for AccessKit feats **F1–F11** (and product wiring already on `develop`: site intent / session / toggle). Records what **Simulator unit/UI tests already cover** versus what remains **`NOT_RUN`**.

This document does **not**:

- Claim physical-device or TestFlight PASS
- Upgrade unit green or CI green into product Phase 1 five-step PASS (`A2` / `A4`)
- Claim desktop Chromium Access routing is fully ported to iOS

## Verdict vocabulary

| Label | Meaning |
| --- | --- |
| `SIMULATOR_UNIT` | Targeted AccessKit / AegisTests cases exist for the Simulator gate |
| `PARTIAL_UNIT` | Related fail-closed or fixture coverage only; full I-row expectation not closed |
| `PENDING` | Depends on a feat not yet on `develop` |
| `NOT_RUN` | No same-candidate runtime evidence (WebKit E2E page load, controlled node, device, TestFlight) |

## Develop inventory (claimed here)

| Feat | On `develop`? | Primary sources / tests |
| --- | --- | --- |
| F1 freeze contracts | yes | `AccessContractTests` |
| F2 registration / lease | yes | `AccessRegistrationLeaseTests` |
| F3 HTTP inbound | yes | `AccessHTTPInboundListenerTests` |
| F4 HTTP CONNECT | yes | `AccessHTTPConnectTests` |
| F5 HTTPS inbound TLS front | yes | `AccessHTTPSInboundFrontTests` |
| F6 Xray digest pins | yes | `AccessXrayAssetPinTests` |
| F7 reality_vision outbound config | yes | `AccessRealityVisionOutboundConfigTests` |
| F8 Xray runtime lifecycle | yes | `AccessXrayRuntimeTests` |
| F9 ProxyConfiguration | yes | `AccessProxyConfigurationApplicatorTests` |
| F10 reality probe | yes | `AccessRealityProbeTests` (no node → `BLOCKED_RESOURCE`) |
| F11 HTTP → reality path | yes | `AccessHTTPRealityPathTests` |
| Local Reality Vision import | yes | `AccessLocalV2RayConfigTests` |
| SOCKS5 no-auth inbound | yes | `AccessSOCKS5InboundTests` (admitted no-auth only) |
| Site intent / session / toggle | yes | `AccessSiteIntentTests`, `AccessSiteSessionControllerTests`, `AccessSiteProxyToggleModelTests` |
| **F12 HTTPS → reality path** | **no** | Pending on `feat/ios-access-https-reality-path-2cd7` |
| **F13 private browsing isolation** | **no** | Pending on `feat/ios-access-private-browsing-isolation-2cd7`; F9 store-kind boundary only |

## Matrix I1–I9

| ID | Scenario | Expected | Simulator unit/UI | Device / TestFlight | Notes |
| --- | --- | --- | --- | --- | --- |
| I1 | HTTP inbound + HTTP page | Via local entry hit fixture / origin | `SIMULATOR_UNIT` — `AccessHTTPInboundListenerTests`, `AccessHTTPConnectTests`, `AccessHTTPRealityPathTests` | `NOT_RUN` | Unit covers listener admit, CONNECT, and HTTP→reality dial seam. Full WebKit page load with correlation ID / origin count = 1 is `NOT_RUN`. |
| I2 | HTTP inbound + HTTPS page | CONNECT success; site TLS end-to-end | `PARTIAL_UNIT` — CONNECT + reality path open for `example.com:443` | `NOT_RUN` | No Simulator UI evidence of end-to-end site TLS through the proxy hop. |
| I3 | HTTPS inbound + HTTP page | TLS front then forward | `PARTIAL_UNIT` — `AccessHTTPSInboundFrontTests` plan/params/lease gates | `NOT_RUN` | Front shell on `develop`. HTTPS inbound → reality confluence is **F12 `PENDING`**. |
| I4 | HTTPS inbound + HTTPS page | Shell TLS + target CONNECT; distinguishable hops; no site MITM cert | `PARTIAL_UNIT` — HTTPS front assembly only | `NOT_RUN` | Must not claim MITM-free two-hop product proof. **F12 `PENDING`**. |
| I5 | Wrong credentials | Fail closed; origin = 0 | `PARTIAL_UNIT` — inactive lease, non-canonical credential slot, registration rotation | `NOT_RUN` | HTTP 407 / secret-mismatch path is not a dedicated product drill here. Listener comments defer secret checks beyond lease/admission gates. |
| I6 | Bad / expired front certificate | Load fails; no bypass | `PARTIAL_UNIT` — `tlsIdentityUnavailable`, empty identity label | `NOT_RUN` | No WebKit certificate-error UI evidence. Bypass prohibition for live page loads is `NOT_RUN`. |
| I7 | Entry / runtime stopped | New requests fail; no silent direct | `SIMULATOR_UNIT` — listener stop, `runtimeNotRunning`, session enable without node / direct fallback rejected | `NOT_RUN` | Unit fail-closed only. Simulator refresh-after-stop UI drill is `NOT_RUN`. |
| I8 | Toggle / Access off | Clear `ProxyConfiguration`; restore native | `SIMULATOR_UNIT` — applicator clear/deactivate; `AccessSiteSessionControllerTests.testDisableTearsDownPublishedSession`; toggle off copy tests | `NOT_RUN` | Confirms empty configuration list and product off copy in unit/UI model tests. Live traffic “not via old port” is `NOT_RUN`. |
| I9 | Ordinary / private credential cross-use | Reject | `PARTIAL_UNIT` — `testOrdinaryAndPrivateStoreBoundaries` | `NOT_RUN` | Store-kind mismatch reject is on `develop`. Full private profile / credential / inbound isolation is **F13 `PENDING`**. |

## REALITY positive / negative

| ID | Scenario | Expected | Simulator unit/UI | Device / controlled node | Notes |
| --- | --- | --- | --- | --- | --- |
| R+ | Admitted `reality_vision` matrix | Build / open path without treating DIRECT as success | `SIMULATOR_UNIT` — outbound builder, local URI/JSON import, probe `passed` with injected executor, HTTP reality path open | `NOT_RUN` / `BLOCKED_RESOURCE` without authorized node | Live controlled-node probe remains environment-gated (`AccessRealityProbeTests` blocked-resource cases). |
| R− | Forbidden egress / fake success | Reject WS+TLS, `allowInsecure`, direct dial as pass, unknown outbound | `SIMULATOR_UNIT` — outbound reject tests, local import rejects, probe `rejectsDirectConnectAsPassFlag`, reality path rejects direct dial flag | `NOT_RUN` | Negative unit coverage is the engineering claim; not a DPI or production node attestation. |

## Device / TestFlight (I10)

| ID | Scenario | Verdict |
| --- | --- | --- |
| I10 | Physical device / TestFlight acceptance | **`NOT_RUN`** |

Do not internally promote Simulator unit results to a release gate.

## How to re-run Simulator AccessKit focus (Darwin)

```bash
xcodebuild test \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AccessKitTests \
  -only-testing:AegisTests/AccessSiteProxyToggleModelTests
```

Or the repo Simulator gate:

```bash
bash apps/ios/scripts/run-simulator-tests.sh --execute
```

This Linux documentation host cannot execute `xcodebuild`; rows above bind to **authored tests on `develop`**, not a fresh xcresult from this session.

## platform-features

`docs/platform-features.json` → feature `aegis-access` / iOS marks AccessKit engineering scope with `validation: simulator` and this file as evidence. Physical device and TestFlight stay out of that validation claim (`NOT_RUN` here and in catalog copy).

## Explicit non-claims

- Product Phase 1 five-step pack (`P-iOS-6` / `A2`+`A4`) — separate track
- F12 HTTPS→reality confluence — pending
- F13 private browsing Access isolation — pending beyond ProxyConfiguration store-kind checks
- SOCKS5 username/password, WS+TLS primary egress, Network Extension / system VPN
