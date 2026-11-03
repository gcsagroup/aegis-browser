# iOS localization: first slice

This is a usable first slice, **not complete localization of Aegis**. The new
languages each translate **131 of 1,068** catalog entries; **937 entries per new
language use explicit English fallback** copied from the same key's `en` value
and marked **`needs_review`, never `translated`**. These remain untranslated in
the target language. Existing translations in all 14 resource languages are
preserved. English, Simplified Chinese and Traditional Chinese each have 1,068
translated entries (1,061 existing entries plus seven newly catalogued strings).

| Resource languages | Translated per language | English fallback (`needs_review`) per language | Total per language |
| --- | ---: | ---: | ---: |
| de, es, fr, id, it, ja, ko, ms, pt, th, vi | 131 | 937 | 1,068 |
| en, zh-Hans, zh-Hant | 1,068 | 0 | 1,068 |

Baseline: `059aa8a8d4e91c339486c0228e5cdb23f3c6f961`. Implementation is confined to
`apps/ios`. Delivery integrates the current development branch separately from this original
implementation baseline. Focused localization checks do not establish
full-repository CI or release readiness.

## Locale mapping

The requested inventory matches the HomeGuard iOS Runner reference from the
2026-11-02 app-review worktree. Its `.lproj` names were used as the inventory;
HomeGuard's camera/scanning permission wording does not describe Aegis and was
not copied.

| Requested preference | Native resources |
| --- | --- |
| de, en, es, fr, id, it, ja, ko, ms, pt, th, vi, zh-Hans, zh-Hant | Matching `.lproj` / catalog language |
| en-GB, en-HK | en |
| zh-Hant-HK | zh-Hant |

The three regional variants reuse existing general-language translations. This
does not claim British/Hong Kong editorial adaptation. There are deliberately no
empty variant `.lproj` directories or `CFBundleLocalizations` entries advertising
resources that do not exist. All three native bundles explicitly retain
`CFBundleDevelopmentRegion = zh-Hans`.

