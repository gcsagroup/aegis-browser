# Aegis Browser Copilot review instructions

Use these instructions primarily for pull-request review. Focus on defects, security/privacy regressions, incorrect assumptions, missing tests, and delivery-governance violations. Avoid repeating formatting or low-value style findings that deterministic tooling already covers.

## Review priorities

- Verify behavior and invariants, including error paths, cancellation, lifecycle changes, concurrency, ownership, compatibility, and state transitions.
- Treat browser/network routing, privacy controls, credential or secret handling, update/install paths, native integration, and CI/release governance as security-sensitive.
- For product feature changes, verify that the same PR contains executable unit tests for the new logic and at least one regression test for an existing safety/compatibility invariant or a relevant historical failure.
- Read the surrounding implementation when a diff changes an interface or shared contract. Flag callers, serializers, generated data, platform adapters, or tests that must change together.
- Prefer findings that identify a concrete trigger, impact, and verification method. Do not invent findings merely to produce review output.

## Delivery evidence boundaries

- `docs/development/ci.zh-CN.md` is the delivery authority for the personal fork. Follow its current `develop` branch flow and evidence identity rules.
- GitHub Copilot review is semantic review evidence only. It does not replace the independent reviewer, hosted CI, Codacy, human approval requirements, Chromium integration evidence, device evidence, signing, or release acceptance.
- Codacy is the deterministic quality/security scanner. Do not duplicate a Codacy-style finding unless it has a concrete semantic, security, or compatibility impact that the PR author should act on.
- Do not infer a green `quality-gate`, Codacy result, branch protection, server-side setting, or merge readiness from repository text, badges, comments, or local output. Those states require live evidence for the exact final head.
- Preserve the H/B/M/S distinction documented by the project: PR head, PR base, GitHub merge candidate, and post-merge branch commit are separate evidence identities.

## Public-upstream review

- Public export must follow the promotion path documented in `docs/development/ci.zh-CN.md`; do not recommend sending `develop` directly to upstream `main`.
- Flag any public-export history that adds, modifies, deletes, or renames private agent-control files such as `AGENTS.md` or case variants.
- The three README files on the public promotion path follow the repository's temporary upstream-mirroring rule; do not treat their deliberate restoration from upstream as accidental data loss.

Keep review comments concise and actionable. When reporting a finding, name the affected file/line, the trigger, the likely impact, and the smallest useful fix or test.
