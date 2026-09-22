---
applyTo: ".github/workflows/**/*.yml,.github/workflows/**/*.yaml,.github/copilot-instructions.md,.github/instructions/**/*.instructions.md,scripts/ci/**/*.mjs,.codacy.yml,.mise.toml,package.json,pnpm-lock.yaml,pnpm-workspace.yaml,docs/development/ci.zh-CN.md,docs/github-upstream-ci.zh-CN.md"
---

# CI and governance review rules

- Preserve macOS `quality` plus `quality-gate` as the automatic blocking path unless the project policy explicitly changes. iOS, Android, Linux, and Windows reporting workflows are manual and must not silently become automatic blockers.
- `quality-gate` must accept the exact required result set documented by the project; missing, skipped, cancelled, timed-out, stale, or extra substitute jobs do not count as success.
- Keep PR evidence identities separate: PR workflows test GitHub's merge candidate M derived from exact B/H; branch push workflows test the resulting branch commit S. Never transfer a result across a rebase, new push, conflict resolution, base advance, or different run attempt.
- Keep workflow permissions least-privilege. Do not expose repository secrets to untrusted fork pull requests or add token-bearing upload steps without an explicit trust-boundary design.
- The PR-title metadata workflow is the sole `pull_request_target` exception: it may write only PR metadata, must check out the exact base SHA with persisted credentials disabled, and must never execute or inspect PR-head code under its write token.
- A repository file cannot prove a service-side setting such as branch protection, rulesets, Codacy authorization/default branch, Copilot automatic review, or approval policy. Require a live server-side readback before claiming those settings are active.
- Copilot review, upstream Codacy analysis, independent review, and hosted CI are separate evidence sources. A success in one does not waive the others.
- Preserve failure classification: product/test failure, infrastructure/account failure, governance/identity mismatch, and unavailable Chromium integration are distinct states and must not be collapsed into a generic pass/fail claim.
- Keep the promotion orchestrator on personal develop trusted `push` / `schedule` / manual contexts only, with the direct-upstream-v2 mode guard. It advances one state per serialized run, uses read-only `GITHUB_TOKEN`, requires dedicated repository secrets for fork/upstream mutations, never force-pushes, and must stop when personal/upstream `main` histories diverge.

- Personal main is locked with upstream syncing allowed and admin enforcement enabled. Mirror only by fast-forward from the actual upstream parent; no product PRs, force pushes, README exceptions or extra sync commits.
- Freeze develop D and upstream B into a separate upstream promotion branch; preserve appended review fixes, bind evidence to current H/M, and backflow upstream S into develop before the next batch. The controller must not approve, merge or enable auto-merge on candidates.
