[**English**](./play-store.md) | [简体中文](./play-store.zh-CN.md) | [繁體中文](./play-store.zh-TW.md)

# Play Store readiness draft: No-Go

This document records future identity, policy, and review gates. It is not a submitted Play declaration.

The current project has:

- no Android build produced from the current source;
- no current identity-bound APK or AAB;
- no production upload key;
- no Play Console application or uploaded artifact; and
- no approved Data Safety form or public privacy-policy URL for a candidate.

No Play action is authorized by this draft.

## Reserved identity

| Item | Reserved target |
|---|---|
| Application ID | `app.gcsa.aegis` |
| Display name | GCSA-aegis |
| Short name | Aegis |
| Default listing language | Simplified Chinese |
| Target architecture | `arm64-v8a` (`target_cpu = "arm64"`) |
| Future signing | Play App Signing; only the upload key is held locally |

The GN application-ID setting proves configuration only. It does not prove the final APK/AAB identity, signing, branding, or store compliance.

Do not publish under Chrome or Google Chrome branding, and do not use Chromium's default icon as the final store asset.

## Data Safety boundary

The statements below are design goals that require verification against the exact candidate. They must not be copied directly into Play Console:

- The product is intended not to collect account, location, contacts, or similar personal data for GCSA-aegis services.
- Chromium default services, metrics, crash reporting, updates, and all third-party components still require candidate-specific review.
- Android page summary is currently unavailable. Any future implementation must document local processing and every user-configured remote destination accurately.
- The product is intended not to bundle a third-party analytics SDK, but the final dependency graph, runtime configuration, and network capture must prove that claim.
- EasyList or other external updates must not expose browsing history, page URLs, persistent identifiers, or unnecessary headers, and their behavior must be disclosed truthfully.

The final Data Safety form must be based on the same APK/AAB, version configuration, permissions, storage behavior, dependency set, and captured network behavior that will be submitted.

## Publication gates

1. Build a current-source Release APK/AAB in a clean, supported x86-64 Linux environment.
2. Bind the repository commit, Chromium commit, 56 Chromium patches, 2 nested V8 patches, GN arguments, package identity, and artifact hashes in a verified manifest.
3. Pass device tests for First Run, normal browsing, `chrome://aegis`, core protections, lifecycle, storage, upgrades, and network behavior.
4. Replace default Chromium icons and audit all names, screenshots, descriptions, and restricted brand assets.
5. Complete permission, outbound-network, data-storage, logging, native-library, third-party-license, and privacy-policy reviews.
6. After explicit approval, create the Play Console application, enroll in Play App Signing, generate the upload key, and complete the listing and Data Safety form.
7. Start with an internal test track and review response before deciding on wider testing.

An accepted internal Android candidate is not automatically Play-ready.

## Related documents

- [Android build and acceptance status](./android.md)
- [Fork architecture](./fork-architecture.md)
- [Browser README](../README.md)
