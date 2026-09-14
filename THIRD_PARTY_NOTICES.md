# Third-party notices

Source authored for GCSA-aegis is licensed under Apache-2.0 as stated in
[`LICENSE`](LICENSE), unless a file or dependency states another license.

The browser product is based on Chromium `151.0.7922.77` at commit
`ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`. Chromium and the third-party
components distributed with Chromium retain their own BSD-style and other
licenses. A complete Chromium source checkout and binary distribution must
preserve Chromium's generated credits and license notices; the repository's
Apache-2.0 license does not replace them.

The optional libtorrent integration pins libtorrent-rasterbar `2.1.1`, licensed
under BSD-3-Clause. See
[`apps/browser/overlay/third_party/aegis_libtorrent/LICENSE`](apps/browser/overlay/third_party/aegis_libtorrent/LICENSE)
and its [pin and provenance record](apps/browser/overlay/third_party/aegis_libtorrent/README.aegis).
The recorded mirror is still release-pending provenance and is not represented
as a production-qualified distribution source.

Development and CI dependencies retain the licenses declared by their upstream
packages. The quality gate records the license metadata for the newly pinned
analysis and coverage tools. That inventory is evidence of metadata collection,
not a complete SBOM or legal compatibility opinion.
