# iOS cloud signing PoC

## Default-cloud acceptance, 2026-11-05 (Asia/Shanghai)

[PR #77](https://github.com/gcsagroup/aegis-browser/pull/77) switched new iOS
packages to cloud by default and retained explicit manual fallback. The runtime
acceptance below uses merged source `b6f0e680b25e64a33109f24ba982e3b9aee68e46`,
tree `5cb91a5eecb81c143f00522bd2e8606ed5028ced`. This documentation backfill
does not produce or relabel any package.

Version **1.0.3 starts at build 1**. All nine cloud combinations omitted the
signing selector, including lightweight Alpha/Release tags and an ordinary
annotated Beta tag with no signing directive. Each used Xcode 26.6 (17F113),
a fresh hosted runner and archive, zero initially installed provisioning
profiles and no Distribution identity. No Distribution P12 was imported.
Archive signing was ad-hoc; export completed Apple cloud Distribution signing.
The ephemeral keychain state was restored.

The explicit manual Beta fallback used `signing_mode=manual`, installed and
cleaned up the existing certificate/profile material, then uploaded the exact
verified package through its retained receipt. The Upload form retained its
default cloud value, confirming that existing-package operations use the
manifest signing mode. No automatic cloud-to-manual retry occurred.

Independent downloaded-byte verification checked the GitHub artifact digest,
manifest hashes and all three targets: Apple-trusted Distribution signatures,
exact Team OU, provisioning CMS, entitlements and delivered IPA/dSYM UUIDs.
All ten uploads are `COMPLETE`, builds `VALID` and unexpired, with the correct
audience. Review-linkage readback found no Beta Review, App Store version or
tester-group relationship. Physical-device acceptance remains unverified.

The exact-source [quality gate](https://github.com/gcsagroup/aegis-browser/actions/runs/41887005986),
[iOS validation](https://github.com/gcsagroup/aegis-browser/actions/runs/41887005934)
and [secret scan](https://github.com/gcsagroup/aegis-browser/actions/runs/41887005903)
passed independently of package and ASC acceptance.

| Entry | Profile | Build | Signing | Package run | Upload run | ASC processing / audience |
| --- | --- | --- | --- | --- | --- | --- |
| Fastlane | Alpha | 1 | cloud | [41894252527](https://github.com/gcsagroup/aegis-browser/actions/runs/41894252527) | same run | `VALID` / `INTERNAL_ONLY` |
| Fastlane | Beta | 2 | cloud | [41895618369](https://github.com/gcsagroup/aegis-browser/actions/runs/41895618369) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Fastlane | Release | 3 | cloud | [41897615023](https://github.com/gcsagroup/aegis-browser/actions/runs/41897615023) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Actions | Alpha | 5 | cloud | [41901851000](https://github.com/gcsagroup/aegis-browser/actions/runs/41901851000) | same run | `VALID` / `INTERNAL_ONLY` |
| Actions | Beta | 6 | cloud | [41903454151](https://github.com/gcsagroup/aegis-browser/actions/runs/41903454151) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Actions | Release | 7 | cloud | [41905273732](https://github.com/gcsagroup/aegis-browser/actions/runs/41905273732) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Tag → private Draft | Alpha | 9 | cloud | [41909079606](https://github.com/gcsagroup/aegis-browser/actions/runs/41909079606) | [41910558537](https://github.com/gcsagroup/aegis-browser/actions/runs/41910558537) | `VALID` / `INTERNAL_ONLY` |
| Tag → private Draft | Beta | 10 | cloud | [41911251650](https://github.com/gcsagroup/aegis-browser/actions/runs/41911251650) | [41912854175](https://github.com/gcsagroup/aegis-browser/actions/runs/41912854175) | `VALID` / `APP_STORE_ELIGIBLE` |
| Tag → private Draft | Release | 11 | cloud | [41913533143](https://github.com/gcsagroup/aegis-browser/actions/runs/41913533143) | [41914893911](https://github.com/gcsagroup/aegis-browser/actions/runs/41914893911) | `VALID` / `APP_STORE_ELIGIBLE` |
| Explicit manual fallback | Beta | 12 | manual | [41915508670](https://github.com/gcsagroup/aegis-browser/actions/runs/41915508670) | [41916645037](https://github.com/gcsagroup/aegis-browser/actions/runs/41916645037) | `VALID` / `APP_STORE_ELIGIBLE` |

Retained IPA SHA-256 values:

| Entry / profile | Build | IPA SHA-256 |
| --- | --- | --- |
| fastlane / alpha | 1 | `74fdf4201e121322e4e3823cdb404d5bea6cf234f805aa97471a99c6eec03291` |
| fastlane / beta | 2 | `6fd8803b7b61b35c0e178870d6a1007e4c9736d99d0e3ab515a6d44191184062` |
| fastlane / release | 3 | `55c445274ccb70ba2d66a51b49ff21ab28941cf506f1d881f540aad898372766` |
| actions / alpha | 5 | `0fd72c5585a9622504e02e29799adfec322d6481b10b33be6d97e7eb75a5fe98` |
| actions / beta | 6 | `f95520ea73cd89716ca102b933708543c73c8bad101382c3b1f6e648d9612bf5` |
| actions / release | 7 | `58c0a6e517b93b5f627393c1a4c8bff14f340c8e5c60e0de8e032e5cdf2a96cf` |
| tag-draft / alpha | 9 | `662e487b9f27098872c4af8fffdcdf1e805314beb0d859826b61d52dac9b0885` |
| tag-draft / beta | 10 | `e02542f7be9dbd77d2f7347383eb9144f601cb2ed3b659a297e218c31c9d95c5` |
| tag-draft / release | 11 | `a9a794647d036d57dff35c0a062081b9016af55547c7b14be8a6962435414bb3` |
| manual-fallback / beta | 12 | `f252e39df85690f25edb16d7a435a9087bbedcb962ffa09c418bf44e9f8c41be` |

The three tag releases remain private Drafts. Each retained eight assets
whose remote digest and size matched the verified local manifest:

- [Alpha 1.0.3 (9)](https://github.com/gcsagroup/aegis-browser/releases/tag/untagged-51a61191b5ac5807f08d), tag `candidate/ios/1.0.3-alpha.9`.
- [Beta 1.0.3 (10)](https://github.com/gcsagroup/aegis-browser/releases/tag/untagged-077b9dae164d41ac425c), tag `candidate/ios/1.0.3-beta.10`.
- [Release 1.0.3 (11)](https://github.com/gcsagroup/aegis-browser/releases/tag/untagged-5c16148b9ad467cb5f30), tag `candidate/ios/1.0.3-release.11`.

[Actions Alpha build 4](https://github.com/gcsagroup/aegis-browser/actions/runs/41899341044)
completed cloud archive/export and independent signature/dSYM checks, but
`actions/download-artifact` failed with `ECONNRESET` before the upload
command ran. ASC had no build or upload files, only an empty
`AWAITING_UPLOAD` export reservation. The failed workflow, package and
readbacks are retained separately. Recovery created a fresh package at
build 5; no failed producer was replayed or imported. The ten accepted
packages above exclude build 4.

[Lightweight Tag Alpha build 8](https://github.com/gcsagroup/aegis-browser/actions/runs/41906988524)
completed a fresh ad-hoc archive, then Xcode cloud export returned exit 70
(data format read error and provisioning profile not found). No IPA,
Draft or upload completed; the keychain was restored. The signing
configuration matched successful Alpha build 5, and an authenticated API read found
the existing App Store profiles active. Recovery used a fresh build 9
on a lightweight tag with the same signing configuration. Build 8 and its
empty export reservation are retained separately and excluded from the
ten accepted packages; the original export error is not relabelled as
a successful run.

The initial default-cloud run `1.0.2 (11)` also reached `COMPLETE` / `VALID`.
Build 12 was cancelled before its upload job executed when numbering was
corrected; only its empty `AWAITING_UPLOAD` export reservation remained.
The complete matrix moved to the unused version 1.0.3 rather than resetting
or reusing accepted 1.0.2 build identities. New versions begin at build 1;
subsequent uploads within a version use increasing, unused build numbers.
The original 1.0.2 matrix and 0.8.0 failure evidence below retain their
original source identities. Local receipts include every IPA/dSYM, delivery
and upload journal, independent verification, final ASC and private Draft
readback, and SHA-256 inventories.

## Hosted primary, local fallback, and historical 1.0.2 matrix

Version **1.0.2 (2–10)** passed all nine Alpha/Beta/Release ×
Fastlane/Actions/Tag-to-Draft combinations on 2026-11-04. Each package completed
a fresh hosted archive, cloud export, independent three-target verification,
ASC upload and processing (`COMPLETE` / `VALID`). The earlier **0.8.0** upload
was rejected by Apple; its failure evidence is retained below. That historical
matrix used builds 2–10; its accepted identities are retained.

No App Review or Beta Review was submitted, no tester groups were assigned, and
the three releases remain private Drafts. Native-device acceptance remains a
separate gate.

### Current signing default and manual fallback

New packages default to **cloud** in the CLI, Fastlane, Simple/Full Actions and
candidate-tag entrypoints. The CLI accepts `--signing-mode manual`, Fastlane
accepts `signing_mode:manual`, and Actions exposes an explicit manual selection.
Cloud failure stops the current attempt; manual is never an automatic retry.
Only new-package operations consume this selector. Status/Wait and retained
package stages use their original identity and signing evidence. Cloud production
packaging runs only on GitHub-hosted macOS; the isolated-keychain local command is an explicit fallback, never an
automatic retry after a cloud failure.

The hosted proof must use Xcode 26.6, a clean runner without installed profiles or
Distribution identities, and a newly created archive. Archive signing defaults to
Apple Development (via ASC API key + `-allowProvisioningUpdates`), then export
performs Apple cloud Distribution signing. Xcode 26.6 rejects ad-hoc/unsigned
archives when targets carry entitlements, so ad-hoc archive signing is opt-in
only (`--archive-signing=ad-hoc`) and is not the CI default. Development-signed
archives are still not distributable packages; the exported IPA must pass the
full Apple-trusted distribution signature/profile/entitlement checks.

Each package contains a source-bound receipt, IPA, dSYM ZIP and independent
signature/dSYM checks. Every target's dSYM UUID must match its archived binary.
Cloud upload re-verifies artifact hashes and actual signing identities against
the retained receipt, refuses upload replay, and keeps upload and processing
receipts separate.

Xcode cloud export can create an empty ASC `AWAITING_UPLOAD` reservation even
with `destination=export`. Cloud packages retain the exact reservation ID after
an unused-build preflight, and upload checks it again before invoking transport.
Only that recorded reservation, with no upload files or uploaded date, may pass.
Other IDs, any file activity, a processed build, or a changed state stop upload.
Manual uploads keep rejecting every existing upload record.

Cloud verification applies a per-target Apple anchor, exact certificate Team OU
and iOS Distribution marker requirement, while allowing certificate rotation.
Profiles are decoded only after native CMS verification under Apple's iPhone
Provisioning Profile Signing trust policy. A successful `security cms -D` exit
alone is insufficient: it can decode altered signed content. The macOS native
validation job includes real self-signed CMS and ad-hoc signature rejection
regressions without importing any signing identity.

The existing iOS Release Validation workflow has an explicit `cloud-poc` manual
exercise on the admitted self-hosted macOS runner labeled by
`vars.AEGIS_IOS_RUNNER_LABEL` (historical `aegis-ios-upstream-migration`). It
uses a dedicated environment restricted to the exact candidate branch, with the
candidate SHA frozen in an environment variable and repeatedly checked against
the dispatch, checkout and remote branch. Both the original operator and
rerunner must be repository Admins. Credentialed work is never triggered by a
fork PR. Production current-main admission is unchanged. Cloud packaging accepts
GitHub Actions macOS runners (`github-hosted` or `self-hosted`); durable
self-host evidence skips the fresh-runner clean-slate profile proof.
The first probe used a 0.8.0 Beta build; its evidence is not transferable from
that candidate to the later merged-source matrix.

The original nine-way integration selected cloud explicitly as follows; the
current entrypoints use cloud when the signing choice is omitted:

| Entry | Explicit selection | Profiles |
| --- | --- | --- |
| Fastlane | Full workflow, `package_entrypoint=fastlane`, `signing_mode=cloud` | Alpha, Beta, Release |
| Actions | Simple workflow, `signing_mode=cloud` | Alpha, Beta, Release |
| Tag → private Draft | Annotated candidate tag selecting cloud signing | Alpha, Beta, Release |

The Fastlane entry runs the actual `bundle exec fastlane ios package` command on
a hosted runner; it does not substitute the local fallback for hosted evidence.
New lightweight tags and ordinary annotations use cloud signing. For an explicit
manual fallback tag, create an annotated candidate directly at the admitted
current-main SHA with this annotation (replace the placeholder with that full
SHA, preserve the first line and use LF newlines):

```text
aegis-ios-signing-v1
{"signingMode":"manual","sourceSha":"FULL_MAIN_SHA"}
```

The same annotation accepts `cloud` when an explicit source-bound choice is
wanted. Malformed reserved signing annotations, source mismatches and unknown
modes stop delivery. An existing tag's prior artifact receipts are not changed.

Tag deliveries first verify private Draft assets and remote hashes. ASC uploads
of those exact packages use the retained delivery receipt in a separate Full
Upload stage; no publishing, tester-group assignment or review submission is
implicit. Apple rejected new 0.8.0 uploads because that train is closed and
below approved 1.0.0. The rejection is retained separately from the authorized
1.0.2 matrix; it is never reported as processing success.

### Merged-source nine-way acceptance, 2026-11-04

Implementation [PR #75](https://github.com/gcsagroup/aegis-browser/pull/75) merged
as `1b347068a62382e3ed9cc21a57f24192541a8873`, tree
`0e2d20039ea29dda2a3110e99ab1bb904dae567a`. All nine packages and their upload
receipts use exactly that source. The independently reviewed implementation head
was `6850c5ae13c22ac6a2b8b2075c88f0a0c4647d83`, with the same tree and no remaining
P1/P2 findings. This later documentation update is not a package producer.

The merge-source [quality gate](https://github.com/gcsagroup/aegis-browser/actions/runs/41833649706),
[iOS contracts/native validation](https://github.com/gcsagroup/aegis-browser/actions/runs/41833649760)
and [secret scan](https://github.com/gcsagroup/aegis-browser/actions/runs/41833649992)
passed independently of the delivery matrix.

Every row used Xcode 26.6 (17F113), began with zero installed profiles and no
Distribution identity, created a new ad-hoc archive, and completed Apple cloud
Distribution export without importing a Distribution P12. Each run restored the
original keychain search list/default and deleted its disposable keychain.
Downloaded artifact bytes matched the GitHub artifact
digest and every manifest member. Independent local verification then checked
the app, Safari extension and Share extension: Apple-trusted Distribution signer
and exact Team OU, signed entitlements, trusted provisioning CMS, profile signer
membership, shared resources and actual delivered IPA/dSYM UUID equality.

| Entry | Profile | Build | Package run | Upload run | ASC processing / audience |
| --- | --- | --- | --- | --- | --- |
| Fastlane | Alpha | 2 | [41835100103](https://github.com/gcsagroup/aegis-browser/actions/runs/41835100103) | same run | `VALID` / `INTERNAL_ONLY` |
| Fastlane | Beta | 3 | [41837325591](https://github.com/gcsagroup/aegis-browser/actions/runs/41837325591) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Fastlane | Release | 4 | [41841951471](https://github.com/gcsagroup/aegis-browser/actions/runs/41841951471) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Actions | Alpha | 5 | [41843651373](https://github.com/gcsagroup/aegis-browser/actions/runs/41843651373) | same run | `VALID` / `INTERNAL_ONLY` |
| Actions | Beta | 6 | [41845318571](https://github.com/gcsagroup/aegis-browser/actions/runs/41845318571) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Actions | Release | 7 | [41847442429](https://github.com/gcsagroup/aegis-browser/actions/runs/41847442429) | same run | `VALID` / `APP_STORE_ELIGIBLE` |
| Tag → private Draft | Alpha | 8 | [41849328220](https://github.com/gcsagroup/aegis-browser/actions/runs/41849328220) | [41851206863](https://github.com/gcsagroup/aegis-browser/actions/runs/41851206863) | `VALID` / `INTERNAL_ONLY` |
| Tag → private Draft | Beta | 9 | [41851984373](https://github.com/gcsagroup/aegis-browser/actions/runs/41851984373) | [41853468470](https://github.com/gcsagroup/aegis-browser/actions/runs/41853468470) | `VALID` / `APP_STORE_ELIGIBLE` |
| Tag → private Draft | Release | 10 | [41854133972](https://github.com/gcsagroup/aegis-browser/actions/runs/41854133972) | [41856478088](https://github.com/gcsagroup/aegis-browser/actions/runs/41856478088) | `VALID` / `APP_STORE_ELIGIBLE` |

All nine server readbacks showed upload `COMPLETE`, processing `VALID`, unexpired
builds and no tester groups. Fresh review-linkage queries found no Beta Review
submission or App Store version relationship for any matrix build. Alpha is
`INTERNAL_ONLY`; Beta and Release are `APP_STORE_ELIGIBLE`. These are upload and
processing results, not TestFlight installation or physical-device proof.

Each tag's separate Upload operation consumed the original package receipt;
it did not rebuild or resign the IPA. The three private Drafts each retained
eight assets; every remote asset digest and size matched the independently
verified local manifest, including the manifest and its checksum:

- [Alpha 1.0.2 (8)](https://github.com/gcsagroup/aegis-browser/releases/tag/untagged-e7a013c4b4feff47ccd5), tag `candidate/ios/1.0.2-alpha.8`.
- [Beta 1.0.2 (9)](https://github.com/gcsagroup/aegis-browser/releases/tag/untagged-3cf735062327789ac173), tag `candidate/ios/1.0.2-beta.9`.
- [Release 1.0.2 (10)](https://github.com/gcsagroup/aegis-browser/releases/tag/untagged-7af48edc026edbff2e12), tag `candidate/ios/1.0.2-release.10`.

Retained IPA SHA-256 values:

| Entry / profile | Build | IPA SHA-256 |
| --- | --- | --- |
| Fastlane / alpha | 2 | `e159f9305868fb4a7b6d4e8b302f591bd5854b0841e8e40d948333152286a8cc` |
| Fastlane / beta | 3 | `500cdc55d8761cf95b89ee4863b98ae92bfa9091c106b140a68d2a59f4115159` |
| Fastlane / release | 4 | `4fe2df41add87b1b188832eb696ad752c82840156513282ce51f0039455d3dd7` |
| Actions / alpha | 5 | `b5643b879c96fd0c080da2ddc9129bbfffc1f5d83fcf1e552bbcb765241f4c4b` |
| Actions / beta | 6 | `35a33cc799a565506d1d40e81b585844405b2aae47d53868e669ec27c2f4e615` |
| Actions / release | 7 | `c9f0b48477a580f0f5dc3c51b01b49d0eabddfdb2571b562085d209cd8abacb0` |
| Tag → private Draft / alpha | 8 | `25de3181b35483d4beb666d06c5c2d0a6851dda7bbf580ea11f7229f0630b38f` |
| Tag → private Draft / beta | 9 | `7cebdd5d20ff8a0da0774f2dfdc123b650f088cb6456685b019ad7b21802cfae` |
| Tag → private Draft / release | 10 | `fbdde047171755c9ac6a6cc8f6f20afd9f279e4f7aece6a44019eb0913fb427f` |

The local acceptance bundle includes all nine IPAs and dSYM ZIPs, original
delivery/upload receipts, per-package independent verification, final ASC
processing/review-linkage readbacks, Draft asset readbacks, an `acceptance.json`
index and `evidence-sha256.json`. The rejected 0.8.0 upload logs and receipt are
preserved in a separate failure directory. Manual was the default during that
source-bound acceptance; it is now the explicit fallback. The isolated-keychain
local proof remains separately bound to 1.0.1 (16). No release was published and no device acceptance is claimed.

### First hosted probe, 2026-11-04

[Run 41826833453](https://github.com/gcsagroup/aegis-browser/actions/runs/41826833453)
used candidate `8dc1c4b3db1a85f263b942f7da23ed8bd9b581e4`, tree
`628124db16c6f5227e969248e8fd265a28e4a9e0`, Xcode 26.6 (17F113), Beta 0.8.0 (500).
The clean runner started with no installed profiles or Distribution identity,
verified three ad-hoc archive signatures, then completed cloud export. All three
IPA signatures, entitlements, shared resources, Firebase registration and dSYM
UUIDs passed. No Distribution P12 was imported, no Distribution private identity
was visible after export, and the original keychain state was restored.

The retained IPA SHA-256 is
`bfeb2dc609bba6fb4a3fb7b61f21c51a1ca33cc5acbf0712fe715019c5773cdc`;
the dSYM ZIP SHA-256 is
`838f87c32d3d75deb7cb3792a0952d4f99666811d31b5be30d20a4aef108c156`.
Downloaded artifact bytes matched the GitHub artifact digest and all receipt
members; independent local signature re-verification also passed.

The run stopped before transport because the original duplicate-upload guard
rejected Xcode's new reservation `b155cd7e-17a1-41a9-9749-6ba2a58b9ea6`.
ASC readback showed `AWAITING_UPLOAD`, no upload files, no uploaded date and no
processed build. No upload-started or upload-result receipt exists. The run is
retained as hosted package proof and a guard failure, not upload/processing or
final merged-source matrix acceptance. The reservation handling above is the
targeted correction; build 500 is not automatically replayed.

### ASC upload probe, 2026-11-04

[Run 41829391901](https://github.com/gcsagroup/aegis-browser/actions/runs/41829391901)
used source `ae16b209ad021ade558dd14d8151d3b4ebd60d4d` for Beta 0.8.0 (510).
Fresh hosted archive/export and verification passed again. The new reservation
guard accepted only its own empty export reservation and invoked upload once.
Apple rejected transport validation: `90186` (0.8.0 train closed), `90478`
(version no longer importable), and `90062` (0.8.0 is below approved 1.0.0).
Processing therefore cannot be accepted for new 0.8.0 packages. The immutable
upload intent and Apple errors are retained; no upload replay or review
submission was performed. The user then authorized 1.0.2 for the nine-way
upload/processing matrix recorded above.

Independent review found a P2 in the earlier verifier's signer trust boundary.
The Apple Team/Distribution requirement and native profile CMS checks above
address it. The unchanged build 500 IPA passed those stronger checks locally;
altered CMS, self-signed CMS and ad-hoc signatures are rejected. These verifier
results are bound separately from the source that built the artifact.

## Local isolated-keychain fallback

The local fallback produces artifacts only and has no upload or TestFlight
operation. The hosted validation exercise above has a separate explicit upload
selection. To return production packaging to manual signing, select `manual`
in the existing iOS Delivery Package operation.

Run from an idle macOS host with Xcode 26.6 and at least 10 GiB free:

```sh
python3 scripts/release/cloud-signing-poc.py --signing-mode cloud-poc \
  --version 1.0.1 --build 16 --team R3JK7R29AC --run-id cloud-poc-01
```

Commit the experimental source first. The command binds receipts to its exact
clean SHA/tree and builds only tracked inputs in a separate output directory.
Supply `AEGIS_ASC_KEY_ID`, `AEGIS_ASC_ISSUER_ID`, `AEGIS_ASC_KEY_PATH` and
`AEGIS_IOS_FIREBASE_DEV_PLIST_BASE64`. If ASC credentials are absent, the existing
local credential parser can discover the unique private credential configuration
in Downloads; it never evaluates shell code or reads a P12/password file.

The PoC temporarily selects a fresh keychain as the user default and entire user
search list, restoring both on success, failure, SIGINT, SIGTERM and SIGHUP. Do
not run concurrent native signing jobs on this host. With explicit Development
configuration and its private password companion, the selected owned non-login
Development keychain is unlocked in this worker session and tested before archive.
Activation failures restore an initially locked keychain; existing unlocked state
is preserved. No keychain import or ACL change is performed. Automatic archive signing may create
a development certificate/key and provisioning profiles in the Apple account;
automatic export may create managed distribution assets. The temporary local key
is deleted afterward; account-side assets are retained for inspection.

The experiment refuses visible Distribution private identities before archive,
before export and after export. It uses automatic development signing for archive
and automatic `app-store-connect` signing with `destination=export`. Both native
commands use the ASC key and `-allowProvisioningUpdates`; no distribution P12 is
imported, and the build number is never automatically changed.

Evidence lives under `.artifacts/cloud-signing-poc/<run-id>/`: archive/export
logs, archive, exported IPA, signature verification and a source-bound receipt.
On failure the receipt retains the failure stage; never label an archive-only
result a signed IPA. Verification checks all three bundle identities, signature,
Apple-trusted signing chain, actual signed entitlements, App Store profile
expiration/type, signer membership in each profile, shared resources and selected
Firebase registration. Actual certificate fingerprints/profile UUIDs are recorded
per artifact to support certificate rotation. Manual verification keeps requiring
its configured fingerprint and profile names.

This local PoC does not establish hosted-CI acceptance, Apple upload/processing,
TestFlight availability or device acceptance. Those results require their own
source-bound runs through the hosted integration above.

Targeted checks:

```sh
python3 -m unittest discover -s scripts/release -p test_cloud_signing_poc.py
python3 -m unittest discover -s scripts/release -p test_verify_signed_ios.py
git diff --check
```

## First execution, 2026-11-04

Archive source: `4a1c8d8068ec8928a7040fc1bfbaafddcae9c118`, tree
`c0f626e437731f3a9884901198c556f191678e6f`, based on upstream main
`dad8953280fccb2f241a553ee8e83ee7685bab6a`. Xcode 26.6 (17F113),
version 1.0.1, build 16, beta configuration.

The complete archive passed with `Apple Development: Created via API` and no
Distribution private identity available. Export failed with exit 70 and Apple
HTTP 403 `FORBIDDEN_ERROR`: the existing Fastlane-CICD App Manager Team API key
does not have access to cloud-managed distribution certificates. No IPA was
produced and no upload was attempted. The original keychain search list/default
were restored and the disposable keychain was removed. Automatic provisioning
created development signing assets; account-side assets are retained.

The initial receipt writer incorrectly passed `opener` to `Path.open`; the
failure receipt was reconstructed from retained native logs and an explicit host
readback, with that reconstruction marked in the receipt. The writer is fixed
and covered by an exclusive-write/private-permissions regression test.

The successful archive and per-file hashes are retained in
`.artifacts/cloud-signing-poc/cloud-poc-01/`. After authorized credentials are
available, reuse the archive without repeating compilation:

```sh
python3 scripts/release/cloud-signing-poc.py --signing-mode cloud-poc \
  --version 1.0.1 --build 16 --team R3JK7R29AC --run-id cloud-export-02 \
  --archive-from cloud-poc-01
```

The retry verifies every archive file hash, prior identity and no-P12 evidence,
and rejects changed native source inputs. Its receipt preserves the original
archive source separately from the export/verifier execution source. Set the
three `AEGIS_ASC_*` variables explicitly when using a different Team API key;
the command does not change shared CI secrets or the production signing selection.

## Accepted cloud IPA, 2026-11-04

The user authorized a separate Admin Team API key named `Tools-Coud-PoC`
(`A9AQKA2C48`). Export attempt 02 passed the cloud permission gate but received an
HTML response where Xcode expected JSON while obtaining the Share profile.
Attempt 03 reused the same hashed archive and completed `EXPORT SUCCEEDED`.

The first verifier incorrectly required Safari's signed entitlements to contain
an App Group, although its committed entitlements are empty. Commit
`8ac40fc156411db11dede83411ac385a7b2ccebd` checks each target against its own
committed entitlement file. The unchanged IPA then passed the independent
verification; the earlier failure receipt is retained alongside a separate
`poc-acceptance.json`.

- Archive source: `4a1c8d8068ec8928a7040fc1bfbaafddcae9c118`.
- Export execution source: `05f45bd0191120dba3f21455228317f6bb4b550f`.
- Verifier source: `8ac40fc156411db11dede83411ac385a7b2ccebd`.
- IPA: `.artifacts/cloud-signing-poc/cloud-export-03/Aegis-cloud-poc-1.0.1-16.ipa`.
- IPA SHA-256: `211d5acd77dd5db0c93d873b9a9236893baeebd826837ee6f2854d900cb5818b`.
- All three signers: `56CA47A01A967A31A21787EA913655AAC70A9241`.
- Three App Store profiles, signed entitlements, Apple-trusted certificate chains,
  deep signatures, 20 shared resources and Firebase registration passed.
- No Distribution P12 imported; no Distribution identity visible before/after
  export; original keychain/default restored. No Apple upload or device test.

Manual was the production default at this historical execution. This result is
local Xcode proof; the later hosted probe and current cloud default are recorded
separately above.

## Shared Fastlane credential rotation

On 2026-11-04 the user authorized replacing the previous Fastlane-CICD key
`J3T6XW486V` with `Tools-Coud-PoC / A9AQKA2C48` across the current iOS/macOS
consumers. The old key was subsequently revoked in App Store Connect.

| Consumer | Repository credential names |
| --- | --- |
| HomeGuard-iOS | `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_CONTENT_BASE64` |
| MacCleaner | `APP_STORE_CONNECT_API_KEY_KEY_ID`, `APP_STORE_CONNECT_API_KEY_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_KEY_CONTENT_BASE64` |
| Watermark | `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_CONTENT_BASE64` |
| Aegis | `AEGIS_ASC_KEY_ID`, `AEGIS_ASC_ISSUER_ID`, `AEGIS_ASC_KEY_BASE64` |
| apple-signing | `APPLE_PORTAL_KEY_ID`, `APPLE_PORTAL_ISSUER_ID`, `APPLE_PORTAL_KEY_CONTENT` |

All 15 repository aliases were written and their metadata read back. Nine
existing environment secrets were also updated across HomeGuard's `ios-release`
and `ios-testflight`, and Aegis's `aegis-ios-store`. Reusable workflow callers
resolve repository/organization credentials before the protected jobs start, so
their repository aliases are included. No signing certificate/profile defaults
or manual-signing behavior changed.

GitHub still denied organization-secret administration after the CLI received
`admin:org`. Existing organization values were not edited: repository aliases
cover the identified consumers, while environment values retain priority, per
the [GitHub secrets precedence rules](https://docs.github.com/en/actions/reference/security/secrets).
Organization-level stale ciphertext cleanup requires an authorized owner.

The new credential passed ASC `GET /v1/apps` (six apps), macOS `notarytool history`,
and the existing Aegis hosted Status workflow
[41818053939](https://github.com/gcsagroup/aegis-browser/actions/runs/41818053939)
at main `dad8953280fccb2f241a553ee8e83ee7685bab6a`. That workflow only queried
the existing 1.0.1 (15) build; it did not package/upload the PoC IPA.

Seven local shared/project parameter files were updated, and their referenced
private key files were checked for matching bytes and private permissions.
Detailed mutation/readback, active-run inventory and cleanup receipts are kept
locally under `.artifacts/asc-rotation/`; no private keys are committed.

After revocation, fresh ASC read-only requests returned HTTP 401 for the old key
and HTTP 200 for the new key. Downloads cleanup removed exactly two fingerprinted
files (708 bytes): the revoked key's `.p8` and a superseded shared configuration
backup. The current shared/project parameter files, standard Fastlane aliases,
new private key and README remain in the local credentials directory. Other
certificates/profiles were retained. Detailed deletion hashes are in
`downloads-cleanup-receipt.json` and the Downloads `rotation-receipt-20261104.json`.