[Apple QA1828](https://developer.apple.com/library/archive/qa/qa1828/_index.html)
describes language/region fallback. The host test also verifies actual compiled
resource selection and `InfoPlist` lookup in a fresh, localized `.app` process for
each of the 17 preferences, rather than testing only a hand-written locale map.
This is macOS Foundation evidence; the separate iPhone Simulator checks are
listed below.

The WebExtension uses `_locales` with `zh_CN`/`zh_TW` and `pt_PT`/`pt_BR`, as well as
the other base language identifiers. Both Portuguese metadata directories use the
same general Portuguese wording. English is its required default locale.
`WKWebExtension` metadata lookup was exercised for all 17 requested preferences,
including the Hong Kong Chinese and English variants. It resolves actual
`__MSG_*__` tokens using WebKit, not a custom JavaScript fallback implementation.
See the [WebExtension i18n format](https://developer.chrome.com/docs/extensions/reference/api/i18n)
and [Apple's extension structure](https://developer.apple.com/documentation/safariservices/creating-a-safari-web-extension).

## Delivered surface

- Browser chrome, address field and accessibility label, tabs/groups, keyboard
  commands, find-in-page results, sharing/bookmark confirmation, privacy notices,
  navigation intervention banners, and the normal start-page WebView.
- Top-level settings/about/appearance controls. The previous three-language-only
  settings description is replaced with a language-neutral description of the
  system app-language setting; its old translations remain in the catalog.
- App `InfoPlist.strings`: camera, microphone and Markdown document type text.
  The existing camera/microphone translations remain byte-for-byte intact. The
  document type uses the existing `Markdown 文档` value as its localization key,
  following [Apple's document type guidance](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app).
- Share extension: localized system display name, all app-authored success/status
  and error messages, with the existing shared catalog bundled in this target.
- Safari extension: localized native display name plus manifest name, description
  and toolbar action. `_locales` is a folder resource in both Aegis and the Safari
  extension, preserving the required `locale/messages.json` hierarchy.
- `project.yml` source registration and the checked-in Xcode project agree on the
  resources. Native `.lproj` directories register the 14 physical languages;
  regional preferences use the tested fallbacks. The new XCTest files are in
  their respective source build phases.

The start page now declares its selected language and HTML-escapes translated
text. The DEBUG research/shopping/injection fixtures deliberately retain their
Chinese language/content. Existing broken dynamic-string paths for find results,
tracking-cleanup notices, the empty tab host label, the WebKit engine value and
share errors now use localization lookup. User-entered titles, addresses and
content are not treated as localization keys.

## Remaining gaps

| Surface | Remaining work |
| --- | --- |
| Native catalog | 937 English fallback entries (`needs_review`) in each of the 11 added languages. AI/model setup and consent, advanced protection/site settings, downloads, reading/library, bookmark/workspace operations, recovery and window management remain largely in English. Some background/browser-policy diagnostics also still need translation. |
| Swift call sites | Catalog coverage is not complete call-site coverage. Framework and model errors/statuses still include hard-coded Chinese strings; this slice does not claim a complete extraction audit of every dynamic string. |
| Markdown WebView | `MarkdownReaderView` already passes the app language to the shared viewer. The shared `enhancements_shared/i18n.js` dictionary supports English and Chinese only; the 11 new languages use its English fallback, and some dynamic controls still contain Chinese. That shared implementation lives outside `apps/ios` and was not changed or copied. |
| Website enhancements | Native advanced UI and script/editor/error messages are mostly outside this translated slice. Web content, installed scripts and model-generated answers are not app UI translations. |
| System/extension presentation | Resource lookup and WebKit metadata parsing passed on macOS. iOS permission dialogs, Files document labels, Safari's extension UI and the share-sheet presentation have not been visually exercised. Provider/system-generated errors use the platform's own localization. |
| Linguistic/layout acceptance | New translations need native-speaker review and iPhone/iPad layout/VoiceOver acceptance, including long German strings, Thai/Vietnamese text and accessibility sizes. Portuguese uses mostly European terminology; no Brazil-specific editorial pass is claimed. |

Foundation does not fall through to English per missing key after selecting a
partial locale, even when English is the next preferred language. The first
candidate exposed Chinese keys in consent and destructive-action dialogs. All
937 missing keys per new locale now have explicit English catalog values with
state `needs_review`; `xcstringstool` emits these values into the locale's compiled
table. The regression checks both the source state/value and actual compiled
English lookup. Fallback entries are not counted as translated; compiled table
size is not a translation-completion metric.

## Checks and reproduction

From the repository root on macOS with Xcode installed:

```sh
python3 apps/ios/scripts/test-localizations.py
node apps/ios/Tests/SharedWebExtension/SafariNavigationIdentityTests.mjs
git diff --check
```

`test-localizations.py` uses only the standard library and Xcode command-line
tools, with artifacts in a fresh `/tmp/aegis-ios-localization-*` directory. It:

1. Compiles the real catalog with `xcstringstool`, checks resource registration,
   original translation hashes, system strings and printf argument types. Every
   fallback outside the translated slice must match `en` and remain `needs_review`.
2. Runs a fresh localized `.app` probe for each requested preference, checking
   actual Foundation lookups, number/string substitution and system metadata.
   For each of the 11 new locales it also loads seven missing consent/deletion
   strings (titles, actions and explanatory text) and requires the actual English
   copy from the compiled `en` table, including `将资料发送给模型？`, `确认发送`
   and `清除网站数据？`.
3. Compiles and executes the production start-page renderer and ShareInbox code:
   HTML language selection, markup escaping, localized errors, URL rejection,
   size limits and the 60-second envelope lifetime are tested.
4. Parses the actual WebExtension with `WKWebExtension` and checks all three
   localized metadata fields plus parser errors for every requested language.
5. Checks that extension permissions and CSP stay unchanged, and reports the
   translated and English fallback (`needs_review`) counts separately.

`Tests/Localization/coverage.json` records the exact translated key set and
preservation hashes. Its small identical-English allowlist contains legitimate
shared terms such as German “Name”, “Version”, “Tabs”, “Downloads” and “App”; it
does not permit English sentence placeholders to be marked `translated`.

The existing Safari navigation-identity regression passes. The changed Swift
sources and new XCTest files also pass syntax parsing, and the project/strings
files pass property-list parsing. Host checks used macOS 26.6.2 and Xcode 27.0.
After the fallback fix, the host regression passed all 17 preferences, including
77 English consent/deletion lookups (seven strings in each of the 11 new locales).
All 10,307 fallback entries matched `en` and retained `needs_review`; comparison
with the pre-fix catalog confirmed all 4,645 existing locale entries unchanged.

Build evidence and pending gates are distinct:

- The reviewed implementation passed an unsigned simulator `build-for-testing`
  with isolated pinned dependencies after the English fallback fix.
- Five `LocalizationTests` passed on iPhone Simulator. The UI test passed all
  17 language preferences at the largest accessibility text size, recording a
  settings screenshot for each preference. These checks cover resource lookup,
  address labels and settings navigation; screenshots alone do not establish
  complete layout or linguistic acceptance.
- These results identify the original implementation candidate. Integration,
  final clean-HEAD local full checks, fresh independent review and hosted CI are
  tracked separately in the delivery PR; prior results do not transfer to changed
  code automatically.
- iPad, real-device, system permission/share/Safari presentation, native-speaker
  review and full-app translation remain pending. No signing, upload or release
  is part of this slice.
