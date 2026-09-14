# Third-party notices and acknowledgements

Thank you to the maintainers, contributors, and communities behind the projects
below. Their browser foundations, libraries, and tools make Aegis possible.
This inventory covers declared direct dependencies and selected development
tools; inclusion does not mean a component ships in every browser build.

Source authored for GCSA-aegis is licensed under Apache-2.0 as stated in
[`LICENSE`](LICENSE), unless a file or dependency states another license.

The browser product is based on Chromium `151.0.7922.77` at commit
`ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`. Chromium and the third-party
components distributed with Chromium retain their own BSD-style and other
licenses. A complete Chromium source checkout and binary distribution must
preserve Chromium's generated credits and license notices; the repository's
Apache-2.0 license does not replace them.

See Chromium's pinned [license](https://chromium.googlesource.com/chromium/src/+/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/LICENSE)
and [credits generator](https://chromium.googlesource.com/chromium/src/+/ff37cfca210138f2a40b843b4a8195ab7e4fc7ff/tools/licenses/licenses.py).
Its transitive components retain their source notices and generated
`chrome://credits`; this list does not replace that mechanism.

The optional libtorrent integration pins libtorrent-rasterbar `2.1.1`, licensed
under BSD-3-Clause. See
[`apps/browser/overlay/third_party/aegis_libtorrent/LICENSE`](apps/browser/overlay/third_party/aegis_libtorrent/LICENSE)
and its [pin and provenance record](apps/browser/overlay/third_party/aegis_libtorrent/README.aegis).
The recorded mirror is still release-pending provenance and is not represented
as a production-qualified distribution source.

## Direct workspace dependencies

Versions are resolved by [pnpm-lock.yaml](pnpm-lock.yaml), from the root
[manifest](package.json) and [core manifest](packages/core/package.json).
The browser workspace's core dependency is internal Aegis code. These external
packages are declared as development dependencies; TypeScript is also imported
by the AST and structure-analysis code used to generate analysis tooling.
License names were checked against the installed packages' `LICENSE*` files.

| Project | Locked version | Use | License |
| --- | --- | --- | --- |
| [TypeScript](https://github.com/microsoft/TypeScript) | 5.9.3 | Types, compilation, AST and structure analysis | Apache-2.0 |
| [DefinitelyTyped / @types/node](https://github.com/DefinitelyTyped/DefinitelyTyped) | 26.2.0 | Node.js type definitions | MIT |
| [tsup](https://github.com/egoist/tsup) | 8.5.1 | Core and analysis bundles | MIT |
| [ESLint and @eslint/js](https://github.com/eslint/eslint) | 9.39.3 each | JavaScript linting and recommended rules | MIT |
| [typescript-eslint](https://github.com/typescript-eslint/typescript-eslint) | 8.70.0 | TypeScript linting | MIT |
| [Vitest and @vitest/coverage-v8](https://github.com/vitest-dev/vitest) | 3.2.7 each | Core tests and V8 coverage | MIT |
| [c8](https://github.com/bcoe/c8) | 12.0.0 | Node tooling coverage | ISC |
| [jsdom](https://github.com/jsdom/jsdom) | 26.1.0 | DOM-based UI tests | MIT |
| [yaml](https://github.com/eemeli/yaml) | 2.8.1 | Workflow YAML parsing | ISC |

## Optional experimental components

The isolated [browser-agent-v2 prototype](prototypes/browser-agent-v2/README.md)
has its own [npm manifest](prototypes/browser-agent-v2/package.json) and
[lockfile](prototypes/browser-agent-v2/package-lock.json). Its three direct npm
dependencies and separately declared Python experiments are acknowledged here;
they are not a list of production browser payloads.

| Project | Declared version / source | Experimental use | License evidence |
| --- | --- | --- | --- |
| [Stagehand](https://github.com/browserbase/stagehand) | 4.0.2, npm lock | Browser agents | MIT; `package/LICENSE` in the [published package](https://registry.npmjs.org/@browserbasehq/stagehand/-/stagehand-4.0.2.tgz) |
| [Playwright MCP](https://github.com/microsoft/playwright-mcp) | 0.0.79, npm lock | Browser automation protocol | [Apache-2.0](https://github.com/microsoft/playwright-mcp/blob/v0.0.79/LICENSE) |
| [Zod](https://github.com/colinhacks/zod) | 4.4.3, npm lock | Schema validation | [MIT](https://github.com/colinhacks/zod/blob/v4.4.3/LICENSE) |
| [browser-use](https://github.com/browser-use/browser-use) | 0.13.8, [requirements](prototypes/browser-agent-v2/requirements-browser-use.txt) | Python browser agent | [MIT](https://github.com/browser-use/browser-use/blob/0.13.8/LICENSE) |
| [MLX LM](https://github.com/ml-explore/mlx-lm) | 0.31.3, [requirements](prototypes/browser-agent-v2/requirements-mlx.txt) | Local model provider | [MIT](https://github.com/ml-explore/mlx-lm/blob/v0.31.3/LICENSE) |
| [Skyvern](https://github.com/Skyvern-AI/skyvern) | 1.0.48, [requirements](prototypes/browser-agent-v2/requirements-skyvern.txt) | Isolated CLI/agent | [AGPL-3.0](https://github.com/Skyvern-AI/skyvern/blob/v1.0.48/LICENSE) |

The [prototype record](prototypes/browser-agent-v2/prototype-lock.json) also
records MCP SDK 1.30.0 and BrowserGym 0.14.3 as candidates, and a pinned
`mlx-community/Qwen3-1.7B-4bit` model revision. Candidate records and model
weights are distinct from the direct software dependencies above; they do not
establish installation or product inclusion. Planned Xray/REALITY integrations
are likewise not represented here as bundled libraries.

## Development and CI tools

We also thank the projects supporting repository validation. Pins live in
[.mise.toml](.mise.toml), the [Quality workflow](.github/workflows/quality.yml),
and the linked scripts. These are tooling acknowledgements, not browser runtime
dependencies.

| Project | Version / source | Use | License |
| --- | --- | --- | --- |
| [Node.js](https://nodejs.org/) | 22.23.1 | JavaScript tooling and tests | [MIT, with bundled notices](https://github.com/nodejs/node/blob/v22.23.1/LICENSE) |
| [pnpm](https://pnpm.io/) | 9.15.0 | Dependency installation | [MIT](https://github.com/pnpm/pnpm/blob/v9.15.0/LICENSE) |
| [CPython](https://www.python.org/) | 3.11.9 | Python scripts and tests | [PSF license and included notices](https://github.com/python/cpython/blob/v3.11.9/LICENSE) |
| [coverage.py](https://github.com/nedbat/coveragepy) | 7.16.1, [requirements](scripts/ci/python-coverage-requirements.txt) | Python coverage | [Apache-2.0](https://github.com/nedbat/coveragepy/blob/7.16.1/LICENSE.txt) |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | 15.2.0, [installer](scripts/ci/install-ripgrep.sh) | CI repository searches | [MIT OR Unlicense](https://github.com/BurntSushi/ripgrep/blob/15.2.0/COPYING) |
| [kcov](https://github.com/SimonKagstrom/kcov) | v43 at `a39874f938ce13f7a65f253120d1ec946b349ffe`, [runner](scripts/ci/run-shell-coverage.sh) | Linux Bash coverage | [GPLv2 text](https://github.com/SimonKagstrom/kcov/blob/a39874f938ce13f7a65f253120d1ec946b349ffe/COPYING); retain source-file notices |
| [Pester](https://pester.dev/) | 5.7.1, Quality workflow | Windows PowerShell coverage | [Apache-2.0](https://github.com/pester/Pester/blob/5.7.1/LICENSE) |
| [JaCoCo](https://www.jacoco.org/) | 0.8.14, [Android helper documentation](apps/browser/scripts/android-ui-driver/README.md) | Separate Android Java helper coverage | [EPL-2.0](https://github.com/jacoco/jacoco/blob/v0.8.14/LICENSE.md) |

Host-provided Git, Bash, Clang/LLVM and the Java toolchain are also used by the
scripts. Their exact versions and bundled notices belong to the selected
host/toolchain distribution; the Quality report records the versions it probes,
and the Android workflow selects Temurin Java 21. This is not a complete
inventory of runner images or toolchain transitive dependencies.

Filter lists and threat feeds are data, not software libraries. Importing an
EasyList-compatible file does not establish its provenance or license; preserve
the selected feed's attribution and terms when synchronizing or distributing
data. Proprietary platform SDKs are not listed as open-source libraries.

Development and CI dependencies retain the licenses declared by their upstream
packages. The quality gate records the license metadata for the newly pinned
analysis and coverage tools. That inventory is evidence of metadata collection,
not a complete SBOM or legal compatibility opinion.
