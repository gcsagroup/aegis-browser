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

`iOS Delivery` is the single packaging and TestFlight workflow. `iOS Release Validation` keeps automatic uncredentialed PR/main checks and unsigned native archives; `iOS Coverage` keeps simulator coverage. All manual iOS workflows require a current effective repository **Admin** grant, including organization-owner grants. Maintain/Write/Read/custom role titles do not qualify. GitHub may still show the Run workflow button to Write users: the uncredentialed admission gate rejects them before protected jobs are scheduled. Both the original actor and the actual rerunner must be Admins; API failures or incomplete role inventories deny access. CI uses the paginated filtered Admin collaborator API with the existing installation token, not a PAT or username allowlist. Local stages resolve the actual authenticated token user; set an authorized `GH_TOKEN`/`GITHUB_TOKEN` in the private process environment. `plan` remains uncredentialed.

The dispatch form has seven inputs. For a new package, enter only `version` and an unused `build`; `operation=package` and `profile=auto` produce Alpha artifacts. Choose Beta/Release explicitly when packaging them. For an existing package, select the operation and paste the complete **delivery receipt** from the last successful run summary into `source`. Leave profile at `auto` and version/build empty: the receipt retains their immutable values. An explicit conflicting identity is rejected.

| Input | When to fill it |
| --- | --- |
| `operation` | `package` (default), `draft`, `upload`, `wait`, `status`, `metadata`, `compliance`, `distribute-internal`, `distribute-external` |
| `profile` | New package audience; `auto` means Alpha for packaging, or the receipt's original audience for later stages |
| `version`, `build` | Required only for package/draft; use a new unused build number |
| `source` | Required for upload and subsequent stages; copy the whole receipt, keep its original copy independently |
| `groups` | Existing comma-separated group names for distribution only |
| `stage_input` | Reviewed JSON for metadata/compliance only |

`package` retains artifacts and never uploads. `upload` uploads the existing IPA to TF without distribution/review. `wait` waits for processing; `status` reads current state. `metadata` changes the supplied Beta description/testing notes; `compliance` applies an explicitly authorized answer. The two distribution choices select their destination directly; Alpha external testing fails in admission. Every successful package/store run emits an updated receipt in Summary. Wait for the whole run to succeed, then use its receipt for the next step; failed or uncertain mutations require reconciliation, not an older receipt or another upload.

A receipt is a bounded, versioned identity pin containing profile/version/build, original package run, latest state run, exact attempt and original manifest SHA256. It grants no permission and does not replace any source, producer, journal or integrity verification. Separate run/attempt/digest/destination/tag fields have been removed from the form. A changed or stale receipt fails the existing import checks before ASC credentials are loaded.

Push `candidate/ios/VERSION-PROFILE.BUILD` to derive its immutable identity and package a private Draft; it never uploads to TF. Manual `draft` derives the same exact existing tag from profile/version/build and checks its source; prefer the tag trigger for normal Draft packaging. Signing uses protected `aegis-ios-signing` on an owned ephemeral macOS ARM64 runner. Draft writes use `aegis-ios-draft` with `contents:write`, always draft/prerelease, and actual download/hash verification. Each successful store run publishes an immutable `ios-delivery-RUN-ATTEMPT` artifact; the receipt selects this state without rebuilding or uploading again to edit metadata or distribute.

The uncredentialed import job checks repository, admitted workflow, latest attempt, successful producer, original package origin, SHA/tree, manifest/assets and completed upload receipt. Protected jobs independently recheck identity and authorization before loading ASC credentials. External TF distribution requests Beta App Review and needs separate authorization. Formal App Store review remains a separate explicit Release-only local stage; neither review is an automatic acceptance test.

Configure repository variable `AEGIS_IOS_RELEASE_ENABLED=false` first. Configure protected environments with custom deployment branch/tag policies, exact approved branch/main and `candidate/ios/*` tags as appropriate; no PR deployment refs. Add signing environment variables `AEGIS_IOS_RUNNER_LABEL`, `AEGIS_IOS_RUBY_BIN`, `AEGIS_IOS_NODE_BIN`, `AEGIS_IOS_BUNDLE_PATH`, `AEGIS_APPLE_TEAM_ID`, `AEGIS_IOS_CERT_SHA1`, `AEGIS_IOS_PROFILES`. Routing label is a repository variable so scheduling can resolve it before entering the signing environment. Add only ASC key ID/issuer/base64 key as encrypted secrets in `aegis-ios-store`. Never put the signing key there. Enable iOS only after passed main CI and configuration readback.

