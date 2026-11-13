# F4 — HTTP CONNECT on inbound

## Scope

Admit `CONNECT host:port HTTP/1.x` on the loopback HTTP listener from F3.

| Type | Role |
| --- | --- |
| `AccessHTTPConnectError` | Fail-closed parse / response errors |
| `AccessHTTPConnectRequest` | Parsed authority + HTTP version |
| `AccessHTTPConnectParser` | Header-block parser + response bytes |
| `AccessHTTPConnectSession` | Per-connection admission; writes `200` |
| `AccessHTTPInboundListener` | Updated to drive CONNECT sessions |
| `AccessHTTPConnectTests` | Parser + establish + reject GET |

## Non-goals

- No direct dial to the CONNECT target (outbound is F11 via `reality_vision`)
- No HTTPS TLS front (F5)
- No Proxy-Authorization secret checks beyond registration binding already done at listen time

## PBX IDs

`0050`–`0054`
