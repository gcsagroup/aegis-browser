# Third-party notices

Thanks to the projects below. This list covers direct dependencies and selected
development tools; not all are included in browser builds.
Aegis-authored source uses [Apache-2.0](LICENSE), unless otherwise noted.
Third-party components retain their own licenses and notices.

## Browser components

- **Chromium 155.0.8059.80** ([license](https://chromium.googlesource.com/chromium/src/+/43a195105613ac83c21d3f14de279f4a045c7da0/LICENSE)): preserve source notices and generated `chrome://credits` in distributions. See the pinned [credits generator](https://chromium.googlesource.com/chromium/src/+/43a195105613ac83c21d3f14de279f4a045c7da0/tools/licenses/licenses.py). Current source pins are [CHROMIUM_VERSION](apps/browser/CHROMIUM_VERSION) and [CHROMIUM_COMMIT](apps/browser/CHROMIUM_COMMIT); historical packages retain their own versions.
- **libtorrent-rasterbar 2.1.1** (optional, [BSD-3-Clause](apps/browser/overlay/third_party/aegis_libtorrent/LICENSE)): [pin and provenance](apps/browser/overlay/third_party/aegis_libtorrent/README.aegis); mirror provenance remains release-pending.
  Its compiled bundled components retain their own notices:
  [try_signal](apps/browser/overlay/third_party/aegis_libtorrent/TRY_SIGNAL_LICENSE.txt)
  and [ed25519](apps/browser/overlay/third_party/aegis_libtorrent/ED25519_LICENSE.txt),
  imported from the same pinned source archive.
  [The archive's complete LICENSE](apps/browser/overlay/third_party/aegis_libtorrent/UPSTREAM_LICENSE.txt)
  also preserves its macOS routing-header notices. [APSL terms](apps/browser/overlay/third_party/aegis_libtorrent/APSL-2.0.txt)
  and the [corresponding source availability notice](apps/browser/overlay/third_party/aegis_libtorrent/SOURCE_OFFER.txt)
  accompany the Mac App; its unmodified routing header is bundled as a separate resource.
- **Boost headers** used by the macOS torrent integration: [Boost Software License 1.0](apps/browser/overlay/third_party/aegis_libtorrent/BOOST_LICENSE_1_0.txt). The build still uses host-provided headers; a license notice does not establish a reproducible dependency version.

The macOS packager installs [Aegis's additional notices](apps/browser/MACOS_THIRD_PARTY_NOTICES.txt)
inside `Contents/Resources/AegisThirdPartyNotices.txt` before signing the staged copy.
The Chromium metadata in `third_party/aegis_libtorrent` and
`third_party/aegis_webui_licenses` makes these dependencies discoverable by the
credits generator on applicable platforms. Source metadata is not proof that a
particular rebuilt binary contains the generated credits.

## iOS bundled resources and SDKs

The iOS app uses system WebKit rather than the bundled desktop Chromium engine.
Its [offline acknowledgements](apps/ios/AegisApp/ThirdPartyNotices.txt) preserve
the five Web enhancement libraries' full licenses, filter-list attributions,
NoCoin's MIT notice, and the Public Suffix List's MPL-2.0 source notice and license.
Settings → About → Open Source Licenses & Acknowledgements opens this resource.

The pinned Block List Project phishing file declares MIT, while the repository
LICENSE at that same commit is the Unlicense. The [combined notice](apps/ios/BrowserKit/Resources/phishing-LICENSE.txt)
retains attribution, the file header, MIT terms and the original repository
license. It does not infer an upstream dual-license grant. The source hash,
revision and conversion provenance are in [security-rules-sources.json](apps/ios/BrowserKit/Resources/security-rules-sources.json).

The current source also resolves Firebase 13.1.1 and its SDK dependency graph.
The [SDK license inventory](scripts/licenses/sdk-licenses/manifest.json) retains
the repository license at each exact Swift Package revision, including optional
packages; resolution is not proof that every package is linked. These are not
uniformly open-source runtime licenses: Google Analytics is not open source,
and precompiled SDK binaries retain the applicable Google SDK/service terms.
See [Firebase's upstream explanation](https://github.com/firebase/firebase-ios-sdk/blob/dc6dfd442b1f3ec215ed62b8beb2623ffab010d6/README.md#L59-L61).
Component-specific notices are retained as well, including
[Crashlytics' bundled libunwind copyright and MIT terms](scripts/licenses/sdk-licenses/firebase-crashlytics.txt).

`python3 -B scripts/licenses/third_party_notices.py check` rejects stale generated
notices or changed SDK pins. The iOS export verifier requires the notices and
license resources inside the actual IPA. Existing released packages are immutable;
these source changes reach users through a subsequent app update. See the
[package audit and remaining gates](docs/audit/third-party-license-packaging-2026-11-03.zh-CN.md).

## Direct workspace dependencies

Development dependencies from the [root](package.json) and
[core](packages/core/package.json) manifests, pinned in [pnpm-lock.yaml](pnpm-lock.yaml).

| Project | Version | License |
| --- | --- | --- |
| [TypeScript](https://github.com/microsoft/TypeScript) | 5.9.3 | Apache-2.0 |
| [DefinitelyTyped / @types/node](https://github.com/DefinitelyTyped/DefinitelyTyped) | 26.2.0 | MIT |
| [tsup](https://github.com/egoist/tsup) | 8.5.1 | MIT |
| [ESLint and @eslint/js](https://github.com/eslint/eslint) | 9.39.3 each | MIT |
| [typescript-eslint](https://github.com/typescript-eslint/typescript-eslint) | 8.72.1 | MIT |
| [Vitest and @vitest/coverage-v8](https://github.com/vitest-dev/vitest) | 3.2.7 each | MIT |
| [c8](https://github.com/bcoe/c8) | 12.0.0 | ISC |
| [jsdom](https://github.com/jsdom/jsdom) | 30.1.3 | MIT |
| [yaml](https://github.com/eemeli/yaml) | 2.9.1 | ISC |

## Optional experimental components

[browser-agent-v2](prototypes/browser-agent-v2/README.md) prototype dependencies,
separate from production browser payloads. npm pins:
[manifest](prototypes/browser-agent-v2/package.json), [lockfile](prototypes/browser-agent-v2/package-lock.json).

| Project | Version / source | License |
| --- | --- | --- |
| [Stagehand](https://github.com/browserbase/stagehand) | 4.0.2 | MIT; `package/LICENSE` in the [published package](https://registry.npmjs.org/@browserbasehq/stagehand/-/stagehand-4.0.2.tgz) |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | 0.0.79 | [Apache-2.0](https://github.com/microsoft/playwright-mcp/blob/v0.0.79/LICENSE) |
| [Zod](https://github.com/colinhacks/zod) | 4.4.3 | [MIT](https://github.com/colinhacks/zod/blob/v4.4.3/LICENSE) |
| [browser-use](https://github.com/browser-use/browser-use) | 0.13.8, [requirements](prototypes/browser-agent-v2/requirements-browser-use.txt) | [MIT](https://github.com/browser-use/browser-use/blob/0.13.8/LICENSE) |
| [MLX LM](https://github.com/ml-explore/mlx-lm) | 0.31.3, [requirements](prototypes/browser-agent-v2/requirements-mlx.txt) | [MIT](https://github.com/ml-explore/mlx-lm/blob/v0.31.3/LICENSE) |
| [Skyvern](https://github.com/Skyvern-AI/skyvern) | 1.0.48, [requirements](prototypes/browser-agent-v2/requirements-skyvern.txt) | [AGPL-3.0](https://github.com/Skyvern-AI/skyvern/blob/v1.0.48/LICENSE) |

## Development and CI tools

Pins: [.mise.toml](.mise.toml), [Quality workflow](.github/workflows/quality.yml)
and linked scripts.

| Project | Version / source | License |
| --- | --- | --- |
| [Node.js](https://nodejs.org/) | 22.23.1 | [MIT, with bundled notices](https://github.com/nodejs/node/blob/v22.23.1/LICENSE) |
| [pnpm](https://pnpm.io/) | 9.15.0 | [MIT](https://github.com/pnpm/pnpm/blob/v9.15.0/LICENSE) |
| [CPython](https://www.python.org/) | 3.11.9 | [PSF license and included notices](https://github.com/python/cpython/blob/v3.11.9/LICENSE) |
| [coverage.py](https://github.com/nedbat/coveragepy) | 7.16.1, [requirements](scripts/ci/python-coverage-requirements.txt) | [Apache-2.0](https://github.com/nedbat/coveragepy/blob/7.16.1/LICENSE.txt) |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | 15.2.0, [installer](scripts/ci/install-ripgrep.sh) | [MIT OR Unlicense](https://github.com/BurntSushi/ripgrep/blob/15.2.0/COPYING) |
| [kcov](https://github.com/SimonKagstrom/kcov) | v43, [runner](scripts/ci/run-shell-coverage.sh) | [GPLv2 text](https://github.com/SimonKagstrom/kcov/blob/a39874f938ce13f7a65f253120d1ec946b349ffe/COPYING); retain source-file notices |
| [Pester](https://pester.dev/) | 5.7.1 | [Apache-2.0](https://github.com/pester/Pester/blob/5.7.1/LICENSE) |
| [JaCoCo](https://www.jacoco.org/) | 0.8.14, [Android helper](apps/browser/scripts/android-ui-driver/README.md) | [EPL-2.0](https://github.com/jacoco/jacoco/blob/v0.8.14/LICENSE.md) |

Host toolchains carry their own notices. Preserve each filter list and threat
feed's attribution and terms when synchronizing or distributing its data.
