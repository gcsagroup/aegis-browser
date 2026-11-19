# Fork 打包签名与 Access 测试

#97 的 Access 闭环在 fork 分支 `promote/ios-access-closed-loop-2cd7`（`quinn521/aegis-browser`）上。fork `develop` 也有 AccessKit。上游 `main` 还没有。

上游 iOS Delivery 仍然只允许 `gcsagroup/aegis-browser` 做 App Store 打包上传。旧的 `AEGIS_IOS_FORK_REHEARSAL` 不能重新打开这条特权路径。

fork 上恢复的是测试用打包签名：

| 工作流 | 作用 |
| --- | --- |
| `macos-delivery-bot.yml` | 先在 fork `main` 上跑完整 DMG 矩阵；上游晋升与同步后置。不上传 Mac App Store |
| `macos-dmg.yml` | Bot 或管理员调度的子运行：`ad-hoc` / `host-signed` / `notarized` 三选一，可选候选 tag |
| `macos-delivery.yml` | 在 self-hosted Mac 上跑 Access 测试；需要时用 `temporary-ad-hoc` 或 Developer ID 签出现有 `.app` 的 DMG。旧的手动入口仍在 |
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

## macOS Delivery · Bot（只打 DMG）

先在 fork `quinn521/aegis-browser` 上把完整矩阵跑通，再做上游 `gcsagroup/aegis-browser` 的晋升与同步。控制流对齐 MacCleaner #71 的 DMG 半边：三种包、候选 tag，以及只有公证候选能升正式版。没有 App Store、TestFlight、Status、Wait，也不做 universal 或 x86_64。Chromium 不能在 GitHub 托管的 macOS runner 上编译，所以打包仍在现有 self-hosted arm64 Mac 上，产物只有 `GCSA-aegis-<version>-mac-arm64.dmg`。

仓库变量 `AEGIS_MACOS_DELIVERY_ENABLED` 必须正好是 `true`。控制器接受 fork 或上游的当前 `main`、第一次运行，发起人必须是该仓库管理员。Delivery Bot 不能自己启动这个控制器。

在 **Actions → macOS Delivery · Bot** 填写版本和 build，例如 `0.8.0` 和 `800001`。

| 操作 | 行为 |
| --- | --- |
| Package | 打一张 DMG。`ad-hoc`、`host-signed`、`notarized` 三种；`unsigned-dmg` 记成 `ad-hoc`，`none` 也记成 `ad-hoc`。签名方式必须和包种类一致。fork 上先把这三种都跑通 |
| Tag release | 同样打包，再由子运行发布预发布 tag `candidate/macos/<version>-<kind>.<build>`。不是 Latest。fork 上可先发候选 |
| Promote | **仅上游**。仓库管理员在 Environment `aegis-macos-dmg-stable` 批准后，把一张 **notarized** 候选升成稳定 tag `v<version>`。fork 上不开放 |
| Complete | 只给 Bot 回写收据。人不要选 |

控制器复用 iOS 已有的 `aegis-ios-bot` Environment 和同一套 Delivery App 变量名（`AEGIS_IOS_DELIVERY_BOT`、`AEGIS_IOS_BOT_INSTALLATION_ID`、`AEGIS_IOS_BOT_PRIVATE_KEY`）。fork 上要装同一套 App，并用 fork 自己的 installation id。它先确认当前 `main` 的 quality 与 secret-scanning 已通过，再调度 `macos-dmg.yml`，并等到那次运行结束。调度响应里必须有 `workflow_run_id`；空响应不会重试。控制器传入 `bot_callback=no`。人直接跑 `macos-dmg.yml` 时默认 `bot_callback=yes`。

`host-signed` 和 `notarized` 都走 `macos-developer-id.py`。`notarized` 在 DMG 生成后直接 `notarytool submit --apple-id --team-id --password --wait`，再 `stapler staple`，然后才封 manifest。不执行 `notarytool store-credentials`。密钥是 `AEGIS_MACOS_NOTARY_APPLE_ID`、`AEGIS_MACOS_NOTARY_PASSWORD`，Team ID 用 `AEGIS_APPLE_TEAM_ID`。旧的 `macos-delivery-receipt.json` 仍是 `notarized=false`；包种类以 `macos-delivery-manifest.json` 为准。

稳定发布只在上游，还要 Environment `aegis-macos-dmg-stable`。fork 矩阵未同步前不要 Promote。

人类直接跑原来的 `macos-delivery.yml` 时，把 Bot 的四个字段留空。那条旧工作流仍然不做公证。

源码里的 `scripts/ci/self-host-job-started.py` 已放行 fork 上的 `macos-dmg.yml` 三个 package job。生效的是 Mac 上的 hook 副本；本轮没有部署那份副本，也没有真正编译或公证。

## 当前 self-host

fork 的开发和内测都走 `quinn-local-aegis-test-01` / `02`（标签 `aegis-test`、`aegis-ios-fork-migration`）。`main`/`develop` 上的 `quality`、C++ 和 iOS archive 本来就会被 `/Users/quinn/actions-runner-aegis/hooks/job-started.py` 放行。

同一份 hook 现在也放行本仓库的内测工作流 `ios-fork-access.yml`、`macos-delivery.yml`、`macos-dmg.yml`，分支包括 `main`、`develop` 和 `promote/ios-access-closed-loop-2cd7`。商店上传作业仍然只允许 `main`/`develop` 和既有 candidate tag。外部 fork PR 继续拒绝。源码副本在 `scripts/ci/self-host-job-started.py`，生效的是 Mac 上的那份。

`.app` 必须是 `AEGIS_MACOS_APP_ROOT` 下的真实目录。`macos-delivery.yml` 不调用 `notarytool`，它写出的 `macos-delivery-receipt.json` 里 `notarized` 固定为 `false`。Gatekeeper 仍可能拒绝未公证的磁盘映像。

Developer ID 使用仓库 secret `AEGIS_MACOS_DEVELOPER_ID_P12_BASE64` 和 `AEGIS_MACOS_DEVELOPER_ID_P12_PASSWORD`。证书只进本次作业的临时钥匙串，不替换登录钥匙串搜索列表。

这不是发行资格，也不代替产品阶段一的五步证据。

当前交付 runner 与 `aegis-release.gn` 只支持 arm64；工作流、计划入口和手动包装脚本会在查找源码或开始重建前拒绝 x64。现有 `.app` 必须有已经 finalize 的构建身份，产品 SHA、补丁 lineage、overlay、GN 和产物复查均须通过；回执分别记录实际产品 SHA 与包装 workflow SHA。

`Package DMG` / `Internal DMG` 的 `product_checkout` 和 `product_sha` 可绑定与包装脚本不同的既有产品工作树及完整 SHA；留空时使用当前 workflow 工作树和 SHA。该工作树必须干净并处于指定 SHA，校验器从该工作树运行，Chromium 源码则绑定到所选 App 的 `src/out/AegisRelease`，不沿用包装 shell 的另一棵源码树。对应命令行参数为 `MACOS_PRODUCT_CHECKOUT` / `MACOS_EXPECTED_SOURCE_SHA`。`Rebuild DMG` 使用 workflow 工作树，通过现有 canonical builder 持有同一原子锁，覆盖 GN、构建、身份 finalize 及打包。

本轮只完成源码与离线回归；没有部署 host hook、调度重建、签名或生成 DMG，实际操作的应用身份与回执仍须单列验收。
