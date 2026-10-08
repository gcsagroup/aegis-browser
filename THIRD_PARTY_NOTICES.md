# Third-party notices

Thanks to the projects below. This list covers direct dependencies and selected
development tools; not all are included in browser builds.
Aegis-authored source uses [Apache-2.0](LICENSE), unless otherwise noted.
Third-party components retain their own licenses and notices.

## Browser components

- **Chromium 151.0.7922.77** ([license](https://chromium.googlesource.com/chromium/src/+/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/LICENSE)): preserve source notices and generated `chrome://credits` in distributions. See the pinned [credits generator](https://chromium.googlesource.com/chromium/src/+/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/tools/licenses/licenses.py).
- **libtorrent-rasterbar 2.1.1** (optional, [BSD-3-Clause](apps/browser/overlay/third_party/aegis_libtorrent/LICENSE)): [pin and provenance](apps/browser/overlay/third_party/aegis_libtorrent/README.aegis); mirror provenance remains release-pending.

## Direct workspace dependencies

Development dependencies from the [root](package.json) and
[core](packages/core/package.json) manifests, pinned in [pnpm-lock.yaml](pnpm-lock.yaml).

| Project | Version | License |
| --- | --- | --- |
| [TypeScript](https://github.com/microsoft/TypeScript) | 5.9.3 | Apache-2.0 |
| [DefinitelyTyped / @types/node](https://github.com/DefinitelyTyped/DefinitelyTyped) | 26.2.0 | MIT |
| [tsup](https://github.com/egoist/tsup) | 8.5.1 | MIT |
| [ESLint and @eslint/js](https://github.com/eslint/eslint) | 9.39.3 each | MIT |
| [typescript-eslint](https://github.com/typescript-eslint/typescript-eslint) | 8.70.0 | MIT |
| [Vitest and @vitest/coverage-v8](https://github.com/vitest-dev/vitest) | 3.2.7 each | MIT |
| [c8](https://github.com/bcoe/c8) | 12.0.0 | ISC |
| [jsdom](https://github.com/jsdom/jsdom) | 26.1.0 | MIT |
| [yaml](https://github.com/eemeli/yaml) | 2.8.1 | ISC |

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
