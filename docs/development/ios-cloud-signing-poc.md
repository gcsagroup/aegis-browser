# iOS cloud signing PoC

The production delivery workflows and Fastlane entrypoints continue to use manual
signing by default. This separate, explicit experiment produces local artifacts
only. It has no upload, release, review-submission or TestFlight operation. To
return to manual signing, use the existing iOS Delivery Package operation.

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
not run concurrent native signing jobs on this host. No existing keychain is
unlocked or imported, and no ACL is changed. Automatic archive signing may create
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
TestFlight availability or device acceptance. Hosted integration remains a
separate change after this experiment passes, with protected credentials and the
existing trusted-source admission rules.

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
the command does not change shared CI secrets or the default manual flow.

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

Manual remains the production default. This is local Xcode proof; hosted CI is
not yet exercised by the PoC entrypoint.

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
