# iOS Independent Release and Upstream Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an iOS-only release framework from the fork through a passed upstream PR, merge it, migrate iOS delivery upstream, and retest every delivery method/profile after merge.

**Architecture:** Extract the accepted iOS pipeline and minimal source-bound receipt/journal/Draft foundations; omit Android/macOS implementation. Add portable lifecycle commands for operations previously performed by task-local helpers. Keep uncredentialed source/contract admission, protected signing, protected store operations and private Draft publication separate.

**Tech Stack:** Ruby 3.3.6, Bundler 2.5.22, Fastlane 2.241.0 (existing lock), Node 22.23.1, Python 3.11+, GitHub Actions, Xcode, existing installed Apple Distribution material and ASC API credentials.

**Spec:** docs/superpowers/specs/2026-10-30-ios-release-upstream-design.md

## Global Constraints

- User authorized one independent iOS PR and merge only after checks pass; the previous three-platform PR gate is superseded for iOS.
- No public release, external Beta review or formal App Store submission is executed.
- Preserve historical ded7afe candidate, its workspace, 1.0.0(1..5), archived evidence and all other platform state/configuration.
- Exact upstream repository ID 1348409663; fork ID 1363949860 and verified parent. Refresh upstream main before creating candidate, merge and source admission.
- Alpha native INTERNAL_ONLY; Beta testing-only and production-submit rejected; Release destinations require explicit stage. Workflow default Alpha/package.
- No private code-signing-key export; no credentials/passwords in argv, Git or logs; signing material names have no dates or beta labels.
- At least 8 GiB internal and 15 GiB external real free space; no shared keychain/VM/proxy/CI-service/SSD-root permission changes.
- Stage journal is immutable, completed stage is reusable, unknown mutation is reconciled through store readback before further action.
- Only the iOS platform state is written. Source and evidence for other platforms remain untouched.

## Review Focus

- Imported artifact/receipt substitution, wrong run/repository/source/attempt, and main advancing between validation and mutation must fail before credentials or mutation.
- A transport failure after successful upload, partial metadata updates, and runner registration uncertainty must never cause automatic duplicate mutations.
- Alpha audience and wrong group type/name/ID must be checked against live data before testing distribution; raw tester state must not imply installation of this build.
- Metadata preserves unrelated locales/contact fields; compliance has explicit authorization and source/native-input scope rather than a default legal answer.
- Runner package startup dependencies, foreign queued jobs, ZIP path/link attacks and disk reserve violations fail before privileged work.

### Task 1: Isolated upstream baseline and iOS receipt/packaging foundation

**Files:** release; Gemfile; Gemfile.lock; .ruby-version; .gitignore; fastlane/Fastfile; fastlane/lib/release.rb; fastlane/lib/stores.rb (Apple only); fastlane/tests/release_test.rb; fastlane/tests/stores_test.rb; scripts/release/cli.rb; scripts/release/verify-ios-archive.py; scripts/release/verify-ipa.py; scripts/release/safari_manifest.py; their fixtures/tests; necessary apps/ios compilation/resources/project inputs only.

**Interfaces:** AegisRelease::Request(platform, options, root:), Receipt.create/verify, Journal.perform, Pipeline.package/upload/status/distribute/submit; iOS-only destinations and immutable profile/source identity. Existing ./release ios syntax remains usable.

- [ ] Create a separate native-managed worktree from refreshed upstream main; create codex/ios-release-upstream-20261030. Preserve old accepted worktree.
- [ ] Record baseline, dependency paths and relevant baseline tests. Bring over locked Ruby dependencies without copying credentials or caches into Git.
- [ ] Port meaningful request/receipt/journal/IPA tests first; run and record failures for missing implementation.
- [ ] Extract only necessary common and iOS code from ded7afe, add required native iOS repairs, omit Android/macOS routes, brand changes, patches and store clients.
- [ ] Add deep signed-package/resource verification driven by explicit signing expectations and exact source manifest. Test malformed archives, substitution, mismatched profile/team and missing resources.
- [ ] Run Ruby contracts, Python archive/IPA checks, CLI plans, real Fastlane lane loading and unsigned native compilation; commit the scoped foundation.

### Task 2: Durable exact-build lifecycle, metadata and compliance

**Files:** fastlane/lib/stores.rb or focused ios_* modules; fastlane/Fastfile; scripts/release/cli.rb; lifecycle tests under fastlane/tests; portable artifact/runner helpers under scripts/release with Python tests.

**Interfaces:** AppleStore.read exact build/uploads; explicit wait/status, metadata JSON, compliance declaration and testing distribution stages. Mutations consume Request plus a verified manifest and completed exact upload receipt; stage receipts include operator input digests and readback result.

