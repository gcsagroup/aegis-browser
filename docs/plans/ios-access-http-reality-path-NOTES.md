# F11 — HTTP inbound to reality path

## Scope

Bridge an admitted HTTP CONNECT request onto a running `reality_vision` runtime.

| Type | Role |
| --- | --- |
| `AccessHTTPRealityPathError` | Fail-closed gates |
| `AccessRealityPathDialing` / `AccessRealityPathStream` | Injectable dial seam |
| `AccessHTTPRealityPath` | Confluence open() API |
| `AccessHTTPRealityPathTests` | HTTP-only, lease, runtime, no-direct |

## Depends on

F4 CONNECT, F8 runtime, F9 ProxyConfiguration (WebKit edge), F10 probe (environment readiness).

## Non-goals

- HTTPS front → reality (F12)
- Starting listeners / Xray inside this type
- Treating direct dial as success

## PBX IDs

`00A0`–`00A3`
