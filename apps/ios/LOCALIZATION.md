# iOS catalog localization

All **1,068 catalog entries** are translated in each of the **14 resource
languages**. This completes the 937 previously untranslated entries in each of
the 11 added languages: **10,307 new translations**, with no `needs_review`
English prose fallbacks. The existing 131 translations in each added language
and all English, Simplified Chinese and Traditional Chinese entries are preserved.

| Resource languages | Translated per language | English fallback (`needs_review`) | Total per language |
| --- | ---: | ---: | ---: |
| de, es, fr, id, it, ja, ko, ms, pt, th, vi | 1,068 | 0 | 1,068 |
| en, zh-Hans, zh-Hant | 1,068 | 0 | 1,068 |

The preservation baseline is `c7f45b21972bfc33c53c0c90bc0a48e9e517103e`.
Changes are confined to `apps/ios`. Catalog completion does not establish full-app
translation, native-speaker acceptance, hosted CI or release readiness.

## Locale mapping

| Requested preference | Native resources |
| --- | --- |
| de, en, es, fr, id, it, ja, ko, ms, pt, th, vi, zh-Hans, zh-Hant | Matching `.lproj` / catalog language |
| en-GB, en-HK | en |
| zh-Hant-HK | zh-Hant |

The three regional variants reuse existing general-language translations. There
are no empty variant `.lproj` directories or `CFBundleLocalizations` entries.
All three native bundles retain `CFBundleDevelopmentRegion = zh-Hans`.
British/Hong Kong editorial adaptation is not claimed. Portuguese follows the
existing European terminology; there is no Brazil-specific editorial pass.

The Safari WebExtension retains `_locales` with `zh_CN`/`zh_TW` and
`pt_PT`/`pt_BR`, alongside the other base language identifiers. Both Portuguese
metadata directories retain the same general Portuguese wording; English remains
the required default. The host probe exercises actual `WKWebExtension` metadata
resolution for all 17 preferences.

## Translated surface and semantics

The catalog covers browser controls, settings, downloads, reading and library
controls, bookmarks and workspaces, recovery, site permissions, website
enhancements and script editing, and AI/model setup and consent. App and share
extension resources use the same catalog. Existing localized system permission
and document-type descriptions, extension display names and WebExtension
metadata remain unchanged.

Translations use the Simplified Chinese source meaning, with English as a
reference. Consent preserves the selected pages, destination service and model;
private-mode notices retain possible provider retention and the absence of
automatic task-history saving. Deletion copy distinguishes removed website data
from retained bookmarks and workspaces. Recovery and one-use authorization copy
retain their explicit negations. Numeric limits and printf argument types,
positions and order are checked across every added-language entry.

The page-assistant translation preset requests the user's active language,
following the existing English/Chinese preset behavior. Actions explicitly
requesting Chinese or English keep that explicit target. Language autonyms,
protocols, product names and format-only templates remain intact. A per-language,
per-key identical-English allowlist records exact values and reasons, including
legitimate shared words such as French “Source” and German “Version”; it does not
allow untranslated sentences or locale-prefixed English text.

## Remaining gaps

| Surface | Remaining work |
| --- | --- |
| Swift call sites | Catalog coverage is not complete call-site coverage. Some framework and model errors/statuses contain hard-coded Chinese; a complete extraction audit remains separate. |
| Markdown WebView | The shared `enhancements_shared/i18n.js` dictionary supports English and Chinese only. Other app languages use its English fallback, and some dynamic controls contain Chinese. This shared implementation is outside `apps/ios`. |
| External content | Websites, installed scripts, user content and model-generated answers are not app UI translations. DEBUG research/shopping/injection fixtures retain Chinese content. |
| System/extension presentation | Resource lookup and metadata parsing do not establish visual acceptance of iOS permission dialogs, Files labels, Safari extension UI or share sheets. System/provider errors use their own localization. |
| Linguistic and accessibility acceptance | Native-speaker review and comprehensive iPhone/iPad layout and VoiceOver acceptance remain separate, including long German strings and Thai/Vietnamese text. |

The first slice used explicit English fallbacks because Foundation does not fall
through to English per missing key in a selected partial locale. Those catalog
fallbacks have now been replaced by actual translations. Historical first-slice
build, review and CI results are not evidence for the completed catalog.

## Checks and reproduction

From the repository root on macOS with Xcode installed:

```sh
python3 apps/ios/scripts/test-localizations.py
node apps/ios/Tests/SharedWebExtension/SafariNavigationIdentityTests.mjs
git diff --check
```

The standard-library host test writes to a new temporary directory, or a new
explicit `--work-dir`. It validates:

1. The full key/language inventory, all translated states, preservation hashes,
   exact printf tokens, numeric constraints and justified identical-English values.
   Negative mutations test blank values, review-state regressions, copied or
   prefixed English, changed limits, broken placeholders and removed negations.
2. All 1,068 source values against the actual compiled `.strings` table and
   Foundation lookup in a fresh process for each of the 17 preferences.
3. Seven literal consent, deletion, recovery and data-boundary probes per
   preference. These fixtures freeze audited text independently of runtime lookup.
4. Localized system metadata in all three bundles, production start-page HTML
   language and escaping, ShareInbox validation/limits/expiry, and actual
   WebExtension metadata parsing with unchanged permissions and CSP.

`Tests/Fixtures/Localization/coverage.json` records the complete inventory and
preservation contract. `literal-probes.json` holds the safety-copy regressions.
Both are bundled in the native test target through its existing `Fixtures`
folder resource. macOS Foundation tests are host evidence, separate from iOS.

On iOS, `LocalizationTests` checks every compiled app/share entry, active-language
lookup and literal probes, regional selection, system resources, share errors,
start-page text and WebExtension metadata. Run this suite in fresh test-host
processes for all 17 requested language preferences. `LocalizationUITests`
launches the app for each preference at the largest accessibility text size,
checks address/settings navigation and the newly translated browsing-settings
title, and records both settings screens. Screenshots do not establish complete
layout or linguistic acceptance.

Candidate SHA, unsigned simulator build/runtime results, independent review,
final clean-HEAD repository checks and exact-head hosted CI belong in the delivery
PR evidence. iPad, real-device, signing, store submission and release remain
separate gates; this delivery does not authorize signing, upload or release.
