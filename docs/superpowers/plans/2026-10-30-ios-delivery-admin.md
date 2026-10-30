# iOS Delivery and Administrator Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace three iOS delivery workflows with one Admin-only entrypoint, retain distinct quality workflows, and persist/verify the approved OS-only export declaration.

**Architecture:** Share administrator verification between source preflight/local operations and a canonical-only workflow admission job. Normalize package/store/tag modes without changing existing immutable artifact or explicit-stage semantics. Retain the existing signing, Draft and store environment separation.

**Tech Stack:** Node22.23.1, Python3.11+, Ruby3.3.6/Fastlane2.241.0, pinned Actions, existing installed Apple signing material and protected ASC credentials.

**Spec:** docs/superpowers/specs/2026-10-30-ios-delivery-admin-design.md

## Global Constraints

- Scope is iOS only. Source37 nine-row acceptance and ten original-source uploads are complete and remain separate evidence.
- Canonical upstream repository ID1348409663; privileged fork delivery remains retired. No shared VM/proxy/service, signing ACL/timeout or main protection changes.
- Admin base grant includes organization owners; both original and triggering actors must pass. Deny Maintain/Write/Read/unknown/API failure before credentials or private-key use.
- Three active iOS purposes: Delivery, Release Validation, Coverage. PR/push quality remains uncredentialed; manual iOS actions require Admin.
- Explicit package/store stages. Tag only produces a private Draft; no implicit TF upload, external review or formal submission.
- Keep source SHA/tree, manifest hashes, original run/attempt and mutation intents. No unknown-upload retries, resigning/rebinding old IPA identities or historical-run deletion.
- Persist boolean ITSAppUsesNonExemptEncryption=false only for the approved current OS-only implementation. Only the source plist declaration may change among native inputs; new source/native digests must be recorded.
- Real free disk reserves: internal8GiB/external15GiB. No private key/password in argv, logs or Git; no private signing-key export.

## Review Focus

- Original Admin with a Write/Maintain rerunner must be denied, including mismatched IDs and incomplete admin inventories.
- A denied dispatch or skipped pre-stage job must not block the later real Admin; a possibly started mutation must block replay.
- A package versus store operation must never take the other artifact/credential path; tags must normalize exact immutable identity.
- A readonly/store/native-runner entrypoint must not use credentials or a signing probe before checking the real operator.
- Exported plist missing/wrong/non-boolean declaration must fail when committed source declares it; legacy absent-key packages are checked against legacy source.

---

### Task1: Shared administrator authorization and credential boundaries

**Files:**
- Create scripts/ci/ios-operator.mjs and scripts/ci/tests/ios-operator.test.mjs.
- Modify scripts/ci/ios-release-preflight.mjs, fastlane/lib/release.rb, scripts/release/ios-runner.py.
- Modify focused Node/Ruby/Python boundary tests.

**Interfaces:**
- `requireIosAdministrator({environment, api, userApi, context})` returns verified principal/run/repository metadata or throws; CI uses installation-token-compatible filtered admin list, local uses actual authenticated user.
- `verifyAdminMetadataCapability({repository, token, api})` performs a readonly capability probe without printing the roster.
- Pipeline authorization runs before ASC authentication/private signing inputs; source admission remains current-main/quality verification. Runner launcher checks canonical repository and actual CLI administrator before probe/registration.

- [ ] Write RED tests for Admin/owner positive, every lower/unknown role, spoofed identity, both rerun directions, malformed/incomplete pages and API errors; assert zero credential/probe work on denial.
- [ ] Run focused tests and confirm failure against absent/current behavior.
- [ ] Implement the operator module and minimal boundary integration; preserve existing source gates and uncredentialed plan.
- [ ] Run focused tests and existing Ruby/Python suites; record GREEN and commit only this coherent authorization deliverable.

### Task2: One delivery entrypoint and immutable transport routing