Privileged fork delivery is retired. The delivery gate, local admission and owned signing-runner launcher accept only canonical `gcsagroup/aegis-browser` repository ID1348409663; old rehearsal flags cannot reopen it. Fork PR/quality checks remain uncredentialed. Historical workflows, runs, tags and artifacts remain evidence, rather than active duplicate delivery entrypoints.

`python3 scripts/release/ios-runner.py --help` documents the owned runner helper. Provide a fresh private directory with a checksum-verified official runner payload (including startup templates), exact run/job/SHA, unique repository label (registered with `--no-default-labels`), installed keychain and public certificate pin. It verifies the actual CLI operator has canonical repository Admin permission before inspecting the payload or probing a signing key, then verifies the entire checksum-pinned official payload inventory, executable modes and credential-free runtime startup (bounded at 90 seconds per runtime to allow cold macOS executable validation), then checks the exact run/source/attempt and all jobs compatible with its dedicated label. It checks signing access and real disk reserves before registration, keeps the registration token out of argv, and registers one ephemeral runner. It never configures a shared runner service, proxy or VM. Keep at least 8 GiB truly free internally and 15 GiB externally throughout signing.

## Recovery, migration and evidence

A mutation writes an immutable started record before the call and a result after verified completion. A lost response leaves an unknown intent. Mutation reruns are rejected at both import and protected restore unless the completed identical journal has been recovered and independently verified; failed attempts require explicit readback reconciliation. Reusing a completed identical stage is idempotent; changed parameters or an unresolved intent are rejected. Actions also checks earlier runs of the identical stage/manifest to prevent a new job silently discarding an unknown journal. An earlier denied dispatch or skipped store job does not block a later Admin only when every attempt conclusively contains no executed store job. Any possibly started mutation or incomplete inventory remains blocked. Do not rerun a failed upload blindly: read exact buildUploads/build/group/metadata state and inspect the failed run's preserved artifact. Reconcile known remote results with independently retained evidence before restoring a receipt; otherwise stop and use a new explicitly chosen build. No command fabricates a completion receipt automatically.

Merge only after required upstream checks and iOS validation pass, follow fresh merged-main CI, then repeat all methods on the new merged source: manual Fastlane, Actions package and Tag/private Draft, each with Alpha/Beta/Release and unique unused builds. Download and verify each artifact; upload that same IPA to TF and read back VALID plus its audience. Reuse completed uploads for representative compliance, metadata and internal distribution checks. Report package, Actions, Draft, upload, processing, group availability, device proof and review states independently. Contract coverage of review routes is not a real review submission.

After upstream delivery passes, read and snapshot fork iOS settings, disable only `AEGIS_IOS_RELEASE_ENABLED` on the fork and retire its iOS-specific environment admission. Retain source, tags, Drafts, TF builds and evidence. Rollback consists of restoring the reviewed iOS environment policies and iOS activation variables against a newly verified source; repeat admission and delivery checks. Do not change shared all-platform release flags or another platform's state/services.

The committed app Info.plist declares Boolean `ITSAppUsesNonExemptEncryption=false` for the reviewed Apple-OS-only encryption implementation. Export verification compares this declaration with the signed app. Reassess it when encryption code/libraries change; historical packages retain their original bytes. Confirm TF reads `usesNonExemptEncryption=false` before any explicit compliance update.

Admin-only candidate Tag protection is independent of workflow code. Apply [the scoped ruleset](../../.github/ios-candidate-admin-ruleset.json) to `refs/tags/candidate/ios/**/*`: restrict creation/update/deletion with only repository Admin bypass. Prepare it disabled, verify GraphQL `repositoryRoleName=admin` for role ID5, then activate and run `node scripts/ci/ios-operator.mjs --verify-candidate-tag-policy` with the actual Admin token. Do not widen bypass actors or tag patterns. This delivery boundary assumes passed main code is trusted; changing shared main review governance is separate work.
