# F8 — embedded Xray runtime lifecycle

## Scope

Start/stop a pinned Xray core with a generated `reality_vision` config.

| Type | Role |
| --- | --- |
| `AccessXrayRuntimeError` | Lifecycle / digest / launch failures |
| `AccessXrayProcessControlling` | Injectable process seam |
| `AccessXrayDigestVerifying` | Digest gate before launch |
| `AccessXrayPinnedDigestVerifier` | Production SHA-256 ↔ F6 pins |
| `AccessXrayRuntime` | idle ↔ running lifecycle |
| `AccessXrayRuntimeTests` | mismatch, missing, start/stop |

## Non-goals

- Controlled-node probe (F10)
- Inbound CONNECT / HTTPS (F3–F5)
- Shipping the real core binary in-repo

## PBX IDs

`0060`–`0064`