**Files:**
- Create .github/workflows/ios-delivery.yml and scripts/release/ios-delivery-plan.py.
- Delete .github/workflows/ios-release.yml, ios-testflight.yml and ios-candidate.yml after migration.
- Modify scripts/release/ios-action.py, ios-restore.py, artifact-transport.py, ios-runner.py trust paths and prior-stage handling.
- Modify scripts/ci/tests/ios-release.test.mjs, add planner/transport regressions.
- Modify manual guards/capability probe in ios-release-validation.yml and ios-coverage.yml; preserve automatic quality.
- Update docs/development/ios-release.md, .zh-CN.md and .zh-TW.md.

**Interfaces:**
- Planner consumes trusted event/ref plus manual inputs and emits operation/profile/version/build/destination/tag and validated producer/state identifiers via GITHUB_OUTPUT.
- `operation=package` routes only to package/optional Draft; existing store operations route only to import/store. Original package must come from a completed successful selected run; current-run Draft requires completed exact package job.
- Prior-stage admission scans the unified workflow by normalized stage/digest title, ignores conclusively unstarted/skipped store jobs, and rejects possibly executed mutations outside imported completed state.

- [ ] Write RED planner/DAG tests for manual defaults, all profile/destination combinations, exact tag normalization, unknown input/stage, wrong source/attempt and unauthorized skip paths.
- [ ] Add RED transport cases for the new workflow path, denied-run non-poisoning, unknown prior mutation and recovered completed journal.
- [ ] Implement normalized unified workflow, explicit Admin dependencies, minimal per-job permissions and new-path provenance; remove branch-push rehearsal packaging and the three old delivery files.
- [ ] Apply manual-only Admin guards and readonly installation-token capability probe to quality workflows; retain original quality purpose/scheduling.
- [ ] Rewrite operator docs around one workflow and explicit stages, including GitHub UI dispatch limitation and safe recovery.
- [ ] Run Node/Ruby/Python regressions, lint/actionlint, inspect no secret/actor input bypass and commit.

### Task3: Source and exported encryption declaration

**Files:**
- Modify apps/ios/AegisApp/Info.plist, scripts/release/verify-signed-ios.py and scripts/release/test_verify_signed_ios.py.
- Update related release documentation.

**Interfaces:**
- Source declares a boolean false key. Verifier compares that committed declaration to the exported app; absence in historical source remains compatible with historical IPA.
- Native-input digest changes are acknowledged; native code/library/resource bytes remain unchanged apart from the one source plist key.

- [ ] Add RED cases for matching false, missing/mismatched/non-boolean exported values and legacy no-key compatibility.
- [ ] Add boolean key and strict source/export comparison; do not hardcode a false declaration independent of source.
- [ ] Run verifier regressions and prove the native-input diff is limited to this one plist key; commit.

### Task4: Review, independent PR, normal merge and live retest

**Files:** implementation only; private evidence/state remains under this iOS owner.

- [ ] Run complete relevant suites and clean-source full quality against current upstream; exact-source uncredentialed CI/archive and actual GITHUB_TOKEN admin-list capability must pass.
- [ ] Obtain one fresh whole-branch security review, repair material findings with meaningful regressions, and create/attach an iOS-only upstream PR from the fork.
- [ ] Follow all required/added checks without bypass, merge the passed PR under existing user authorization, then wait for fresh main gates.
- [ ] Run fresh live-checked identities for local Fastlane Alpha, unified manual Beta, candidate Tag Release and default-Alpha unified delivery. Every generated IPA uploads to TF and reads VALID/native audience/automatic usesNonExemptEncryption=false before explicit compliance mutation. Reuse upload state for metadata/internal assignment.
- [ ] Actually download/verify CI and Draft assets. Preserve historical runs/TF builds; disable obsolete indexed entrypoints only after the new one is qualified.
- [ ] Read back active workflow inventory, Admin configuration/gates, canonical source/settings, artifacts/TF states and disk reserves. Keep non-Admin real-account evidence honestly distinguished from fixture/DAG denial tests and physical-device proof unverified.
- [ ] Record complete source-bound evidence in ios.json; hand off final iOS evidence without resuming paused other-platform controllers.