- [ ] Add failing cases for upload states NOT_FOUND/PROCESSING/FAILED/COMPLETE, wrong train/build, expired build and Alpha audience mismatch.
- [ ] Implement exact buildUploads and build/audience readback; bounded wait stops on Apple failure and preserves uncertainty on network failure.
- [ ] Test and implement validated metadata JSON locale fields description/whatsNew, preserving contacts/unrelated locales; journal and verify each intended operation.
- [ ] Test and implement explicit compliance declaration and source/native scope; preserve conflicting existing answers and reject unauthorized/default declarations.
- [ ] Test and implement internal/external route/group checks, current raw tester state reporting, and immutable restore/import of previous package/upload records.
- [ ] Add runner negative tests for missing templates, wrong queued job/repository, registration uncertainty and disk reserve; implement owned ephemeral helper and verification-only signing probe.
- [ ] Run targeted and related regressions, commit portable iOS lifecycle tools.

### Task 3: iOS-only Actions, admission, artifact reuse and documentation

**Files:** .github/workflows/ios-release-validation.yml; ios-release.yml; ios-candidate-tag.yml; ios-testflight.yml; scripts/ci/ios-release-preflight.mjs and tests; scripts/release/ios-action adapter/tag parser/artifact validation; docs/development/ios-release.{md,zh-CN.md,zh-TW.md}; minimal documentation index links; workflow contract tests.

**Interfaces:** iOS activation variable AEGIS_IOS_RELEASE_ENABLED; exact-source validation jobs; protected package outputs manifest digest/package run identity; store workflow accepts explicit package_run_id and upload_run_id for later stages, never implicit repackage/reupload. Existing repository quality-gate/Codacy requirements remain enforced.

- [ ] Write failing source-admission and workflow contract tests, including stale passing attempt, moved main/tag, wrong fork parent, PR-origin package, unexpected permission/credential propagation and unrelated artifact run.
- [ ] Implement credential-free validation (contracts and native unsigned archive); separate protected signing, private Draft and store jobs. Use SHA-pinned official actions.
- [ ] Implement import of previously completed same-source package artifacts and upload receipts for independent post-upload stages.
- [ ] Document all profile/destination/stage commands, input schemas, recovery/readback, signing/ASC config, upstream gates, evidence limits and fork rollback; include no host-private paths/IDs or PII in public docs.
- [ ] Run actionlint and relevant Node/Ruby/Python suites, review source/secret boundaries, commit iOS automation/docs.

### Task 4: Fork acceptance and passed independent upstream PR

**Files:** scoped implementation only; private evidence in the platform evidence directory; PR description references exact commits/runs/hashes without local private data.

- [ ] Verify full candidate diff from current upstream contains only iOS and required foundations; preserve all other platform changes outside the PR.
- [ ] Push fork branch; follow exact-source credential-free validation. Configure only narrow fork iOS environments/flags as needed, preserving existing other-platform settings.
- [ ] Run real signed Alpha/Beta/Release package checks and real fork Actions/Tag-to-private-Draft acceptance, downloading and verifying actual bytes.
- [ ] Allocate fresh build identities after live ASC preflight. Validate a new Alpha end-to-end upload, native INTERNAL_ONLY processing, same-source authorized compliance, build metadata readback and Aegis early access internal distribution; device proof stays separate.
- [ ] Review the final diff independently, repair in scope and revalidate changed source. Create an iOS-only upstream PR through the connected GitHub tool and attach it to the chat.
- [ ] Follow all actual PR/head/merge-candidate required checks including quality-gate/Codacy and added iOS checks. No bypass or merge while any required gate is unresolved.

### Task 5: Authorized merge, upstream setup and every-method retest

**Files:** no post-review source changes without normal revalidation; protected environment configuration, runner registration and private evidence only.

- [ ] Refresh current PR/base/checks, merge the passed iOS PR through normal controls, then bind to exact new main SHA/tree and wait for fresh main quality checks.
- [ ] Create upstream iOS-only protected signing, TF/store and Draft environments, constrained to main and planned exact candidate tags. Install existing authorized ASC API credentials as encrypted environment secrets through stdin/sealed API, without code-signing-key export. Read back metadata/settings only.
- [ ] Enable upstream iOS after gates pass and prepare task-owned ephemeral signing runner(s). Keep other platform flags and shared host services unchanged.
- [ ] Execute the upstream manual/Actions/Tag-Draft by Alpha/Beta/Release 3x3 package matrix, with unique unused builds and exact merged-source provenance. For every row verify real signed artifacts, hashes, audience export marker, resources and corresponding TF upload/VALID readback. Tag rows also require private Draft and downloaded asset verification.
- [ ] Exercise internal distribution, current audience/group/tester status, safe metadata and explicit compliance using the new upstream artifacts/receipts; do not repackage or reupload for later operations. Formal/external review paths remain simulation/contract coverage only.
- [ ] Retire only fork iOS activation/admission after upstream acceptance; preserve a read-verified rollback snapshot and all other platform configuration.
- [ ] Re-read upstream source/settings/Actions/ASC, verify retained historical builds, package/evidence digests and disk reserves; write complete iOS platform state and final migration report. Do not claim success from an enabled flag or PR merge alone.
