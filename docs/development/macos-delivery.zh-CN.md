# Fork 打包签名与 Access 测试

#97 的 Access 闭环在 fork 分支 `promote/ios-access-closed-loop-2cd7`（`quinn521/aegis-browser`）上。fork `develop` 也有 AccessKit。上游 `main` 还没有。

上游 iOS Delivery 仍然只允许 `gcsagroup/aegis-browser` 做 App Store 打包上传。旧的 `AEGIS_IOS_FORK_REHEARSAL` 不能重新打开这条特权路径。

fork 上恢复的是测试用打包签名：

| 工作流 | 作用 |
| --- | --- |
| `macos-delivery.yml` | 在 self-hosted Mac 上跑 Access 测试；需要时用 `temporary-ad-hoc` 或 Developer ID 签出现有 `.app` 的 DMG，不公证 |
| `ios-fork-access.yml` | 在 fork 已有的 `AEGIS_IOS_RUNNER_LABEL`（当前 `aegis-ios-fork-migration`）上跑 AccessKit 模拟器测试。`Alpha package` 打 0.8.0 alpha 自测包，不导入 Distribution 证书，不上传，不提审 |

macOS 沿用 fork 变量 `AEGIS_MACOS_BRANCH_REHEARSAL=true` 和 `AEGIS_MACOS_REHEARSAL_SIGNING_MODE=temporary-ad-hoc`。Runner 优先 `AEGIS_MACOS_RUNNER_LABEL`，否则用现有 iOS self-hosted 标签，不改成 `macos-26`。

# macOS Delivery（前期，不公证）

手动工作流：`.github/workflows/macos-delivery.yml`。

先在 fork `quinn521/aegis-browser` 上使用。上游仓库也可以手动触发。不会改 iOS 工作流的 Runner。

## 执行环境

打包和 Access 测试都跑在现有 self-hosted Mac 上：

`["self-hosted", "macOS", "ARM64", <label>]`

`<label>` 优先用仓库变量 `AEGIS_MACOS_RUNNER_LABEL`。未设置时沿用已经在跑 iOS 的 `AEGIS_IOS_RUNNER_LABEL`。不会退回 `macos-26`。

## 操作

| 操作 | 行为 |
| --- | --- |
| Access tests | 在这台 Mac 上跑 Access 证据校验和 `test-aegis-access-native.sh` |
| Package DMG | 先跑上述测试，再对 runner 上已有的 `.app` 做 ad-hoc 或 Developer ID 签名并生成 DMG |
| Internal DMG | 先跑 Access 测试，再在已知 Mac 构建目录里找带 `Contents/MacOS` 的 `.app`，打未公证的 0.8.0 DMG。找不到就不做假包 |
| Rebuild DMG | 在这台 Mac 上找到 Mac 用的 Chromium 源码，用 `aegis-release.gn` 重新编译 `GCSA Aegis.app`，再 ad-hoc 签名打 DMG。只有 Android 检出、或没有源码时，不下载、不做假包 |

0.8.0 只打 alpha，给开发自测。不上传，不提审。列车关闭只挡住送审，不挡住这个 alpha 包。

## 当前 self-host

fork 的开发和内测都走 `quinn-local-aegis-test-01` / `02`（标签 `aegis-test`、`aegis-ios-fork-migration`）。`main`/`develop` 上的 `quality`、C++ 和 iOS archive 本来就会被 `/Users/quinn/actions-runner-aegis/hooks/job-started.py` 放行。

同一份 hook 现在也放行本仓库的内测工作流 `ios-fork-access.yml`、`macos-delivery.yml`，分支包括 `main`、`develop` 和 `promote/ios-access-closed-loop-2cd7`。商店上传作业仍然只允许 `main`/`develop` 和既有 candidate tag。外部 fork PR 继续拒绝。源码副本在 `scripts/ci/self-host-job-started.py`，生效的是 Mac 上的那份。

`.app` 必须是 `AEGIS_MACOS_APP_ROOT` 下的真实目录。前期不调用 `notarytool`，回执里 `notarized` 固定为 `false`。Gatekeeper 仍可能拒绝未公证的磁盘映像。

Developer ID 使用仓库 secret `AEGIS_MACOS_DEVELOPER_ID_P12_BASE64` 和 `AEGIS_MACOS_DEVELOPER_ID_P12_PASSWORD`。证书只进本次作业的临时钥匙串，不替换登录钥匙串搜索列表。

这不是发行资格，也不代替产品阶段一的五步证据。

当前交付 runner 与 `aegis-release.gn` 只支持 arm64；工作流、计划入口和手动包装脚本会在查找源码或开始重建前拒绝 x64。现有 `.app` 必须有已经 finalize 的构建身份，产品 SHA、补丁 lineage、overlay、GN 和产物复查均须通过；回执分别记录实际产品 SHA 与包装 workflow SHA。

`Package DMG` / `Internal DMG` 的 `product_checkout` 和 `product_sha` 可绑定与包装脚本不同的既有产品工作树及完整 SHA；留空时使用当前 workflow 工作树和 SHA。该工作树必须干净并处于指定 SHA，校验器从该工作树运行，Chromium 源码则绑定到所选 App 的 `src/out/AegisRelease`，不沿用包装 shell 的另一棵源码树。对应命令行参数为 `MACOS_PRODUCT_CHECKOUT` / `MACOS_EXPECTED_SOURCE_SHA`。`Rebuild DMG` 使用 workflow 工作树，通过现有 canonical builder 持有同一原子锁，覆盖 GN、构建、身份 finalize 及打包。

本轮只完成源码与离线回归；没有部署 host hook、调度重建、签名或生成 DMG，实际操作的应用身份与回执仍须单列验收。
