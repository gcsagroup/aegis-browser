# P-mac-6 — macOS product Phase 1 five-step evidence pack

## Scope

Ships the product Phase 1 **evidence pack** for macOS: five-step drill fixture
(B2-1..B2-5), correlation ID convention (B4 / P0-4), operator README, and a
pack validator that **refuses PASS** from overlay unit tests alone.

Depends on P-mac-3 (bubble session) and P-mac-5 (fault fail-closed). Exit
criteria covered: **1 + 2 + 3 + 5 + 6**. DEV-only P-mac-4 is **not** required
for this exit and must not be claimed PASS while still open.

| Piece | Role |
| --- | --- |
| `AccessSiteProxyPhase1EvidenceStepId` | on / load / fault / recovery / off |
| `BuildPhase1EvidenceCorrelationId` | `aegis-mac-p1/<sha8>/<run>/<step>` |
| `RunSiteProxyPhase1EvidenceDrill` | Session+route contract drill with IDs |
| Pack under `docs/audit/evidence/macos-access-product-phase1/` | Operator path + manifest template |
| `macos-access-phase1-evidence.mjs` | Schema + anti-拼证 validator |
| Patch `0355` | Keeps Chromium series synced with overlay (after merged P-mac-4 `0354`) |

## Flow (B2)

1. **On (B2-1):** toolbar / session enable → Publish/ACK → ready; correlation `…/on`
2. **Load (B2-2):** navigation/subresource plans `UseRegisteredProxy`; correlation `…/load`
3. **Fault (B2-3):** runtime fault → Fail or Wait; never silent DIRECT; `…/fault`
4. **Recovery (B2-4):** recover → PROXY republish → ready; `…/recovery`
5. **Off (B2-5):** disable → native / PreserveNative; `…/off`

## Evidence rules (B4)

- Same candidate SHA for logs, correlation IDs, and on/off UI captures
- Launchable macOS build required; overlay unit green ≠ product PASS
- Do not stitch different SHAs or CI-only greens into PASS
- Direct page success must never be recorded as Access success

## Non-goals

- Claiming native B4 PASS without filled pack artifacts
- Claiming P-mac-4 DEV panel PASS while that feat is open
- iOS product evidence pack (P-iOS-6) — see
  `docs/audit/evidence/ios-access-product-phase1/`
