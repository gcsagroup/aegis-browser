**English** | [简体中文](ios-webkit-protection.zh-CN.md) | [繁體中文](ios-webkit-protection.zh-TW.md)

# iOS Ver 5.0 web protection

For iPhone and iPad running iOS 18.4 or later. Protection combines public WebKit APIs, local rules and page structure checks. This is a development candidate. See the [acceptance record](audit/ios-webkit-protection-2026-10-12.zh-CN.md) and [platform comparison](platform-features.en.md).

## Controls and recovery

Open More → Settings → Protection options to manage risky URLs, known mining resources, known fingerprinting resources, system hardening and experimental strict fingerprint limits. Mining and fingerprinting resource rules are enabled by default and remain independent of the advertising filter.

- **Blocked pages:** known phishing hosts or combined high confidence signals open a native warning. A risky document found by structure checks is replaced and unloaded. Return to the start page or allow the same complete URL in this tab for ten minutes. Navigating to another URL revokes this permission. Other tabs and private windows do not share it.
- **Resource exceptions:** the page menu can allow this origin’s security resources for ten minutes, or restore protection immediately. This pauses mining and fingerprinting rules in the current tab, while phishing navigation checks continue. Restoring rules does not undo scripts already loaded.
- **System hardening:** off by default. On iOS 26.4 or later, the public security restriction disables web JIT; MTE benefits depend on hardware. Earlier systems retain their default WebKit protection and display that limitation. System Lockdown is preserved. Per-site settings take effect after reloading.
- **Strict fingerprint limits:** experimental and off by default. Restrictions on Canvas pixels, WebGL reads and audio output may affect legitimate exports, games and audio. Choose compatibility mode in the site settings and reload to restore those APIs.

System fraudulent-site warnings and known-host HTTPS upgrades remain enabled. HTTPS failure uses WebKit’s user-mediated fallback preference; the app does not bypass system warnings.

## What local checks read

Before navigation, the browser checks exact phishing hosts and URL risk. Registered domains use the Public Suffix List, including private suffixes, plus system URL handling for internationalized names. Separate tenants on shared hosting remain separate sites.

After document commit, an isolated script reads a bounded title, password-field counts, associated form target origins and iframe origins. It checks immediately, then every two seconds for up to one minute. It reads no field values, passwords, verification codes or body text, and makes no model request. Legitimate federated login, one internationalized name or normal drawing alone does not justify unloading a page. Same-document path changes remain checked against the current URL within the original observation window. Navigation, stopping and closing invalidate previous checks; new documents do not retain notices from the previous page.

A separate page script records bounded counts and categories for Canvas, WebGL, Audio, Worker and WASM calls. A page can forge these signals. They provide notices only, never native privileges or an automatic verdict that unknown mining is occurring.

## Rules and updates

Bundled version `2026101201` contains 190,191 exact phishing hosts, 312 mining hosts and four specific fingerprint collection endpoints. [Source metadata](../apps/ios/BrowserKit/Resources/security-rules-sources.json) includes hashes and licenses.

- [Block List Project](https://github.com/blocklistproject/Lists): phishing hosts; repository Unlicense, with an older MIT label in the list header. Its declared update date is **2026-07-06**, so this is not real-time evidence that a host is still malicious.
- [NoCoin](https://github.com/hoshsadiq/adblock-nocoin-list): known browser mining hosts, MIT.
- [EasyPrivacy](https://easylist.to/pages/licence.html): selected collection endpoints, under this project’s selected CC BY-SA 3.0 data license.
- [Public Suffix List](https://publicsuffix.org/list/): MPL 2.0, with the original license header retained.

Rule packages use Ed25519 verification and bounds on size, domain syntax, entry counts, versions and validity. **This version distributes security rules through app updates; it has no online security feed.** The advertising filter’s automatic update switch applies to EasyList/EasyPrivacy. An expired bundled package remains active with an update notice. Signatures do not establish the current maliciousness of every upstream host or replace maintenance and false-positive handling.

## Limits

Structure checks start after loading begins. They cannot guarantee zero earlier requests or exfiltration, and forms introduced after the one-minute observation period are outside that window. Unknown fetch, XHR and WebSocket exfiltration, per-script CPU use and arbitrary HTTPS response bodies are not comprehensively inspected.

Strict fingerprint limits wrap page APIs. Workers, OffscreenCanvas, cached functions or restored originals can bypass them. Default WebKit privacy remains available, but a public toggle does not reproduce all Safari advanced fingerprint protections. V8 bytecode instrumentation and full DNS/CNAME checks are not ported.

Simulator checks establish navigation, resource blocking and UI behavior. They do not establish physical-device MTE, power consumption, real-world detection accuracy or release eligibility.
