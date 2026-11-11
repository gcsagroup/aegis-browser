# Aegis central cloud export PoC

The first product integration implements a single Alpha, export-only allocation. The Aegis changes are reviewed through quinn521/aegis-browser targeting develop. Runtime admission continues to bind gcsagroup/aegis-browser (1348409663), its current main, and its latest successful exact-source quality workflow. The central counterpart lives in gcsagroup/apple-signing (1364015229).

## Execution and credentials

The central Git tree stores no private keys, encrypted P12/PFX files or encoded key backups. Signing credentials belong in protected product Environment Secrets. Temporary Xcode key files remain confined to the isolated native signing session and are excluded from every transfer or retained object.

A private archive producer installs ios-central-archive.yml from the reviewed Aegis source. Its protected workflow/ref and original operator, rerunner, numeric job ID and successful first attempt are frozen in the central authorization. Configure AEGIS_CENTRAL_PRODUCER_REPOSITORY, AEGIS_CENTRAL_SOURCE_SHA, AEGIS_APPLE_TEAM_ID, AEGIS_IOS_CENTRAL_ARCHIVE_RUNNER_LABEL and the Alpha Firebase registration. The development-only macOS account needs valid Apple Development signing material and the three exact development profiles. The archive process rejects ASC and Distribution credentials. It emits archive.zip and canonical request.json exclusively in the private producer run. This workflow skips public repositories.

The central admission job accepts one request SHA-256. E authenticates the private repository, successful exact producer/job, operator Admin permissions in Aegis, artifact ID and platform digest, original ZIP bytes, S/tree and quality.yml push/main latest attempt with both quality jobs. A separate hosted Ubuntu job runs product ASC preflight with a read-only status Key. The dedicated macOS signer executes E code only, reauthenticates the original input, writes and reads back the single START, checks the ASC preflight, freshly extracts the authenticated ZIP, then loads the signing Key. Its account-wide lock and cleanup marker survive cancellation or ambiguous cleanup. Xcode performs exportArchive with destination=export and internal-only Alpha.

Product code and Ruby dependencies run in separate hosted jobs with permissions: {} and no central signing/write credentials. They capture the exact ASC export reservation, verify Apple trust, actual signed/profile entitlements and source resources, and compare all three delivered IPA UUID sets with original dSYMs. A separate E-owned finalizer compares the original signer IPA hash, retains five verified deliverables, the original archive/prepared/native receipts and result.json in a private Draft in the producer repository, downloads every asset by numeric ID and checks actual bytes, then records the immutable central result. Product clients receive access to their own private repository. START and result refs are permanent consumption indexes. Short-lived Actions artifacts carry inter-job data only.

## Activation record

The committed activation initially has status=not_activated and an empty authorizations array. Runtime bootstrap rejects this state before scheduling the protected signer. An authorized deployment PR must freeze one request_sha256, authority_commit A, executor_commit E, artifact_id, full producer identity, expires_at, caller (actor_id, triggering_actor_id, ref and job_id), allocation_validation_sha256 and storage (private repository name/ID, explicit positive retention_days and validation_sha256). Those validation digests must point to retained original product allocation/exclusion evidence and storage write/read/overwrite-denial/tenant-denial/recovery checks. Unknown IDs, unverified endpoints and guessed credentials cannot supply these values.

A/E are delivered first. A separate reviewed registry revision L activates the exact tuple and one independently reserved version/build. Coordinate the product reservation with every existing delivery route before activation; this PoC does not introduce an automatic default route switch. The current producer/private storage and Apple permissions have not been deployed or accepted by these code PRs.

Protected product Environments carry the secrets: aegis-ios-input and aegis-ios-signing use AEGIS_EVIDENCE_READ_TOKEN for the private producer, aegis-ios-retain alone uses AEGIS_EVIDENCE_WRITE_TOKEN, AEGIS_SOURCE_READ_TOKEN (Aegis source/Admin metadata read), AEGIS_STATUS_KEY_ID/ISSUER_ID/KEY_BASE64 (ASC status only) and AEGIS_SIGNING_KEY_ID/ISSUER_ID/KEY_BASE64 (approved non-Admin cloud signing). The ASC read-only Key exists only in aegis-ios-status; the cloud signing Key exists only in aegis-ios-signing. Configure each named Environment and its reviewed ref/reviewer protections separately. Actual Apple permissions and GitHub Environment/ref protections must be verified separately. Product verification uses an isolated hosted macOS runner; the signing account must never execute product code or dependencies.

## Recovery and acceptance

