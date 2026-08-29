# Audit records

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

These files are dated, point-in-time engineering records. They preserve the evidence and release boundaries that were valid when written; they are not a live release-status page. Use the [roadmap](../roadmap.md), a fresh `pnpm run browser:status` result, and the latest [iOS hardening record](ios-simulator-hardening-2026-08-28.md) with a new Simulator run for the current source/build relationship.

## Current boundary

- The combined source carries 67 top-level Chromium patches plus 2 nested V8 patches.
- The 57-patch diagnostic manifest and 65-patch Agent acceptance remain historical snapshots. Neither binds or qualifies the current 67-patch head.
- Android, trusted build attestation, product identity, signing/notarization, install acceptance, and full outbound-traffic review remain open gates.
- Script-risk, MinerGuard, and bytecode-shadow work remains research-only or observe-only and does not authorize blocking or release claims.
- Research corpora must remain separated: Phase 2 is a synthetic formal fixture; Phase 3 is a 13-sample operator-blinded public pilot with recall `1/3`. Neither result is generalizable.
- iOS evidence is Simulator-only. Real-device Safari/Share permissions, default-browser entitlement, Archive, formal signing, TestFlight, App Store, and release qualification remain No-Go gates.

## Records

- [Pre-implementation baseline](baseline-2026-08-24.md)
- [Implementation progress](implementation-progress-2026-08-24.md)
- [CPU and research optimization](cpu-and-research-optimization-2026-08-25.md)
- [Phishing detection gaps and roadmap](phishing-detection-gap-and-roadmap-2026-08-25.md)
- [JavaScript fingerprint hardening](js-fingerprint-hardening-2026-08-26.md)
- [JavaScript analysis and MinerGuard](js-miner-guard-2026-08-27.md)
- [Build identity and signing](js-build-identity-and-signing-2026-08-27.md)
- [Script-protection research phase 2](js-protection-research-phase2-2026-08-27.md)
- [Script-protection research phase 3](js-protection-research-phase3-2026-08-28.md)
- [iOS Simulator qualification — historical baseline](ios-simulator-qualification-2026-08-28.md)
- [iOS Simulator hardening — current local requalification](ios-simulator-hardening-2026-08-28.md)
- [Aegis Browser Agent v1 M0 baseline](aegis-agent-m0-baseline-2026-08-28.md)
- [Aegis Browser Agent v1 local acceptance](aegis-browser-agent-v1-acceptance-2026-08-29.md)
- [Aegis Browser Agent v1 security-fix verification](aegis-browser-agent-v1-security-fix-verification-2026-08-29.md)

The dated source records are retained in Simplified Chinese to avoid maintaining translated evidence copies that could drift. This trilingual index summarizes their scope; hashes, counts, and conclusions must be read from the original record and revalidated before reuse.
