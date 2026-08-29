[English](./tree-layout.md) | [简体中文](./tree-layout.zh-CN.md) | [**繁體中文**](./tree-layout.zh-TW.md)

# 預期新增的 Chromium 目錄

以下路徑是 GCSA-aegis 補丁的落點；補丁落地前，這些路徑並不存在：

```text
src/chrome/browser/aegis/
  aegis_service.h
  aegis_service.cc
  aegis_prefs.cc          # 規劃中

src/chrome/browser/ui/webui/aegis/
  aegis_ui.cc
  aegis_ui.h
  resources/

src/chrome/common/aegis/
  features.h
  features.cc
  builtin_tracker_hosts.*   # 包含 generated/tracker_hosts.inc
  builtin_phish_hosts.*
  tracking_query_params.*
  generated/*.inc           # 由 packages/core 透過 sync-core-snapshot.sh 產生
  aegis_net_throttle.*

src/third_party/aegis_policy/
  policy_snapshot.json      # packages/core 的可攜式 JSON 匯出
  BUILD.gn                  # 複製到 out/aegis_policy/
```

修改 `packages/core` 後重新產生規則：

```bash
pnpm --filter @gcsa-aegis/browser sync-core-snapshot
```

建置接線：

- `chrome/browser/BUILD.gn` — 依賴 `//chrome/browser/aegis`
- `chrome/browser/about_flags.cc` — 啟用開關
- `chrome/common/chrome_features.cc` — `kAegisEnabled`
