# F12 — HTTPS inbound to reality path

## Scope

Bridge an admitted HTTPS inbound CONNECT (behind the F5 TLS front) onto a
running `reality_vision` runtime. Same outbound dial seam as F11
(`AccessRealityPathDialing`). Certificate / TLS-identity failure is fail-closed
with no DIRECT bypass.

| Type | Role |
| --- | --- |
| `AccessHTTPSRealityPathError` | Fail-closed gates (transport, cert, runtime, no-direct) |
| `AccessHTTPSRealityPath` | Confluence open() API |
| `AccessHTTPSRealityPathTests` | Happy path, cert no-bypass, HTTP vs HTTPS gates |

## Depends on

F5 HTTPS inbound TLS front, F11 HTTP reality path seams (`AccessRealityPathDialing`),
F4 CONNECT, F8 runtime.

## Exit

- HTTPS inbound shell uses the **same outbound** as HTTP
- Certificate failure has **no bypass**
- No silent DIRECT

## Non-goals

- Starting listeners / Xray inside this type
- Site MITM or forging origin certificates
- Changing F11 HTTP-only contracts

## PBX IDs

`00A4`–`00A6`
