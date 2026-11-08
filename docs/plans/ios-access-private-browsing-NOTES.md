# F13 — isolate private browsing access state

Branch: `feat/ios-access-private-browsing-isolation-2cd7`  
Base: `develop` (after F9 ProxyConfiguration + P-iOS-1/2 store seams)

## Scope

Give private browsing an independent Access ownership bucket so registration,
lease, proxy configuration, credentials, and site-intent entries never leak
into the ordinary lane (and vice versa). Ending a private browsing session
destroys private Access state. Cross-bucket reuse fails closed.

F9 already exposed the WebKit write boundary (`applyToOrdinaryStore` /
`applyToPrivateStore`). This slice turns that API hint into a real ownership
controller product code can bind before applying ProxyConfiguration.

## What landed

| Piece | Role |
| --- | --- |
| `AccessBrowsingBucket` | Ordinary / private lane key; bridges `AccessOwner.profile` and `AccessProxyDataStoreKind`. |
| `AccessBrowsingIsolationError` | Fail-closed mismatch, destroy, and cross-reuse errors. |
| `AccessBrowsingAccessState` | Per-bucket registration / credential slots / proxy fixture / intent store; private destroy + fresh begin. |
| `AccessBrowsingIsolationController` | Install / query / require-belongs-to / end-private-session orchestration. |
| `AccessBrowsingIsolationControllerTests` | Isolation, cross-reuse rejection, destroy, and fresh private session. |

No new AccessKit framework target, Info.plist, or PrivacyInfo. Sources land
under the existing AccessKit target and are wired in `Aegis.xcodeproj`.

## Fail-closed rules

- Owner profile must match the target bucket (`ordinary` ↔ ordinary, `private` ↔ privateBrowsing)
- Proxy fixture `dataStoreKind` must match the target bucket
- Registration ids and credential slots are sticky to their owning bucket; destroyed private ids cannot migrate into ordinary
- Reads / installs against a destroyed private lane throw `privateAccessStateDestroyed`
- `requireRegistration` / `requireCredentialSlot` / `requireProxyFixture` reject cross-bucket reuse without mutating the peer lane
- Ending private browsing clears private registration, credentials, proxy fixture, and intents; ordinary state is untouched

## Explicit non-goals

- No BrowserSession / tab UI wiring (later product path binds the controller)
- No inbound listener, Xray runtime, or REALITY path changes
- No change to F9 applicator algorithms — only ownership before apply
- No persistent disk store for private Access state (in-memory; destroy wipes it)

## Test plan

1. Regenerate if needed: `cd apps/ios && xcodegen generate`
2. Run AccessKit-focused unit tests on an iOS 18.4+ Simulator:

```bash
xcodebuild test \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AegisTests/AccessBrowsingIsolationControllerTests
```

3. Confirm coverage for:
   - Independent ordinary vs private registration / proxy / intent
   - Cross-bucket install and require-* rejection
   - Private destroy leaves ordinary intact and blocks reuse of retired private ids
   - `beginPrivateBrowsingSession` after destroy starts a fresh empty private lane

## PBX IDs

`00D0`–`00D4`

## Blocked / follow-ups

| Item | Status |
| --- | --- |
| F9 ordinary/private applicator API | **done** — this PR owns the isolation controller those call sites bind to. |
| P-iOS-1/2 intent + session stores | Present; F13 wraps separate per-bucket intent stores. Session controller product wiring can inject this controller later. |
| BrowserSession private exit hook | Not wired here; call `endPrivateBrowsingSession()` from the private profile teardown path in a later slice. |
| Simulator evidence on this host | Linux environment cannot run `xcodebuild`; tests are authored for the existing iOS Simulator gate. |

## Out of scope

- HTTPS inbound → Reality confluence (F12)
- Simulator evidence catalog (F14)
- Changing ordinary Access teardown semantics
