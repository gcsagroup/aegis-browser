# Documentation

**English** | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

This directory contains the public product architecture, roadmap, research boundaries, product page, and dated local audit records for GCSA-aegis.

> **Current boundary — 2026-08-28:** source integration is synchronized to 56 top-level Chromium patches plus 2 nested V8 patches. The latest identity-bound build-tree manifest covers only 54 top-level patches plus the 2 V8 patches. The project remains release No-Go.

## Start here

- [Project overview](../README.md)
- [Architecture](architecture.md)
- [Roadmap and release gates](roadmap.md)
- [Research-to-implementation map](research-map.md)
- [Changelog](../CHANGELOG.md)
- [Trilingual product page](product.html)
- [Browser build and verification guide](../apps/browser/README.md)

## Status language

- **In source:** code or a patch exists; this is not build or runtime proof.
- **Source synchronized:** the repository overlay and patch stack match the external Chromium checkout.
- **Locally validated:** the named source, artifact, test, and runtime scope passed a recorded local gate.
- **Release-qualified:** identity, trust, signing, installation, platform, privacy, and distribution gates all passed for the same artifact. GCSA-aegis has not reached this state.

Do not add results from different patch heads. A historical App, APK, test count, or hash proves only the snapshot named by its record.

## Dated plans and audits

Files whose names include a date are evidence snapshots, plans, or implementation records. Their use of “current” refers to that record's date, not necessarily to the current repository head. Use [Roadmap](roadmap.md) for the current public status, and preserve the dated files as historical evidence rather than silently rewriting their measurements.

## Language convention

- English is the unsuffixed primary file shown by GitHub.
- Simplified Chinese uses `.zh-CN.md`.
- Traditional Chinese uses `.zh-TW.md`.
- Each public document begins with links to all three versions.
- Version numbers, dates, identifiers, hashes, commands, and evidence boundaries must remain equivalent across translations.

`product.html` is intentionally a single file with English, Simplified Chinese, and Traditional Chinese switching built in.

## Source synchronization is not a release

The 2026-08-28 authorization permits SSH source synchronization to `git@github.com:gcsagroup/aegis-browser.git`. It does not authorize tags, GitHub Releases, binaries, packages, signing or notarization actions, Play uploads, or production deployment.
