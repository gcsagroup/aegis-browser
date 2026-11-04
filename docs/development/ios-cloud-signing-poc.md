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
