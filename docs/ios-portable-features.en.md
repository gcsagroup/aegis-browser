# iOS Ver 4.0 guide

[简体中文](ios-portable-features.zh-CN.md) · [繁體中文](ios-portable-features.zh-TW.md) · [English](ios-portable-features.en.md)

This work adds browsing settings, a reading library and limited browser operations using SwiftUI and system WebKit. See the [platform comparison](platform-features.en.md) and [acceptance record](audit/ios-portable-features-2026-10-11.zh-CN.md). This remains a development candidate. Simulator results do not establish physical-device, App Store or four-platform release acceptance.

The current candidate is **Ver 4.0 (82)**. The original acceptance record covers the earlier feature batches. Search-engine removal passed related regression tests on both Simulators and an actual interaction check; see the [search-engine acceptance record (Simplified Chinese)](audit/ios-search-engines-2026-10-11.zh-CN.md).

## Search, home page and browsing

Open **More → Settings → Search, home page and browsing**. Choose DuckDuckGo, Google, Bing, Baidu or custom search, then **Save browsing settings**. Custom templates must use HTTPS and contain `{searchTerms}` exactly once in a query parameter, for example `https://www.google.com/search?q={searchTerms}`. Search text is encoded as parameter data rather than URL structure.

Expand **Manage search engines** and use the delete button beside an engine to remove a preset or the custom option. Removing the selected engine selects the first remaining engine. Removing all engines disables address-bar searches while keeping direct web addresses available. **Restore preset engines** restores the list and preserves your custom template. Tap **Save browsing settings** to apply these changes; they persist after restart.

Set the home page and startup behavior on the same screen: restore normal tabs, show the start page or open the home page. Startup behavior applies when a browser window is created. “Use home page for new tabs” applies to new tabs. Private tabs do not survive relaunch.

Page settings cover zoom, desktop sites, JavaScript, script popups and media playback. Site-specific rules take priority. JavaScript and desktop mode apply after a reload; popup and media options apply to new tabs. Turning history off stops new entries. Clear existing history separately in privacy settings.

## Sites and protection

- **Settings → Site settings and permissions**: select the current or a saved site to set zoom, mobile/desktop mode, JavaScript, camera and microphone access. Rules are separated by protocol, host and port. Camera and microphone provide Ask or Block and still require system permission. Up to 200 sites can be saved.
- **Settings → Manage site data**: select a site and confirm clearing. Normal tabs across all windows close first to prevent immediate writes. Private tabs, bookmarks, workspaces and reading items are preserved. The existing clear-all entry removes all normal site data.
- **Settings → Protection options**: control tracking parameter cleanup, local high-risk URL checks and foreground filter updates. Automatic checks default to off. When enabled, they run as normal browsing enters the foreground, at least 24 hours after success or 1 hour after failure. Failed updates keep the previous rules.
- **Open system app settings**: opens iOS controls for language and hardware permissions. Default-browser options depend on installation eligibility and OS version.

Turning off a navigation check does not allow credentialed URLs or arbitrary script schemes. iOS manages system WebKit protections and permission prompts.

## Reading, notes and translation

1. Open an ordinary page, then **More → Reading and notes → Read current page**. The app reads the current page text. Login and payment forms are rejected; input values and hidden text are excluded. Text is limited to 24,000 characters, with a truncation notice when needed.
2. Copy a passage into the quote field, add notes, then **Save item and notes**. Quotes must appear in the original and are highlighted. Reading stays in the current view until you explicitly save it to the local encrypted library.
3. For translation, configure a model service, then **Preview and translate**. Review the endpoint, model and redacted text before confirming. Notes, history and PDFs are not sent. Save after generation to keep the translation. Wide iPad layouts show original and translation side by side; iPhone stacks them.
4. Search saved titles, sources, text, notes or translations. Archive an item from its editor; enable Show archived items to reopen it and clear its archive switch. Plain-text export includes the original, source, notes and translation.
5. Deleting requires another confirmation and cannot be undone. Exported files remain. The library holds up to 100 items and 8 MB in total; archived items count toward these limits.

The library uses AES-GCM with a key stored in this device's keychain. Decryption failures preserve the original file and prevent writes. Conflicting saves from another window or stale editor are rejected; reopen the item before saving. Copying ciphertext alone is not a cross-device backup because the device key is not included.

Private reading does not automatically save text or source URLs. Saving and exporting explain what remains stored and ask for confirmation. Cancelling the translation preview sends no model request. Translations need human review. Synthetic model acceptance verifies requests and interaction, not real-model translation quality.

### PDF

Choose **Import a PDF page**, select a file from Files and enter a page number starting at 1. Only that page's existing text layer is extracted. Limits are 20 MB and 1,000 pages. Scanned pages without text, encrypted files and invalid page numbers produce an error. OCR is unavailable. PDF text is read, saved and exported locally.

## Browser operations

Open **More → AI assistant → Browser operations and workflows** and select tabs in the current window and browsing mode.

- Choose grouping, saving a workspace, opening URLs you enter, reloading, closing or scrolling down the current page. Enter the name or URLs, preview the scope, then confirm execution.
- Alternatively, describe a goal for the model. The first confirmation sends only the goal and redacted titles and URLs. Returned steps are validated, and a second confirmation is required before execution.
- A plan allows up to 6 steps, 16 selected tabs and 16 entered URLs. It expires after 5 minutes and cannot be replayed. Changes to the window, mode, source page or navigation version require a new preview.
- Close and reload must be the final step. The model cannot add URLs you did not supply, run arbitrary scripts, fill forms, sign in or pay. Cancellation leaves completed steps in effect and reports the count; there is no whole-plan rollback.

Saving private URLs as a normal workspace explicitly warns that they remain after private tabs close.

## Foreground page checks

Open **Check current page for updates** from browser operations. Select 1, 5 or 15 minutes and confirm. The app reads the current text, then reloads and compares text digests at the chosen interval. It shows the count, time and change status. Text is neither saved nor sent to a model. Leaving the panel, changing mode or entering the background stops checks. There is no schedule while the app is closed. Reloading can affect temporary page state, so use ordinary information pages.

## Download network and size settings

Open **More → Downloads → Download settings and storage**. Control cellular, metered and Low Data Mode access, and choose a 100 MB, 500 MB, 1 GB or 5 GB limit per file. New tasks capture the current rules. Resumes, mirror changes and restored tasks retain their original rules. iOS may delay background transfers. After force-quitting, reopen the app and verify download status.

HTTP downloads, Metalink, mirror failover and hash verification remain available. BitTorrent and magnet support need an iOS-specific backend and background design and are not ported here. Arbitrary third-party extension installation, account sync and deep Chromium/V8 protection modules are also outside this implementation. Consult the [platform catalog](platform-features.en.md) for source and acceptance status.
