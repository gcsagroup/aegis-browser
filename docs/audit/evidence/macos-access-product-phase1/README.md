# macOS Access product Phase 1 — five-step evidence pack

Acceptance: `docs/plans/access-product-phase1-acceptance.zh-CN.md` (B2 + B4).  
Feat: P-mac-6. Parent epic: upstream #98 / fork tracking #110.

## Status

This directory is the **pack scaffold**. Until a launchable macOS build fills
artifacts under one candidate SHA, product status stays `NOT_RUN`. Overlay
unit drills and CI green must not be upgraded to PASS.

Exit criteria for this pack: **P-mac-1 + 2 + 3 + 5 + 6**. P-mac-4 (DEV
ALLOW/BLOCK panel) is out of scope for the exit claim while unfinished.

## Correlation ID

Format (see `correlation.md`):

```text
aegis-mac-p1/<candidate8>/<run_id>/<step>
```

Steps: `on` | `load` | `fault` | `recovery` | `off` (B2-1..B2-5).

Emit the same ID in browser logs, node-side traces, and (optional) screenshot
filenames so one operation can be joined without stitching SHAs.

## Operator path (native macOS)

1. Build/sign a launchable candidate; record `sourceSha` (40 hex) and channel.
2. Copy `manifest.template.json` → `manifest.json`; set identity + `runId`.
3. From a clean Profile, run the five steps on a controlled host with an
   authorized Reality node (never use DIRECT success as Access success):
   - **on** — toolbar bubble enable → ready or readable failure
   - **load** — navigate; confirm page via PROXY exit; attach log lines with `…/load`
   - **fault** — stop node / inject fault; new requests Fail/Wait, no DIRECT
   - **recovery** — restore node; ready again via PROXY
   - **off** — disable; native connection restored
4. Attach per-step artifacts (logs required; on/off UI captures required for PASS).
5. Validate: `node apps/browser/scripts/macos-access-phase1-evidence.mjs --check docs/audit/evidence/macos-access-product-phase1`

## Fixture (non-PASS)

`RunSiteProxyPhase1EvidenceDrill` in
`access_site_proxy_phase1_evidence_fixture.h` locks the session/route contract
and correlation IDs for unit/browser hosts. It is **evidence scaffolding**,
not a B4 product PASS.

## Files

| File | Purpose |
| --- | --- |
| `manifest.template.json` | Schema + NOT_RUN template |
| `correlation.md` | ID convention |
| `status.json` | Current pack verdict (`NOT_RUN`) |
| `artifacts/` | Place same-candidate logs/UI captures here |
