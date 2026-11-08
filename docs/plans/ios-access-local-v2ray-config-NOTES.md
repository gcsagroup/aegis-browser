# Local Reality Vision import for Access tests

## Scope

Use a developer-local test endpoint (Xray Core **or** sing-box client export /
`vless://` share URI) to drive Access `reality_vision` parameters.

| Surface | Role |
| --- | --- |
| iOS `AccessLocalV2RayConfigLoader` | **Minimal**: `vless://` share URI or flat JSON only |
| `apps/browser/scripts/access_local_v2ray_config.py` | macOS/Linux smoke: URI + Xray Core + sing-box |
| `scripts/access-local-v2ray-smoke.sh` | One-shot local runner |

Routing databases (`geoip.dat` / `geosite*.srs`) are **out of scope** — Access
only needs the admitted Reality Vision outbound fields.

## Env

| Variable | Meaning |
| --- | --- |
| `AEGIS_ACCESS_LOCAL_V2RAY_CONFIG` | Path to a `vless://` text file or client JSON |

Never commit real share URIs or client JSON. Keep them under
`/.local/access-service/` (gitignored). CI stays green when unset.

Suggested local fixtures (operator-only):

| File | Role |
| --- | --- |
| `test-reality-vision.uri` | Positive: admitted `reality_vision` share URI |
| `test-ws-tls-reject.uri` | Negative: WS+TLS must fail closed (`unsupportedSecurity` / `unsupportedNetwork`) |

## Admitted matrix

VLESS + TCP + REALITY + `xtls-rprx-vision` (`encryption=none`). Rejects WS /
`allowInsecure` / non-REALITY security.

## Field map

| Access field | `vless://` | Xray Core | sing-box |
| --- | --- | --- | --- |
| address | host | `vnext[].address` | `server` |
| port | port | `vnext[].port` | `server_port` |
| userID | user | `users[].id` | `uuid` |
| serverName | `sni` | `realitySettings.serverName` | `tls.server_name` |
| publicKey | `pbk` | `realitySettings.publicKey` | `tls.reality.public_key` |
| shortID | `sid` | `realitySettings.shortId` | `tls.reality.short_id` |
| fingerprint | `fp` | `realitySettings.fingerprint` | `tls.utls.fingerprint` |

## PBX IDs

`00B0`–`00B3`

## Non-goals

- Embedding geo routing assets on iOS
- Full Xray / sing-box document parsers inside AccessKit
- Committing live node credentials
