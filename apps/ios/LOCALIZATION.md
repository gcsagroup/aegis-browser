# iOS catalog localization

All **1,086 catalog entries** are translated in each of the **14 resource
languages**. The original 1,068-entry completion covered the 937 previously untranslated entries in each of
the 11 added languages: **10,307 new translations**, with no `needs_review`
English prose fallbacks. The existing 131 translations in each added language
and all English, Simplified Chinese and Traditional Chinese entries are preserved.

| Resource languages | Translated per language | English fallback (`needs_review`) | Total per language |
| --- | ---: | ---: | ---: |
| de, es, fr, id, it, ja, ko, ms, pt, th, vi | 1,086 | 0 | 1,086 |
| en, zh-Hans, zh-Hant | 1,086 | 0 | 1,086 |

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

## Agent contract errors (iOS 1.0.1)

The 16 user-facing contract errors use stable semantic keys in AgentKit's
`AgentErrors.xcstrings`. The framework owns the table and the generated Swift
symbols, so lookup follows the framework bundle. Editing a translation does
not rename a Swift reference. The app and share extension continue to use
their existing shared catalog for their own UI.

The error table has all 17 requested localizations. UK and Hong Kong English
use British spelling such as “authorisation”. Hong Kong Traditional Chinese
uses 身份 for page identity, and Taiwan Traditional Chinese uses 身分. Identical
wording across regional variants is intentional where the meaning and usage agree.

`AgentContractError.errorDescription` uses the shared family/dialect resolver and
typed adapter while retaining the generated resource's framework bundle and table.
The adapter checks compiled table key membership, selects the regional resource,
and supplies an explicit resource locale with system formatting overrides.
Ordinary literal resources use an explicit `.lproj` bundle: supplying only a locale
to `String(localized:bundle:locale:)` does not switch its resource language.
Generated semantic resources retain their keys and bindings; Foundation renders
interpolation and plurals. A value identical to its key is a valid translation,
not a missing-key signal. Fallback is regional resource, family, then English;
Traditional Chinese never falls back to Simplified Chinese.

`testContractErrorDescriptionsHonorRequestedSystemLocale` compares all 16 actual
`errorDescription` and bridged `NSError.localizedDescription` results with the
selected compiled AgentKit table and records requested/selected locales. Run it
in fresh test hosts for all 17 preferences; explicit-resource-locale tests alone
do not validate this default caller path.

For this batch, prefer String Catalogs over converting to per-language
`.strings` files. The framework builds with generated symbols, existing app
translations keep their inventory and regression checks, and the simulator
can exercise the compiled framework table in each locale. Per-language files
would isolate translation diffs, but replacing the existing catalogs would
require migrating their checks and supplying a separate typed lookup mechanism.
Use semantic keys incrementally as features change.

## In-app language selection

Settings → Language offers Follow System and the 14 language autonyms, with one
English and one Traditional Chinese choice. `AppLanguageSettings` observes an
injectable preference store. Only the family is persisted under
`browser.languageFamily.v1` in `group.com.gcsa.aegis.ios.share-inbox`; Follow System
removes it. Other preferences, credentials and content keep their existing stores.
The Share Extension rereads the choice on appearance and before new messages.

`Shared/AppLocalization.swift` is compiled internally into the app, BrowserKit,
AgentKit and Share Extension. Ordered explicit same-family language preferences
choose the dialect before generic preferences use the system region. An explicit
en-US remains US with a GB region; an unsupported specific English region falls
back within English. zh-HK/zh-TW aliases select Traditional Chinese, while explicit
zh-Hans-HK remains Simplified. Main app/share regional wording still reuses the
14 base resources; only AgentKit has the 17 regional tables described above.
Translation language is separate from system region, calendar, hour cycle,
numbering and time-zone formatting. Fixed POSIX/ISO8601 codecs remain unchanged.

SwiftUI views observe locale changes. Translated navigation titles use a locale-observing
modifier that materializes a typed resource into verbatim text for native navigation
chrome, without replacing destination identity. Commands observe the controller revision,
and UIKit updates placeholders/accessibility without replacing text fields or
first responders. Presentation-owned cached messages retain typed resources or
errors until displayed. Recorded/user/model content is not rewritten. New model
requests capture the effective language; requests already running keep their inputs.
Sessions, windows, tabs, WebViews, drafts, downloads and agents retain their identity.
Loaded app-owned start pages update text nodes through structured WebKit arguments
with exact native/JavaScript URL, document-token and revision checks. External
pages are neither modified nor reloaded. iOS-owned permission and Safari metadata
presentation remains system-managed.

The only catalog additions are Language and the regional matching note, each with
14 translations. `coverage.json` records these separately from the historical
1,083-key inventory; existing values and preservation hashes at branding baseline
`3eea1244651d881ec506a5b1c2dab0661095e15f` remain unchanged.

Focused host checks (use a new output directory):

```sh
python3 apps/ios/scripts/test-app-language.py --work-dir /path/to/new/task-cache-output
```

This compiles actual catalogs and checks 45 independent policy fixtures, owners,
fallback, persistence, formatting, interpolation/plurals, typed compiler extraction,
catalog rejection guards and native-evidence rejection guards. `--plist-fixtures`
is an explicit fallback for environments without the catalog compiler and is not
compiled-catalog evidence. Pure tests inject in-memory defaults. DEBUG app/framework
providers use `com.gcsa.aegis.ios.ui-tests`; reset precedes store construction and
`--ui-testing-preferences-keep` preserves only the intended test-run preferences.

The 17-host Agent runner additionally accepts repeatable `--policy-case` names
from `language-policy.json` to cover manual families, generic preferences and region
conflicts. Expected family/resource/region evidence is supplied independently and
mismatches are rejected. `AppLanguageTests` covers native runtime continuity,
start-page ownership, UIKit editing and active download/model work.
`AppLanguageUITests` covers same-process selection, unique family entries, Settings,
address/find/start-page refresh, external form continuity and relaunch persistence.
Run on both iPhone and iPad, including large Dynamic Type. The UIKit editing test
requires an isolated `--ui-testing` host without a fixed language-family argument
override. Host tests do not establish iOS compilation, XCTest/UI acceptance, CI or
independent review; those remain separate candidate verification gates.

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
2. All 1,085 source values against the actual compiled `.strings` table and
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
