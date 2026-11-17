# iOS delivery Bot

## Intent and authorization

The maintainer authorized the proposed dedicated GitHub App integration and a
1.1.0 Beta upload to TestFlight on 2026-11-17. Reuse the existing delivery engine,
protected signing/store environments and immutable package receipts.

## Approach

Use a dedicated GitHub App with Actions write and Contents read. The maintainer
subsequently limited installation to the explicit inventory of `gcsagroup`
repositories where their account has effective Admin or Owner access. Personal
account installations are excluded. This iOS controller
still requests tokens limited to the canonical Aegis repository. An Admin starts
a controller on current main; the
controller exchanges its protected App key for a repository-scoped, short-lived
installation token and dispatches the existing Simple/Full workflow. External
automation may use that same App identity. An Admin PAT would retain unnecessary
human privileges; replacing the delivery engine would duplicate signing and
replay controls. Both alternatives are excluded.

The controller supports Package, Package and upload, Draft, Status and Wait.
Package and upload automatically follows its successful producer with read-only
Wait. Draft retains the existing requirement for an Admin-created candidate tag;
the Bot does not gain candidate-tag creation or public release authority.
Public GitHub publication, external TestFlight distribution and App Store review
remain explicit administrator operations.

## Identity and source

Bot admission is opt-in through repository configuration pinning App ID, slug and
numeric Bot user ID. Resolve the App and Bot identity from GitHub, compare the
run's original and triggering principals, and reject unknown Bots. Human
principals still require actual Admin grants. Allow the App only for delivery
dispatches on main with the exact approved source SHA and the five operations
above. Local CLI, cleanup, validation, coverage and candidate pushes retain Admin
admission. The original request's SHA must match the runtime SHA, including in
every protected job; a branch move fails closed.

## Execution and recovery

Use GitHub's dispatch response run ID; never select the latest run. Bind run,
attempt, repository, workflow, actor and SHA while monitoring. Write each known
dispatch receipt immediately, and retain producer completion before starting any
later stage, including when polling or a subsequent Wait fails. Do not retry writes
or rerun producers. A failed or ambiguous dispatch/upload preserves the original
identity and requires status reconciliation. Refresh installation tokens only as
needed while polling. The Bot key stays in its own protected controller
environment and is never passed to signing/store jobs or printed.

The workflow shell adapter validates an existing, owned, non-symlink summary
command file under the canonical runner temporary directory before starting the
App client, and streams receipts there while preserving controller failure codes.
Version components are checked individually as bounded ASCII decimals.

## Acceptance

Behavior tests cover configured Bot acceptance, impersonation, lower human roles,
reruns, wrong event/workflow/source, disallowed operations, token scoping and
redaction, exact child-run monitoring, producer failure and dispatch ambiguity.
Run the repository gates and a fresh read-only independent review before code
handoff. Installation and protected-environment approvals are separate live gates.
The Beta is accepted only after source-bound package/upload evidence and Apple's
VALID state for the exact version/build; upload alone is insufficient.
