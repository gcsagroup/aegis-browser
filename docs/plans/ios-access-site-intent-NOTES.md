# P-iOS-1 — site intent (off / allow / block)

## Scope

Per exact-host Access product intent without starting runtime or WebKit wiring.

| Type | Role |
| --- | --- |
| `AccessSiteIntent` | `off` / `allow` / `block` |
| `AccessSiteHost` | Canonical exact-host key + URL normalization |
| `AccessSiteIntentError` | Validation failures |
| `AccessSiteIntentStore` | In-memory persistence (off entries omitted) |
| `AccessSiteIntentTests` | Parse / normalize / store |

## Non-goals

- ProxyConfiguration / Xray start (P-iOS-2)
- SwiftUI toggle (P-iOS-3)
- Profile isolation buckets (F13 / later)

## PBX IDs

`00C0`–`00C4`
