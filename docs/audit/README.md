# Audit records

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

These files are dated, point-in-time engineering records. They preserve the evidence and release boundaries that were valid when written; they are not a live release-status page. Use the [roadmap](../roadmap.md) and a fresh `pnpm run browser:status` result for the current source/build relationship.

## Current boundary

- The current source carries 56 top-level Chromium patches plus 2 nested V8 patches.
- The latest macOS Release build-tree manifest binds only the earlier 54 + 2 state. It is local diagnostic evidence, not proof for patches 0055/0056 and not a signed or notarized distributable.
- Android, trusted build attestation, product identity, signing/notarization, install acceptance, and full outbound-traffic review remain open gates.
- Script-risk, MinerGuard, and bytecode-shadow work remains research-only or observe-only and does not authorize blocking or release claims.

## Records

- [Pre-implementation baseline](baseline-2026-08-24.md)
- [Implementation progress](implementation-progress-2026-08-24.md)
- [CPU and research optimization](cpu-and-research-optimization-2026-08-25.md)
- [Phishing detection gaps and roadmap](phishing-detection-gap-and-roadmap-2026-08-25.md)
- [JavaScript fingerprint hardening](js-fingerprint-hardening-2026-08-26.md)
- [JavaScript analysis and MinerGuard](js-miner-guard-2026-08-27.md)
- [Build identity and signing](js-build-identity-and-signing-2026-08-27.md)
- [Script-protection research phase 2](js-protection-research-phase2-2026-08-27.md)

The dated source records are retained in Simplified Chinese to avoid maintaining translated evidence copies that could drift. This trilingual index summarizes their scope; hashes, counts, and conclusions must be read from the original record and revalidated before reuse.