The stable consumption key covers ASC application 6827988433, IOS, canonical version and build. Changing the request, source, profile, workflow or attempt retains the same consumed key. Reruns and ambiguous writes cannot grant another export. After START, failed or handled-cancelled signing keeps its available original data in the private central transfer artifact for 30 days, including native/*.ipa if cleanup failed before the canonical IPA copy. A fixed failure record contains only the exception class and key-removal status. Transfer upload itself can fail or be force-cancelled, so permanent storage of failed output is not claimed. Reconcile and copy any available originals into approved private storage before this transport retention expires. The permanent START remains consumed even when no output was recovered. A pending host cleanup marker blocks subsequent signing until its recorded account resources have been reconciled. Finalization may use the frozen historical START after its admission deadline passes. Closing new admission preserves original-record reading.

For independent readback, an operator with central read access checks refs/heads/ios-export/aegis/result/<allocation SHA-256> against its START and actual central workflow/run/attempt, then uses the recorded private release/asset IDs to retrieve the originals through the product evidence repository. Check the recorded result.json hash and every asset size/SHA-256. On the approved clean Aegis authority, set an operator-only AEGIS_CENTRAL_READ_TOKEN and run central-ios.py verify-retained --work /private/downloaded-originals --output /private/new-verification. It authenticates the actual central START/result and successful run, checks the nine original files, and verifies the downloaded original IPA against its original dSYM. The report goes into a fresh directory. The PoC result is export-only and cannot be supplied as an existing production delivery/upload receipt.

Local tests substitute native commands and network services. Real acceptance still requires a private producer, an independently reserved build, Development archive, minimum-permission cloud export, object readback and cleanup. ASC processing/upload, the existing production entrypoint/channel matrix and physical-device upgrade each require their own subsequent acceptance.

The credential-free protocol is mirrored as scripts/ios_export/protocol.py in the central repository and scripts/release/central_ios_protocol.py in Aegis. Review both copies together and verify byte equality before updating either contract. Unit/regression tests cover source/producer identity, canonical requests, entitlement escalation, delivered dSYM drift, ZIP escape, repeated/lost consumption, actual private-file creation and cancellation cleanup.


## Quinn develop-only acceptance exception

Before upstream promotion, one independently authorized Alpha export may use
`quinn521/aegis-browser` (`1363949860`), owner `287940781`, parent
`1348409663`, and only `refs/heads/develop`. This is a development test exception,
not a general fork permission. Production remains the default V1 contract and
rejects the V2 development request.

Use `ios-central-develop-archive.yml` in an approved private producer and
`aegis-ios-develop-export.yml` in central main. Every producer and central dispatch
must have Quinn as both original and triggering actor, on attempt 1. The request
uses `aegis-central-archive-v2`, `scope: quinn-develop-poc`, an explicit source ref,
Alpha, and export-only. Current source, owner/parent, latest exact push/develop
quality run/attempt, and both successful quality jobs are rechecked before START.

The separate `develop-activation.json` starts inactive. Its active form has one
exact authorization with the original V1 fields plus `issued_at`, `source_tree`,
`status_authority_commit`, `quality_run_id`, `quality_attempt`,
`environment_validation_sha256`, and `credential_validation_sha256`. The registry
also has `scope: quinn-develop-poc`. Timestamps are UTC with Z; the interval is
positive and no longer than **24 hours**. The approval freezes A=S, E, T, L,
producer/run/job/artifact, source tree, quality, storage and global build-number
exclusion evidence. No guessed ID or placeholder digest can activate a real run.
The immutable START stores the original approval, L, scope and quality tuple.
Expiry is checked again immediately before the signing Key is loaded. A consumed
START is never released by expiry, cancellation or another scope.

Development uses only `aegis-ios-develop-input`, `aegis-ios-develop-status`,
`aegis-ios-develop-signing` and `aegis-ios-develop-retain`. Protect central main,
reviewer separation and bypass settings; verify actual private-repository support
and the retained evidence before activation. Private archive production uses its
own `aegis-ios-develop-archive` Environment and Development-only account. Product
code receives neither cloud signing nor ASC status credentials. Input/signing
use evidence-read and source-read tokens; retain alone receives the evidence-write
token; status and signing Keys remain in their respective Environments.

Status preflight and post-export capture execute central E's `status.rb` with
separately frozen upstream authority T
`a34c412158ff95a689dd810ae624119b3f2b279b` and T's locked Ruby dependencies.
Both status jobs are independent of candidate S's code and caches. Candidate S
runs only the credential-free verification job. The finalizer authenticates the
capture job's separate artifact ID/digest and compares its original bytes with
S's returned copy before recording a result.

Both entrypoints retain the original application/platform/version/build
allocation and the same `ios-export/aegis/{start,result}` indexes. The V2 result
is `aegis-central-develop-export-result-v1`, with `purpose: development-test-only`,
`uploadAuthorized: false`, `submissionAuthorized: false`, `releaseReady: false`
and no promotion permission. It cannot be supplied as a production delivery
receipt. Source promotion follows accepted development evidence; production
signing needs its own allocation and authorization.

Use `central-ios.py archive`, `verify` or `verify-retained` with explicit
`--scope quinn-develop-poc`. Default commands remain production-only. Retained
verification authenticates the original START and actual successful development
workflow and does not require current develop, an open admission window, or an
unexpired temporary Actions artifact. Original package bytes and symbols remain
read-only.

These code paths do not establish deployment or real acceptance. Before activation,
retain actual private producer/storage identity, global version/build exclusion,
minimum Apple role tests, Environment protections, isolated signer/Development
producer admission and object write/read/overwrite-denial/tenant-denial/recovery
proofs. Missing infrastructure or permissions leave the registry inactive. A real
cross-machine export, original object readback, upload/ASC processing and device
acceptance have separate evidence.
### Development administrator authorization

The optional `operator-merged-activation-pr-v1` proof identifies the actual
`GCSA-ToolsTeam` administrator account (`316909304`) that merged one frozen
development activation PR. The central executor owns this policy; the activation
PR cannot change it. Authorization lasts at most 24 hours and consumes the same
global build allocation. Central signing uses a separate GitHub-hosted `macos-26`
job with fixed Xcode 26.6.

`verify-retained --scope quinn-develop-poc` authenticates this proof from original
START/RESULT records and frozen Git/PR evidence, including its canonical digest.
Its central read token additionally needs Pull requests read access. Later admin
removal, main movement and admission expiry do not invalidate original readback.
The report states `independentHumanApproval: false` and
`environmentBypassObserved: null`: administrator merge identity and Environment
bypass capability do not establish an independent person's approval or an actual
deployment bypass event. Both registries remain inactive until a separate exact
authorization is prepared after infrastructure and Apple-role verification.
