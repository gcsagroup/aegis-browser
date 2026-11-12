# Optional Copilot review

Apply only when Copilot review is explicitly requested. It is supplementary evidence, not a Ready, merge or promotion prerequisite, and does not replace independent review, CI, upstream Codacy, Chromium integration, device, signing or release acceptance.

Report actionable defects with file/line, trigger, impact and a useful fix or test. Inspect affected callers/contracts and error, cancellation, lifecycle, concurrency and ownership paths. Browser/network routing, privacy, credentials, native integration, install/update and CI/release governance deserve security scrutiny. Avoid duplicating deterministic style findings without semantic impact.

Product feature PRs include executable unit tests for new logic and a regression for an existing safety/compatibility invariant or relevant historical failure.

[Development CI guide](../docs/development/ci.zh-CN.md) owns delivery and promotion. Preserve H/B/M/S identity: PR head, base, GitHub merge candidate and post-merge commit are separate evidence. Claim live protection, checks or merge readiness only from exact-candidate service evidence.

Public promotion freezes develop into an independent upstream-main branch; personal main stays an exact fast-forward mirror. Review fixes return to develop after upstream merge. Flag any public-export commit that adds, changes, removes or renames private agent-control files such as `AGENTS.md` or case variants. README/workflow sources remain shared; there is no README replacement exception. Upstream Codacy is required where the guide specifies it; synchronization alone does not authorize release.
