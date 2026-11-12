# F7 — generate reality_vision outbound config

## Scope

Build fail-closed Xray client JSON for the admitted `reality_vision` matrix:
VLESS + RAW(TCP) + REALITY + XTLS Vision.

| Type | Role |
| --- | --- |
| `AccessRealityVisionOutboundConfigError` | Validation failures |
| `AccessRealityVisionParameters` | Canonical address / UUID / REALITY fields |
| `AccessRealityVisionOutboundConfig` | Generated document + JSON serialization |
| `AccessRealityVisionOutboundConfigBuilder` | Profile gate + matrix assembly + tree scan |
| `AccessRealityVisionOutboundConfigTests` | Happy path + ws_tls_compat / allowInsecure / ws rejects |

## Fixed matrix

| Field | Value |
| --- | --- |
| protocol | `vless` |
| encryption | `none` |
| flow | `xtls-rprx-vision` |
| network | `tcp` |
| security | `reality` |
| fingerprint default | `chrome` |

`allowInsecure` and `wsSettings` are never emitted; a post-build scan fails closed if they appear.

## Out of scope

| Item | Owner |
| --- | --- |
| Asset digest pins | F6 (already landed) |
| Embedded Xray lifecycle | F8 |
| Controlled-node probe | F10 |
| Inbound listeners / CONNECT | F3–F5 |
| WebKit ProxyConfiguration | F9 |

## PBX IDs

File refs / build files: `0040`–`0044`.
