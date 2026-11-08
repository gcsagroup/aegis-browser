# Firebase registrations

| iOS channel | Firebase project |
| --- | --- |
| Dev, Alpha and Beta | `gcsa-aegis-dev` |
| Release | `gcsa-aegis-prod` |

Both Firebase apps register the Bundle ID `com.gcsa.aegis`. The approved project IDs and Firebase App IDs are pinned in [identities.json](identities.json).

For a local Dev build, place the DEV project's downloaded `GoogleService-Info.plist` in `apps/ios/Firebase/dev/` and select the `Aegis-Debug` scheme. A build without that local file leaves Firebase disabled. Use the existing Fastlane `--profile` for signed Alpha, Beta and Release packages. Fastlane stages the selected config and verifies the final IPA against it.

For Actions packaging, set the `AEGIS_IOS_FIREBASE_DEV_PLIST_BASE64` and `AEGIS_IOS_FIREBASE_PROD_PLIST_BASE64` configuration variables in the `aegis-ios-signing` environment to the base64-encoded iOS plists downloaded from their respective Firebase projects. The local Fastlane command reads variables with the same names. Keep the downloaded files out of Git. An unsigned Release validation build defaults to Firebase disabled.

Crash reporting, usage analytics, and remote diagnostics configuration each default on when no explicit choice has been saved. Existing saved choices are preserved. Privacy & Protection shows a diagnostics entry that opens the independent switches, including when this build has no Firebase registration. A build from a different Firebase project pauses telemetry when installed over an existing installation. This preserves the browser's data and keeps cached telemetry in its original environment. Use a fresh app container to verify telemetry after changing projects.

Remote Config can only pause diagnostics that the user has allowed; it cannot enable consent or control browser features. The [configuration template](remote-diagnostics-template.json) documents the three allowed parameters. It is not automatically published. Apply it to the correct project only as a separately authorized operation. The [control design](../../../docs/plans/ios-firebase-controls.zh-CN.md) specifies cache expiry, named-app installation cleanup, and the limits of revoking queued crash reports.

Archive dSYMs with the IPA. Run symbol upload explicitly after verifying the IPA. Use the official `upload-symbols` tool with the source registration that was verified in that IPA, or upload to the corresponding app's dSYM console. [Firebase symbol upload instructions](https://firebase.google.com/docs/crashlytics/ios/get-deobfuscated-reports)
