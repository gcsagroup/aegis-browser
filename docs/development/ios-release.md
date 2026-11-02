# iOS release operations

One package has one immutable profile. Alpha is exported with native TestFlight internal testing only and must read back as `INTERNAL_ONLY`. Beta can use internal or external testing, but cannot enter production destinations or formal review. Release supports all destinations through explicit stages. Package, upload, processing, compliance, metadata, distribution and review are separate operations. No upload automatically requests review or releases publicly.

## Local stages

Use Ruby 3.3.6, the locked Bundler/Fastlane dependencies, Node 22.23.1, Python 3.11+ and Xcode on macOS. Start from a clean committed source. `bundle install` installs the pinned dependencies; `./release ios plan` prints source SHA/tree, native input digest and available stages without credentials. Every mutation requires an explicit profile.

```sh
./release ios package --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6
./release ios upload --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256
./release ios wait --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios status --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios compliance --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256 --input compliance.json
./release ios metadata --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256 --input metadata.json
./release ios distribute --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight-internal --groups 'Existing internal group' --manifest-sha256 MANIFEST_SHA256
```

Examples use an illustrative build number: query ASC first and choose an unused identity. Keep the digest independently from the package directory. The IPA, dSYM, manifest/checksum and completed upload journal must survive later stages. Moving to another source SHA/tree requires a new package. Package output is `.artifacts/release/ios/RUN_ID`; work/archive/DerivedData in that directory are rebuildable, delivery files and receipts are evidence. Do not remove an active directory. Verify the actual signed IPA, embedded profiles, certificate fingerprint, audience flag and committed shared resources; an unsigned archive does not qualify an IPA.

Set `AEGIS_APPLE_TEAM_ID`, `AEGIS_IOS_CERT_SHA1` and `AEGIS_IOS_PROFILES` (JSON mapping all three bundle IDs to existing App Store profile names) for packaging. The installed Apple Distribution key remains in its existing local keychain. Export no private signing key and change no shared keychain ACL/search list. Material names should describe their type, such as `Distribution.cer` or `AppStore.mobileprovision`.

ASC stages use `AEGIS_ASC_KEY_ID`, `AEGIS_ASC_ISSUER_ID` and either a private mode-600 `AEGIS_ASC_KEY_PATH` or `AEGIS_ASC_KEY_BASE64`. Supply credentials through a private environment/secret provider; never through command arguments, Git or public evidence. GitHub admission uses `GH_TOKEN` with read access, or a stage-specific token for Draft writes. Set `AEGIS_IOS_RELEASE_ENABLED=true`; upstream delivery requires the exact current main SHA and latest terminal successful `quality` and `quality-gate` jobs. Main/tag are read again immediately before mutation.

## Explicit inputs

