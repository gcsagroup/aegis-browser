# iOS Delivery Bot Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline with one owner and the repository's built-in independent review.

**Goal:** Add a dedicated App operator to existing iOS delivery and upload 1.1.0 Beta to TestFlight.

**Architecture:** Pin App identity, source and permitted stages at existing admission. A protected Admin-started controller mints a scoped installation token and drives exact child runs through existing delivery workflows.

**Tech Stack:** Node 22.23.1, Python 3.11.9, GitHub Actions and existing Fastlane delivery.

**Spec:** `docs/superpowers/specs/2026-11-17-ios-delivery-bot-design.md`

## Global Constraints

- Canonical repository only; Bot dispatches current main with an approved full SHA.
- Bot operations: Package, Package and upload, Draft, Status and Wait.
- Keep Admin, candidate-tag, protected-environment and replay controls.
- No automatic public release, external distribution or App Store review.
- Never retry mutation requests after unknown outcomes.

## Review Focus

- A different App or misleading Bot login must not borrow the configured identity.
- Rerunners must be independently authorized; source movement must stop delivery.
- Lost dispatch responses must not create a second upload.
- Token requests must be limited to the canonical repository and required permissions.
- Failed child runs must stop orchestration before later stages.

### Task 1: Operator and source admission

**Files:** `scripts/ci/ios-operator.mjs`, `scripts/ci/tests/ios-operator.test.mjs`, `scripts/release/ios-delivery-plan.py`, workflow Simple/Full inputs.

- [x] Write Bot acceptance and rejection behavior tests; run and observe expected failures.
- [x] Implement pinned App verification and approved-source input without changing human admission.
- [x] Run operator and delivery-plan regressions.

### Task 2: Scoped App controller

**Files:** `scripts/ci/ios-delivery-bot.mjs`, `scripts/ci/run-ios-delivery-bot.sh`, `scripts/ci/tests/ios-delivery-bot.test.mjs`, `scripts/release/test_ios_delivery_bot_summary.py`, `.github/workflows/ios-delivery-bot.yml`.

- [x] Write tests for request scope, exact run identity, failure and ambiguous writes.
- [x] Implement token exchange, dispatch, bounded polling and automatic Wait after upload.
- [x] Add protected Admin-started controller and focused workflow behavior checks.

### Task 3: Validation and delivery

**Files:** `docs/development/ios-delivery-actions.md` and implementation evidence.

- [x] Document configuration, approved operations and recovery.
- [ ] Run full repository gates; bind raw evidence and complete diff to candidate SHA.
- [ ] Run `codex review` with Astra/xhigh/read-only; fix and re-review relevant changes.
- [ ] Deliver through repository PR gates and prepare exact App installation permissions.
- [ ] Query unused 1.1.0 build, package/upload Beta and wait for exact Apple VALID state.
