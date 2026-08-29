[**English**](./tree-layout.md) | [简体中文](./tree-layout.zh-CN.md) | [繁體中文](./tree-layout.zh-TW.md)

# Intended Chromium tree additions

These paths are the landing zone for GCSA-aegis patches (not present until patches land):

```text
src/chrome/browser/aegis/
  aegis_service.h
  aegis_service.cc
  aegis_prefs.cc          # planned

src/chrome/browser/ui/webui/aegis/
  aegis_ui.cc
  aegis_ui.h
  resources/

src/chrome/common/aegis/
  features.h
  features.cc
  builtin_tracker_hosts.*   # includes generated/tracker_hosts.inc
  builtin_phish_hosts.*
  tracking_query_params.*
  generated/*.inc           # from packages/core via sync-core-snapshot.sh
  aegis_net_throttle.*

src/third_party/aegis_policy/
  policy_snapshot.json      # portable JSON export of packages/core
  BUILD.gn                  # copy into out/aegis_policy/
```

Regenerate rules after editing `packages/core`:

```bash
pnpm --filter @gcsa-aegis/browser sync-core-snapshot
```

Build wiring:

- `chrome/browser/BUILD.gn` — deps on `//chrome/browser/aegis`
- `chrome/browser/about_flags.cc` — enable flag
- `chrome/common/chrome_features.cc` — `kAegisEnabled`
