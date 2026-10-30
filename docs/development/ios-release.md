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

`iOS Release Validation` has uncredentialed contract and unsigned native jobs. `iOS Package and Private Draft` defaults to Alpha/package only. Signing runs only in protected `aegis-ios-signing` on a task-owned ephemeral macOS ARM64 runner. `iOS Candidate Tag` accepts only `candidate/ios/VERSION-PROFILE.BUILD` and calls the same package workflow; its tag must equal admitted source. Draft writes happen only in `aegis-ios-draft` with `contents:write`, always draft/prerelease, followed by actual asset download and hash verification. Nothing publishes the Draft.

`iOS TestFlight Existing Package` accepts the exact `profile/version/build`, original `package_run_id`, retained `manifest_sha256`, and `source_attempt`. For later stages, set `upload_run_id` to the latest successful store-state run, preserving the entire stage history. Each successful store run publishes a new immutable `ios-delivery-RUN-ATTEMPT` artifact. Reuse this state for subsequent operations; never rebuild or upload again just to distribute or edit metadata. The uncredentialed import job checks repository, workflow, event, latest attempt, successful source run, original package origin, SHA/tree, manifest/assets and upload receipt. The protected store job independently restores and verifies these before loading ASC credentials.

Store stages are explicit: `status`, `wait`, `upload`, `compliance`, `metadata`, `distribute`. `destination`/`groups` apply to distribution; `stage_input` holds the JSON input above. External distribution requests Beta App Review and therefore needs separate operator authorization. Formal review remains a separate local Release-only `submit --destination app-store` operation; it requires a prepared exact App Store version, existing metadata/compliance and manual release. Neither review route is an automatic acceptance test.

Configure repository variable `AEGIS_IOS_RELEASE_ENABLED=false` first. Configure protected environments with custom deployment branch/tag policies, exact approved branch/main and `candidate/ios/*` tags as appropriate; no PR deployment refs. Add signing environment variables `AEGIS_IOS_RUNNER_LABEL`, `AEGIS_IOS_RUBY_BIN`, `AEGIS_IOS_NODE_BIN`, `AEGIS_IOS_BUNDLE_PATH`, `AEGIS_APPLE_TEAM_ID`, `AEGIS_IOS_CERT_SHA1`, `AEGIS_IOS_PROFILES`. Routing label is a repository variable so scheduling can resolve it before entering the signing environment. Add only ASC key ID/issuer/base64 key as encrypted secrets in `aegis-ios-store`. Never put the signing key there. Enable iOS only after passed main CI and configuration readback.

Fork rehearsal additionally requires `AEGIS_IOS_FORK_REHEARSAL=true`, its verified repository ID in `AEGIS_IOS_FORK_REPOSITORY_ID`, and the exact `refs/heads/codex/ios-release-*` ref in `AEGIS_IOS_FORK_REF`. It checks the upstream parent and latest complete exact-source validation attempt. Fork routes are artifacts, private Draft, TF upload and internal testing only. A branch push can bootstrap a package-only rehearsal using explicit `AEGIS_IOS_REHEARSAL_PROFILE`, `AEGIS_IOS_REHEARSAL_VERSION`, `AEGIS_IOS_REHEARSAL_BUILD`; if validation has not finished, the preflight fails before signing and may be rerun once validation succeeds. This mechanism leaves other platform workflows untouched.

`python3 scripts/release/ios-runner.py --help` documents the owned runner helper. Provide a fresh private directory with a checksum-verified official runner payload (including startup templates), exact run/job/SHA, unique repository label (registered with `--no-default-labels`), installed keychain and public certificate pin. It verifies the entire checksum-pinned official payload inventory, executable modes and credential-free runtime startup, then checks the exact run/source/attempt and all jobs compatible with its dedicated label. It checks signing access and real disk reserves before registration, keeps the registration token out of argv, and registers one ephemeral runner. It never configures a shared runner service, proxy or VM. Keep at least 8 GiB truly free internally and 15 GiB externally throughout signing.

## Recovery, migration and evidence

A mutation writes an immutable started record before the call and a result after verified completion. A lost response leaves an unknown intent. Mutation reruns are rejected at both import and protected restore unless the completed identical journal has been recovered and independently verified; failed attempts require explicit readback reconciliation. Reusing a completed identical stage is idempotent; changed parameters or an unresolved intent are rejected. Actions also checks earlier runs of the identical stage/manifest to prevent a new job silently discarding an unknown journal. Do not rerun a failed upload blindly: read exact buildUploads/build/group/metadata state and inspect the failed run's preserved artifact. Reconcile known remote results with independently retained evidence before restoring a receipt; otherwise stop and use a new explicitly chosen build. No command fabricates a completion receipt automatically.

Merge only after required upstream checks and iOS validation pass, follow fresh merged-main CI, then repeat all methods on the new merged source: manual Fastlane, Actions package and Tag/private Draft, each with Alpha/Beta/Release and unique unused builds. Download and verify each artifact; upload that same IPA to TF and read back VALID plus its audience. Reuse completed uploads for representative compliance, metadata and internal distribution checks. Report package, Actions, Draft, upload, processing, group availability, device proof and review states independently. Contract coverage of review routes is not a real review submission.

After upstream delivery passes, read and snapshot fork iOS settings, disable only `AEGIS_IOS_RELEASE_ENABLED` on the fork and retire its iOS-specific environment admission. Retain source, tags, Drafts, TF builds and evidence. Rollback consists of restoring the reviewed iOS environment policies and iOS activation variables against a newly verified source; repeat admission and delivery checks. Do not change shared all-platform release flags or another platform's state/services.
