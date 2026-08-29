[English](./tree-layout.md) | [**简体中文**](./tree-layout.zh-CN.md) | [繁體中文](./tree-layout.zh-TW.md)

# 预期新增的 Chromium 目录

以下路径是 GCSA-aegis 补丁的落点；补丁落地前，这些路径并不存在：

```text
src/chrome/browser/aegis/
  aegis_service.h
  aegis_service.cc
  aegis_prefs.cc          # 规划中

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
  generated/*.inc           # 由 packages/core 通过 sync-core-snapshot.sh 生成
  aegis_net_throttle.*

src/third_party/aegis_policy/
  policy_snapshot.json      # packages/core 的可移植 JSON 导出
  BUILD.gn                  # 复制到 out/aegis_policy/
```

修改 `packages/core` 后重新生成规则：

```bash
pnpm --filter @gcsa-aegis/browser sync-core-snapshot
```

构建接线：

- `chrome/browser/BUILD.gn` — 依赖 `//chrome/browser/aegis`
- `chrome/browser/about_flags.cc` — 启用开关
- `chrome/common/chrome_features.cc` — `kAegisEnabled`
