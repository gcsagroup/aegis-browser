# F14 — simulator evidence and feature catalog notes

Branch: `feat/ios-access-simulator-evidence-2cd7`  
Base: `develop` (F1–F11 + site intent/session/toggle already merged)

## Scope

Engineering evidence pack only:

| Piece | Role |
| --- | --- |
| `docs/audit/ios-access-simulator-evidence-2026-11-08.md` | Matrix **I1–I9** + REALITY ±; device/TestFlight = `NOT_RUN` |
| `docs/platform-features.json` (+ generated pages) | Mark iOS AccessKit scope: Simulator unit/UI vs device `NOT_RUN` |
| This NOTES file | Feat boundary and non-goals |

No AccessKit / AegisApp product toolbar or session code changes.

## Depends on

- F1–F11 engineering closed loop on `develop`
- Catalog check: `node scripts/check-platform-features.mjs`

## Pending on develop (do not claim)

| Feat | Status |
| --- | --- |
| F12 HTTPS inbound → reality path | Not merged; I3/I4 confluence stays `PENDING` / `PARTIAL_UNIT` (front only) |
| F13 private browsing Access isolation | Not merged; I9 limited to F9 store-kind mismatch tests |

When F12/F13 land, refresh the matrix rows in a follow-up docs PR — do not fold their implementation into F14.

## Evidence rules

- Prefer documenting authored Simulator unit/UI coverage over inventing PASS
- Never claim physical-device PASS from this pack
- Unit/CI green ≠ product Phase 1 (`A2`/`A4`) PASS
- Do not describe I1–I4 as a full desktop Access port

## Non-goals

- Product five-step evidence directory (`P-iOS-6`)
- Real-device / TestFlight / Archive gates
- Implementing F12 or F13
- SOCKS5 authenticated path, WS+TLS primary egress, Network Extension
