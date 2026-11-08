# F9 — apply ProxyConfiguration to WKWebsiteDataStore

Branch: `feat/ios-access-proxy-configuration-2cd7`  
Base: `develop` (after F1 freeze contracts merge)

## Scope

Apply registration-derived Network `ProxyConfiguration` values to a
`WKWebsiteDataStore`. Ordinary and private browsing stores are separate call
sites. Closing or deactivating Access always writes an empty configuration list
so a previous loopback port is not reused.

## What landed

| Piece | Role |
| --- | --- |
| `AccessProxyRegistrationFixture` | Fake registration input (no F2 lease types). Soft-depends on F1 `AccessInboundTransport` (`http` / `https` only). |
| `AccessProxyConfigurationBuilder` | Maps fixture → HTTP CONNECT plan; HTTPS attaches TLS options to the proxy hop. |
| `AccessProxyConfigurationApplicator` | Writes / clears `WKWebsiteDataStore.proxyConfigurations`. |
| `AccessProxyConfigurationError` | Fail-closed errors for host / port / kind mismatch. |
| `AccessProxyConfigurationApplicatorTests` | Unit coverage for apply, replace, clear, deactivate, and kind boundaries. |

No new AccessKit framework target, Info.plist, or PrivacyInfo: F1 already owns
those. This PR only adds applicator sources under the existing AccessKit target
and wires them in `Aegis.xcodeproj`.

## Fail-closed rules

- Non-loopback hosts rejected (`127.0.0.1` / `::1` only)
- Port `0` rejected
- Empty / padded registration id rejected
- Ordinary / private kind mismatch throws without clearing a correctly applied peer store
- Inactive fixture → empty configuration list (old port dropped)
- Explicit `clear*` always assigns `[]`

## Explicit non-goals

- No inbound listener, Xray runtime, or REALITY path
- No SOCKS5 constructible path
- No BrowserSession / tab wiring (later product slice)
- No F2 registration / lease types — fixture is intentional

## Test plan

1. Regenerate if needed: `cd apps/ios && xcodegen generate`
2. Run AccessKit-focused unit tests on an iOS 18.4+ Simulator:

```bash
xcodebuild test \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:AegisTests/AccessProxyConfigurationApplicatorTests
```

3. Confirm coverage for:
   - HTTP cleartext vs HTTPS TLS-to-proxy plans
   - apply → replace port → clear leaves empty configs
   - deactivated fixture clears the store
   - ordinary / private kind mismatch is rejected without clearing a correctly applied peer store
   - non-loopback host and port `0` fail closed

## Blocked / follow-ups

| Item | Status |
| --- | --- |
| F1 freeze contracts on `develop` | **done** — rebase onto F1 AccessKit; use `AccessInboundTransport`. |
| F2 registration / lease types | Not in this PR. Fake `AccessProxyRegistrationFixture` is intentional. |
| F3–F5 inbound listeners | Not implemented; fixture ports are not bound. |
| F6–F8 / F10 REALITY + Xray | Not touched. |
| F13 private browsing isolation | API boundary only (`applyToOrdinaryStore` / `applyToPrivateStore`). No BrowserSession wiring. |
| Simulator evidence on this host | Linux environment cannot run `xcodebuild`; tests are authored for the existing iOS Simulator gate. |

## Out of scope

- Xray / outbound / inbound listener implementation changes
- SOCKS5 constructible path
- Wiring the applicator into `BrowserSession` tab creation (later product slice)
