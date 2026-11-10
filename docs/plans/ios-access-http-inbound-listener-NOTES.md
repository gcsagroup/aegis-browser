# F3 — loopback HTTP inbound listener

## Scope

Bind a cleartext HTTP inbound listener to one `AccessRegistration` on loopback only.

| Type | Role |
| --- | --- |
| `AccessHTTPInboundError` | Fail-closed lifecycle / admission errors |
| `AccessHTTPInboundListener` | `NWListener` on registration endpoint; counts accepts |
| `AccessHTTPInboundListenerTests` | HTTPS rejected; inactive lease; start/accept/stop |

## Gates

- Transport must be `http` (HTTPS front is F5)
- Lease must be active at `start(at:)`
- Host must already be loopback (`AccessEndpoint`)
- Bind uses `requiredLocalEndpoint` so the socket is not wildcard

## Out of scope

| Item | Owner |
| --- | --- |
| HTTP CONNECT | F4 |
| HTTPS TLS front | F5 |
| REALITY / Xray | F6–F8 / F10 |
| WebKit ProxyConfiguration | F9 |

## PBX IDs

File refs / build files: `0030`–`0032` (partitioned from F2 `0010`–`0014`, F6 `0020`–`0025`, F7 `0040`–`0044`, F9 `0009`–`000D`).