`metadata.json` may contain only `locales`, with `description` (Beta app description) and/or `whatsNew` (this build's testing notes). Fields are nonempty strings up to 4000 characters. Existing feedback contacts, listing fields and other locales are preserved.

```json
{"locales":{"en-US":{"description":"Reviewed product description","whatsNew":"Changes in this exact build"},"zh-Hans":{"whatsNew":"本次构建的测试内容"}}}
```

`compliance.json` requires an explicit boolean, exact source and native digest from `plan`, and a statement of operator authorization. There is no default encryption answer. Reassess compliance when native inputs change; preserve conflicting existing ASC answers.

```json
{"usesNonExemptEncryption":false,"sourceSha":"EXACT_SHA","nativeInputsSha256":"EXACT_NATIVE_DIGEST","authorization":"Operator reviewed this source and authorized this answer"}
```

Status distinguishes build absence/processing/failure/VALID, buildUploads errors, native audience, encryption, beta states and assigned groups. Tester counts use Apple's raw tester `state`. `INSTALLED` is an account state; it does not prove this exact build ran on a physical device. Wait is bounded (`--timeout` 1..3600, `--interval` 1..60) and stops on failure, expiry or audience mismatch. Network uncertainty is reported, never translated into success.

## Actions and candidate tags

The manual entrypoints **iOS Delivery · 精简版 / Simple** and **iOS Delivery · 完整版 / Full** share one reusable backend. Full explicitly forwards the ASC and signing secret names; the called jobs retain `aegis-ios-store` and `aegis-ios-signing`, whose environment values override caller values. See [GitHub’s environment-secret rule](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#using-inputs-and-secrets-in-a-reusable-workflow). Both require the original operator and rerunner to be current effective repository Admins. Signing, Apple credentials and private Draft permissions remain in their existing protected environments. Local CLI commands retain their existing interface.

Simple has four bilingual fields: operation, version, build, and package product. Select **Package**, **Package and upload**, **Status**, or **Wait**. Enter a version such as `1.0.0` and build such as `35`; product is ignored for Status/Wait.

- Package creates a new IPA/dSYM/manifest without uploading.
- Package and upload first checks that Apple has no matching build or upload, then uploads the same newly signed package. It never distributes, submits for review, or publicly releases. Producer digest and exact run/attempt are passed directly between protected jobs; original package and uploaded-state artifacts are retained separately. Rerunning this combined operation is rejected; reconcile unknown outcomes before choosing a new build.
- Status directly queries the exact Apple version/build using a GET-only client. It requires no receipt, old artifact, package profile or historical source checkout. Missing builds return `NOT_FOUND`; there is no latest-build fallback. Audience cannot distinguish Beta from Release, and the query implementation SHA is not binary provenance.
- Wait is also read-only and bounded to five minutes. Missing uploads, rejection, expired builds and timeout stop without reuploading.

Full adds explicit private Draft, existing-package Upload, receipt-bound Wait, Metadata, Compliance and internal/external Distribution. Use version/build for packaging, Draft or read-only queries. For existing-package store stages paste the complete **Delivery receipt** from the latest successful run Summary, keep Product on Auto, and supply existing groups or reviewed stage JSON only where needed. Version/build alone never authorizes a mutation.

The original `aegis-ios-v1` receipt remains valid. A completed upload within its original package run emits `aegis-ios-v2:...:uploaded` to preserve completed-upload state when producer and state run IDs coincide. Both retain immutable profile/version/build, original producer, exact state attempt and independently pinned manifest digest. Receipts grant no permission; repository Admin, producer success, source/tree, artifact and journal/replay checks remain independent. Wait for the whole run to succeed before using a receipt.

Alpha is internal-only; Beta allows internal/external testing and blocks formal App Store submission; Release requires explicit stages. External distribution requests Beta Review and needs separate authorization. Neither workflow offers formal submission or public publishing. Candidate tags still only create packages and private Drafts.

The uncredentialed import job checks repository, admitted workflow, latest attempt, successful producer, original package origin, SHA/tree, manifest/assets and completed upload receipt. Protected jobs independently recheck identity and authorization before loading ASC credentials. External TF distribution requests Beta App Review and needs separate authorization. Formal App Store review remains a separate explicit Release-only local stage; neither review is an automatic acceptance test.

Configure repository variable `AEGIS_IOS_RELEASE_ENABLED=false` first. Configure protected environments with custom deployment branch/tag policies, exact approved branch/main and `candidate/ios/*` tags as appropriate; no PR deployment refs. In `aegis-ios-signing`, retain `AEGIS_APPLE_TEAM_ID`, `AEGIS_IOS_CERT_SHA1` and `AEGIS_IOS_PROFILES` as variables. Add encrypted environment secrets `AEGIS_IOS_DISTRIBUTION_P12_BASE64` (single-line base64 of the existing Apple Distribution certificate and private key), `AEGIS_IOS_DISTRIBUTION_P12_PASSWORD`, and `AEGIS_IOS_APP_PROFILE_BASE64`, `AEGIS_IOS_SAFARI_PROFILE_BASE64`, `AEGIS_IOS_SHARE_PROFILE_BASE64` (single-line base64 of the respective existing App Store provisioning profiles). The package job uses an ephemeral GitHub-hosted Mac, validates each profile against the configured team, name, target and certificate, and removes its temporary keychain and profiles after packaging. Do not print, commit, or put these secrets in artifacts or the store environment. Add only ASC key ID/issuer/base64 key as encrypted secrets in `aegis-ios-store`. Enable iOS only after passed main CI and configuration readback.

Privileged fork delivery is retired. The delivery gate, local admission and owned signing-runner launcher accept only canonical `gcsagroup/aegis-browser` repository ID1348409663; old rehearsal flags cannot reopen it. Fork PR/quality checks remain uncredentialed. Historical workflows, runs, tags and artifacts remain evidence, rather than active duplicate delivery entrypoints.

The repository-provided `scripts/release/ios-runner.py` launcher is **disabled**. Even a verified Admin request is refused before payload access, installed-key probes, runner registration or listener startup. Queue snapshots, unique labels and identity checks after execution cannot prevent another job from running on a signing host. There is no bypass flag. Re-enabling this entrypoint requires separately reviewed, fail-closed pre-execution authorization or server-enforced workflow isolation; existing validation helpers alone do not establish that boundary. Source validation, package/receipt contracts and read-only queries remain available. Do not provision a shared or manually labelled runner as a workaround. This change does not remove or alter any existing host, keychain or registration.

## Recovery, migration and evidence

A mutation writes an immutable started record before the call and a result after verified completion. A lost response leaves an unknown intent. Mutation reruns are rejected at both import and protected restore unless the completed identical journal has been recovered and independently verified; failed attempts require explicit readback reconciliation. Reusing a completed identical stage is idempotent; changed parameters or an unresolved intent are rejected. Actions also checks earlier runs of the identical stage/manifest to prevent a new job silently discarding an unknown journal. An earlier denied dispatch or skipped store job does not block a later Admin only when every attempt conclusively contains no executed store job. Any possibly started mutation or incomplete inventory remains blocked. Do not rerun a failed upload blindly: read exact buildUploads/build/group/metadata state and inspect the failed run's preserved artifact. Reconcile known remote results with independently retained evidence before restoring a receipt; otherwise stop and use a new explicitly chosen build. No command fabricates a completion receipt automatically.

Merge only after required upstream checks and iOS validation pass, follow fresh merged-main CI, then repeat all methods on the new merged source: manual Fastlane, Actions package and Tag/private Draft, each with Alpha/Beta/Release and unique unused builds. Download and verify each artifact; upload that same IPA to TF and read back VALID plus its audience. Reuse completed uploads for representative compliance, metadata and internal distribution checks. Report package, Actions, Draft, upload, processing, group availability, device proof and review states independently. Contract coverage of review routes is not a real review submission.

After upstream delivery passes, read and snapshot fork iOS settings, disable only `AEGIS_IOS_RELEASE_ENABLED` on the fork and retire its iOS-specific environment admission. Retain source, tags, Drafts, TF builds and evidence. Rollback consists of restoring the reviewed iOS environment policies and iOS activation variables against a newly verified source; repeat admission and delivery checks. Do not change shared all-platform release flags or another platform's state/services.

The committed app Info.plist declares Boolean `ITSAppUsesNonExemptEncryption=false` for the reviewed Apple-OS-only encryption implementation. Export verification compares this declaration with the signed app. Reassess it when encryption code/libraries change; historical packages retain their original bytes. Confirm TF reads `usesNonExemptEncryption=false` before any explicit compliance update.

Admin-only candidate Tag protection is independent of workflow code. Apply [the scoped ruleset](../../.github/ios-candidate-admin-ruleset.json) to `refs/tags/candidate/ios/**/*`: restrict creation/update/deletion with only repository Admin bypass. Prepare it disabled, verify GraphQL `repositoryRoleName=admin` for role ID5, then activate and run `node scripts/ci/ios-operator.mjs --verify-candidate-tag-policy` with the actual Admin token. Do not widen bypass actors or tag patterns. This delivery boundary assumes passed main code is trusted; changing shared main review governance is separate work.
