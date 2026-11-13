# Embedded Access core (K0 / K1)

Pinned upstream sources and a verified local xcframework build for the in-process
thin bridge (`StartInstance` / `Dial`). Stock LibXray `Invoke` / `RunXray` is
**not** the product ABI.

- Xray-core: `v26.11.9` / `676eaf66f8f05d4d558ee7a74b4736623d3feeb9`
- libXray: `v26.11.9` / `5a0f7d8d1c28b34afb5727b04b26a10f6dbac7e3` (license / source reference only)
- Bridge: `apps/ios/EmbeddedCore/bridge` → `AegisEmbeddedCore.xcframework`

`embedded-core-lock.json` status is `verified_build` with both iOS slice digests.
`AccessGoEmbeddedCore` wraps the linked module. The product publisher
(`AccessEmbeddedProxyEntryFactory`) stays fail-closed until the lock may link,
the framework is linked, **and** a supported Reality Vision config is present. Dev builds read a local path from
`AEGIS_ACCESS_LOCAL_V2RAY_CONFIG` in the app process. Internal Alpha and Beta
builds can use the app resource described below.

## Build / package

```bash
AEGIS_EMBEDDED_CORE_DIGEST_MODE=ci-rebuild \
  scripts/release/prepare-ios-access-core.sh \
    apps/ios/EmbeddedCore/embedded-core-lock.json .artifacts/ios-embedded-core
```

Preparation builds the pinned bridge in a copy, checks the binding tool pin, and
leaves the tracked lock unchanged. The output contains the XCFramework, measured
slice digests, an effective `embedded-core-lock.json`, a build manifest and Xcode's
input file list. `ci-rebuild` records the actual source-pinned rebuild; the default
`strict` mode additionally requires the frozen slice digests to match. Neither mode
establishes a reproducible binary across different Xcode/SDK versions.

The Xcode project defaults to `.artifacts/ios-embedded-core`. For a separate build
directory, pass `AEGIS_EMBEDDED_CORE_PRODUCTS=/absolute/build/directory` to
`xcodebuild`. The sandboxed AccessKit build phase verifies those inputs and installs
the effective lock and build manifest in the framework bundle. Unsigned CI uses its
admitted job directory, preserves the archive and manifests, and rechecks the clean
checkout, actual framework inputs and bundled manifests before sealing the archive.

The opt-in K gate accepts `--products /absolute/build/directory`. It verifies the
actual slices before linking, requires all three live test leaf identifiers to pass,
and checks the same link evidence as the unsigned archive. For each architecture
it verifies the app's load command (including the Debug dylib), the selected
static archive against the linker's input, the Go table and bridge exports in
AccessKit, and the bundled carrier's UUID and sections against the linker output.
The receipt records the binary hashes for the loader and carrier. A missing, failed or
skipped required leaf cannot produce PASS. Use a new output directory for each run;
node credentials never belong in the receipt or repository.

## Internal Dev and Alpha test node

The private signing repository owns the GitHub Environment secret
`AEGIS_ACCESS_TEST_NODE_URI` (one complete VLESS Reality Vision share URI).
Expose it only in the private internal archive step. With the locked framework
prepared, call the wrapper from that step, selecting `dev` or `alpha`:

```bash
bash scripts/release/ios-private-test-node-archive.sh alpha \
  MARKETING_VERSION=0.8.0 CURRENT_PROJECT_VERSION=1
```

The wrapper accepts additional Xcode settings such as the private job's signing
team. It writes the URI to a temporary file outside the checkout, removes the URI
from Xcode's environment, and prints the private archive path. The input file
and DerivedData are removed on exit. Anyone with the resulting app can extract
the URI. Keep the archive, exported apps, and access to them private.

The shared test node is configured on the server for a 10 GB daily allowance
(10,000,000,000 bytes), covering upload and download combined. The panel owns
the reset schedule; the app displays the service's actual counters and quota.
It is separate from commercial account entitlements. Public PR, signing, and
release workflows do not need this secret. Ordinary builds omit the node.
Beta, release, and unrecognized channels remove the resource on a reused build
directory and ignore it at runtime, including environment overrides. Dev may
explicitly override the bundled node with its local development config path.

## Toolchain (historical verified local attempt)

- Go: `1.27.3`
- gomobile / gobind: `golang.org/x/mobile@v0.0.0-20261011034528-197770444867`
- Artifact: `apps/ios/EmbeddedCore/Products/AegisEmbeddedCore.xcframework`

Slice digests (thin bridge):

- ios-arm64: `4d23ef190459a63963a1df0beb2296cc3c9cd6614e701529c2105f624621e6d4`
- ios-arm64-simulator: `9264f94db8724dab5988d216497f695d0a45f78103f6418ee84a4b86a4207c93`

License texts for these upstream projects are listed in iOS
「开源许可与鸣谢」 via `scripts/licenses/access-core/`.
