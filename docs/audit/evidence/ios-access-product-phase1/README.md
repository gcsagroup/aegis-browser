# iOS Access product Phase 1 — five-step evidence pack

Acceptance: `docs/plans/access-product-phase1-acceptance.zh-CN.md` (A2 + A4).  
Feat: P-iOS-6. Parent epic: upstream #98 / fork tracking via #104.  
Engineering F14 matrix (unit inventory only): `docs/audit/ios-access-simulator-evidence-2026-11-08.md`.

## Status

This directory is the **product** pack scaffold (A2-5 / A4). Until a same-candidate
Simulator run fills artifacts, product status stays `NOT_RUN`. Unit greens, CI
green, and the F14 engineering matrix must not be upgraded to `SIMULATOR_PASS`.

Device / TestFlight remain **`NOT_RUN` / out of scope** for this pack. Do not
internally promote `SIMULATOR_PASS` into a release gate.

Exit criteria for this pack claim: **P-iOS-1 + 2 + 3 + 5 + 6**. DEV-only P-iOS-4
is out of scope for the pack exit claim while unfinished.

### Fault step dependency

A2-3 (fault, no silent DIRECT) and A2-4 (recovery) require the fail-closed
fixture API from **P-iOS-5** (`feat/ios-access-fault-no-direct-2cd7`). While that
PR is not on `develop`, treat the **fault** (and recovery) step as **pending**:
scaffold verdicts stay `NOT_RUN`, and `SIMULATOR_PASS` is refused until the
fault fixture is present and same-candidate artifacts cover those steps.

## Correlation ID

Format (see `correlation.md`):

```text
aegis-ios-p1/<candidate8>/<run_id>/<step>
```

Steps: `on` | `load` | `fault` | `recovery` | `off` (A2-1..A2-5).

Emit the same ID in browser/AccessKit logs, node-side traces, and (optional)
screenshot filenames so one operation can be joined without stitching SHAs.

## Operator path (iOS Simulator)

1. Build a Simulator candidate; record `sourceSha` (40 hex) and channel (`SIMULATOR`).
2. Copy `manifest.template.json` → `manifest.json`; set identity + `runId`.
3. From a clean Profile, run the five steps on a controlled host with an
   authorized Reality node (never use DIRECT success as Access success):
   - **on** — site-proxy enable → ready or readable failure
   - **load** — navigate; confirm page via PROXY exit; attach log lines with `…/load`
   - **fault** — stop node / inject fault; new requests Fail/Wait, no DIRECT
     (requires P-iOS-5 API)
   - **recovery** — restore node; ready again via PROXY
   - **off** — disable; native connection restored (ProxyConfiguration cleared)
4. Attach per-step artifacts (logs required; on/off UI captures required for
   `SIMULATOR_PASS`).
5. Validate: `node apps/browser/scripts/ios-access-phase1-evidence.mjs --check docs/audit/evidence/ios-access-product-phase1`

## Fixture (non-PASS)

`AccessSitePhase1Evidence` correlation helpers lock the A2 step IDs and
`aegis-ios-p1/…` convention for Simulator unit hosts. They are **evidence
scaffolding**, not an A4 product `SIMULATOR_PASS`.

The full on→load→fault→recovery→off drill fixture binds to the P-iOS-5 fault
API; until that lands, only correlation helpers ship in-tree.

## Files

| File | Purpose |
| --- | --- |
| `manifest.template.json` | Schema + NOT_RUN template |
| `correlation.md` | ID convention |
| `status.json` | Current pack verdict (`NOT_RUN`) |
| `artifacts/` | Place same-candidate logs/UI captures here |
