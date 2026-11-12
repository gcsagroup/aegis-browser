# P-iOS-6 — iOS product Phase 1 five-step evidence pack

## Scope

Ships the product Phase 1 **evidence pack** for iOS: five-step correlation
convention (A2-1..A2-5), operator README, pack status scaffold, and a
validator that **refuses `SIMULATOR_PASS`** from unit tests alone and keeps
device/TestFlight as `NOT_RUN`.

Depends on P-iOS-3 (site toggle UI, done) and P-iOS-5 (fault fail-closed).
Exit criteria covered for this pack claim: **1 + 2 + 3 + 5 + 6**. DEV-only
P-iOS-4 is **not** required for this pack exit claim and must not be claimed
while still open.

| Piece | Role |
| --- | --- |
| `AccessSitePhase1EvidenceStep` | on / load / fault / recovery / off |
| `AccessSitePhase1EvidenceCorrelation` | `aegis-ios-p1/<sha8>/<run>/<step>` |
| `AccessSitePhase1EvidenceFaultRequirement` | Documents pending P-iOS-5 API |
| `AccessSitePhase1EvidencePack` | Pack path + allowed product status |
| Pack under `docs/audit/evidence/ios-access-product-phase1/` | Operator path + manifest template |
| `ios-access-phase1-evidence.mjs` | Schema + anti-拼证 validator |
| PBX `00F8`–`00FB` | Correlation / fault-requirement / pack / tests |

Engineering F14 (`docs/audit/ios-access-simulator-evidence-2026-11-08.md`) remains
the unit inventory; this feat is the **product** A2/A4 pack analogous to
`docs/audit/evidence/macos-access-product-phase1/`.

## Flow (A2)

1. **On (A2-1):** site-proxy enable → ready; correlation `…/on`
2. **Load (A2-2):** navigation via PROXY exit; correlation `…/load`
3. **Fault (A2-3):** runtime/node fault → Fail or Wait; never silent DIRECT; `…/fault`
4. **Recovery (A2-4):** recover → PROXY ready again; `…/recovery`
5. **Off (A2-5):** disable → native / cleared ProxyConfiguration; `…/off`

## Fault step pending (P-iOS-5)

While `feat/ios-access-fault-no-direct-2cd7` is not on `develop`:

- `status.json` keeps `faultStep: pending-pios5`
- Template fault/recovery verdicts stay `NOT_RUN`
- Validator refuses `SIMULATOR_PASS` unless a P-iOS-5 fault fixture is present
  (and same-candidate artifacts cover all five steps)
- Required fixture API (capability level): fail-closed runtime fault that
  refuses silent DIRECT as Access success, plus recoverable PROXY-ready path

When P-iOS-5 lands: update-branch onto `develop`, flip
`AccessSitePhase1EvidenceFaultRequirement.isPending` in a follow-up if the
drill binds the concrete symbols, and re-run the validator.

## Evidence rules (A4)

- Same candidate SHA for logs, correlation IDs, and on/off UI captures
- Simulator candidate may record `SIMULATOR_PASS`
- Device / TestFlight remain `NOT_RUN` / out of scope (not a release gate)
- Unit / CI green ≠ product `SIMULATOR_PASS`
- Do not stitch different SHAs into PASS
- Direct page success must never be recorded as Access success

## Non-goals

- Claiming `SIMULATOR_PASS` without filled same-candidate artifacts
- Claiming device / TestFlight PASS on this track
- Claiming P-iOS-4 DEV panel PASS while that feat is open
- Replacing the F14 engineering matrix
- macOS evidence pack (P-mac-6)
