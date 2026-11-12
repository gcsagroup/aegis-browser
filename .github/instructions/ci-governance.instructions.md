---
applyTo: ".github/workflows/**/*.yml,.github/workflows/**/*.yaml,.github/copilot-instructions.md,.github/instructions/**/*.instructions.md,scripts/ci/**/*.mjs,.codacy.yml,.mise.toml,package.json,pnpm-lock.yaml,pnpm-workspace.yaml,docs/development/ci.zh-CN.md,docs/github-upstream-ci.zh-CN.md"
---

# CI and governance review

Use [the CI guide](../../docs/development/ci.zh-CN.md) for the current required result set and promotion flow.

- Preserve macOS `quality` + `quality-gate` as the automatic blocking route. iOS/Android/Linux/Windows reporting stays manual unless policy explicitly changes. Missing, skipped, cancelled, timed-out, stale or substitute jobs cannot satisfy required results.
- Bind PR results to exact B/H/M and branch-push results to S, including run attempt and check source. A push, rebase, conflict resolution or base advance invalidates mismatched evidence. Repository files do not prove live branch protection, service settings or scanner authorization.
- Use least-privilege tokens; untrusted PR code never receives repository secrets. The sole `pull_request_target` exception is PR-title metadata: exact base checkout, persisted credentials disabled, metadata writes only, and no PR-head code execution/inspection under that token.
- Keep upstream Codacy, independent review, hosted CI and applicable integration evidence separate. Copilot review is optional. Preserve distinctions among product failures, infrastructure/account failures, identity/governance mismatches and unavailable Chromium integration.
- The promotion controller runs only in trusted personal-develop push/schedule/manual contexts with the direct-upstream-v2 guard. It advances one state per serialized run, uses read-only `GITHUB_TOKEN` plus dedicated mutation secrets, and never force-pushes. Main divergence stops it; it cannot approve, merge or enable auto-merge on candidates.
- Personal main is a locked upstream mirror with admin enforcement and controlled fast-forward sync. Freeze develop D/upstream B in a separate promotion branch, preserve appended fixes, rebind current H/M, and backflow upstream S to develop before the next batch. No product PRs, README exceptions or extra sync commits on personal main.
