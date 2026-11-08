# Local V2Ray / Xray config import for Access tests

## Scope

Import a developer-local V2Ray or Xray client JSON into admitted
`reality_vision` parameters for iOS AccessKit and macOS smoke checks.

| Piece | Role |
| --- | --- |
| `AccessLocalV2RayConfigError` | Fail-closed import errors |
| `AccessLocalV2RayConfig` | Resolved parameters + source path |
| `AccessLocalV2RayConfigLoader` | Parse outbounds / flat JSON |
| `AccessLocalV2RayConfigTests` | Synthetic fixtures + env-gated live import |
| `apps/browser/scripts/access_local_v2ray_config.py` | macOS/Linux redacted smoke |
| `scripts/access-local-v2ray-smoke.sh` | One-shot local runner |

## Env

| Variable | Meaning |
| --- | --- |
| `AEGIS_ACCESS_LOCAL_V2RAY_CONFIG` | Absolute path to client JSON (required for live import) |
| `AEGIS_ACCESS_LOCAL_V2RAY_LIVE` | Reserved for optional live probe (not required for import) |

Never commit real client JSON. CI stays green when the env path is unset
(`pathNotSet` / `XCTSkip`).

## Admitted matrix

Same as F7: VLESS + TCP + REALITY + `xtls-rprx-vision`. Rejects `wsSettings`
and `allowInsecure`.

## PBX IDs

`00B0`–`00B4`

## Non-goals

- Shipping a default node or secrets
- Starting product traffic from this loader alone
- Accepting WS+TLS or non-REALITY outbounds
