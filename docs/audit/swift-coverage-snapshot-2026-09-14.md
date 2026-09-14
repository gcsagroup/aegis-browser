# iOS Swift Simulator test coverage snapshot — 2026-09-14

These badges are manually recorded snapshots from a successful iOS Simulator
test run, not automatically updated coverage for the current `main` commit.
They measure the native iOS product's Swift source, not a macOS product or the
Chromium browser. The README's live CI badge separately includes the
mandatory macOS quality job plus Linux Bash and Windows PowerShell coverage;
it does not represent a full macOS Chromium build.

## Recorded evidence

- [iOS Coverage run 34839060677, attempt 1](https://github.com/quinn521/aegis-browser/actions/runs/34839060677): `push`, completed successfully on 2026-09-14.
- Tested SHA: `66ca5eecb0686bc856aa288167c93be1939155f6`; recorded tree state: `clean`.
- [Artifact 10346575425](https://github.com/quinn521/aegis-browser/actions/runs/34839060677/artifacts/10346575425): `swift-coverage-34839060677-1`. The workflow retains artifacts for 14 days; this dated summary remains in Git after the download expires.
- Xcode 26.6, build `17F113`; iOS Simulator runtime `com.apple.CoreSimulator.SimRuntime.iOS-26-5`.
- Devices: Aegis QA iPhone 17 and Aegis QA iPad Air 11-inch (M4).
- `run-metadata.txt` records `iphone_exit=0`, `ipad_exit=0`, and `input_stability_exit=0`.
- Input manifest SHA-256: `21cbfe6d0fea4ba36153d0d223871737541f240acc29c2a0259f90049b91270a`.

| Simulator | Covered / executable lines | Measured line coverage | Generated at (UTC) | Summary SHA-256 |
| --- | --- | --- | --- | --- |
| iPhone | 6759 / 8088 | 83.57% | 2026-09-14 11:50:04.764 | `f5c59c7f68daaa972ca1945cc2a8ad5e3d312625ef43da7e7cf83a5e382ed5b8` |
| iPad | 6874 / 8088 | 84.99% | 2026-09-14 12:02:05.654 | `3b2f74e93ce151f2c0e61f6c53bfa81b285653952f7764d16f7067fe536df5fa` |

The hashes identify `iPhone-swift-coverage.json` and
`iPad-swift-coverage.json` in that artifact. Both summaries were checked against
their raw `iPhone-coverage.json` / `iPad-coverage.json` xccov reports using the
repository's existing summarizer; the line counts reproduced exactly.

## Measurement scope

This is combined unit + UI test coverage. The default Aegis scheme includes
both `AegisTests` and `AegisUITests` in
[project.yml](../../apps/ios/project.yml), and the recorded run used
`test_plan=<scheme-default>`. Both targets contribute to the same xcresult and
xccov report. No independent unit-only percentage or attribution of covered
lines to one test target is available from these summaries.

The [Simulator test runner](../../apps/ios/scripts/run-simulator-tests.sh)
enables code coverage and exports real `xccov` reports. The
[Swift summarizer](../../apps/ios/scripts/summarize-xccov.mjs) inventories product
`.swift` files under `apps/ios`, excluding `Tests`, `.build`, and `DerivedData`
directories and symbolic links. It counts each physical source file once,
selecting the target measurement with the greatest executable-line count, then
covered-line count. Percentages use measured executable lines and are rounded
to two decimal places. The two device results are not added or averaged.

Each device measured all 25 inventoried product Swift files: 23 had covered
lines, two had zero covered lines, and none were unmeasured. The zero-covered
files are `SafariWebExtension/SafariWebExtensionHandler.swift` and
`ShareExtension/ShareViewController.swift`; their executable lines remain in
the denominator. This is line coverage, not branch coverage, real-device
acceptance, UI completeness, signing, or release qualification.

## Refreshing the snapshots

Use a successful existing iOS Coverage run and download its evidence. Verify
the exact tested SHA, clean tree, input stability, both Simulator results,
summary hashes, and raw xccov counts before updating this record and both SVGs
in a reviewed commit. Keep the SVG titles and this audit record's date and SHA synchronized. If an artifact
has expired, obtain a new successful run rather than treating an older badge
as current evidence. No external badge service, secret, or automated repository
write permission is required.
