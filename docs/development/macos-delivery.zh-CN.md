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

## DEV GeoSite 静态规则编译（M1）

在仓库根目录用 Node.js 20 或更新版本，从本地 XTLS/Xray-rules-dat 标准版 raw `geosite.dat`（`20261120235103`）及 Chromium `155.0.8059.80` ICANN+PRIVATE PSL 生成单组静态清单。

```sh
node scripts/dev/compile-geosite.mjs --dat geosite.dat --psl effective_tld_names.dat \
  --group DEBIAN --output debian.json
```

可选组为 `DEBIAN`、`DOUBAN`、`MEITUAN`。首次编译须使用尚不存在的输出路径。输出卷须启用所有权检查，目录及其上级目录须由当前用户或 root 所有，允许其他用户写入的目录须设置 sticky bit。发布时使用 macOS 随附的系统 Ruby 读取目录 ACL。ACL 须可读取，且仅可授予读取和访问权限。重复编译时，已有普通文件的字节完全一致即可直接成功。若内容不同，或输出路径指向符号链接等非普通文件，请为 `--output` 指定一个新路径。加 `--verify` 可重建并逐字节核对现有清单。历史 `DEBIAN` 清单使用 V2Fly `20261121064510` 的 `--dlc dlc.dat` 复现。每次必须明确指定一个来源，编译器离线校验原文件与完整 typed 规则的摘要。[固定分类与来源规格](https://github.com/quinn521/aegis-browser/blob/54ce210fdcaf242b2df3bc74a24d77a820075a5c/docs/superpowers/specs/2026-11-21-geosite-updates-design.md#官方来源与首批完整分类)

CLI 和自动化校验均使用上述命令直接启动。代码复用可按普通模块导入 `compileGroup` 和 `matchesHost`。

在 `node --test scripts/dev/tests/compile-geosite.test.mjs` 前设置 `AEGIS_XRAY_GEOSITE_INPUT_DIR`（`geosite.dat`）和 `AEGIS_GEOSITE_INPUT_DIR`（`dlc.dat`、`effective_tld_names.dat`）可运行真实输入回归。已认证的分类规则和摘要随测试夹具提供。

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

在 **Actions → macOS Delivery · Bot** 填写版本和 build。上游 ad-hoc 路径使用桌面产品版本的前三段，并将末段传为 build。例如，`7.5.0.345` 对应 `7.5.0` 和 `345`。

上游 ad-hoc 作业使用 `AEGIS_MACOS_CHROMIUM_ROOT` 和 `AEGIS_MACOS_DEPOT_TOOLS_DIR` 指向构建机上准备好的 Mac 源码与工具。构建身份在源码 App 上完成，ad-hoc 签名在 DMG 的 staging 副本上执行。

| 操作 | 行为 |
| --- | --- |
| Package | 打一张 DMG。`ad-hoc`、`host-signed`、`notarized` 三种；`unsigned-dmg` 记成 `ad-hoc`，`none` 也记成 `ad-hoc`。签名方式必须和包种类一致。fork 上先把这三种都跑通 |
| Tag release | 构建并封存一份 DMG，上传和核对资产后以 `candidate/macos/<version>-<kind>.<build>` 公开为 prerelease。Latest 保持原值 |
| Promote | **仅上游**。仓库管理员在 Environment `aegis-macos-dmg-stable` 批准后，把一张 **notarized** 候选升成稳定 tag `v<version>`。fork 上不开放 |
| Complete | 只给 Bot 回写收据。人不要选 |

候选已封存而发布失败时，从原始 run/attempt 取回 DMG 和 manifest，确认上游 main 与获准提交一致，再用同一提交下的 `macos-dmg-delivery.py tag-release --manifest <manifest> --dmg <dmg>` 继续核对。使用具有发布权限的凭据，并将 `GITHUB_SHA` 设为该候选的获准提交。重复发布前核对原 tag、Draft 和资产摘要。

控制器复用 iOS 已有的 `aegis-ios-bot` Environment 和同一套 Delivery App 变量名（`AEGIS_IOS_DELIVERY_BOT`、`AEGIS_IOS_BOT_INSTALLATION_ID`、`AEGIS_IOS_BOT_PRIVATE_KEY`）。fork 上要装同一套 App，并用 fork 自己的 installation id。fork 的默认分支可以保持 `develop`；交付仍严格绑定该仓库当前 `main` 的完整 SHA。它先确认当前 `main` 的 quality 与 secret-scanning 已通过，再调度 `macos-dmg.yml`，并等到那次运行结束。调度响应里必须有 `workflow_run_id`；空响应不会重试。控制器与人工入口均启用 `bot_callback=yes`。控制器最多同步等待 5 小时，托管作业上限为 355 分钟；超过等待预算只记录 `monitoring-deferred` / `pending=true`，不报告完成、公证成功或候选 tag，也不重复调度。子运行保留原 360/400 分钟构建预算，成功后由既有 `call-bot` 路径继续核验并记录完成。回调会重新核对父运行、attempt、所选作业、封存摘要和可选候选资产；失败或证据缺失不能回写完成收据。

`host-signed` 和 `notarized` 都走 `macos-developer-id.py`。两者的作业专用钥匙串分别按 360/400 分钟预算设置锁定时间，保留 `always()` 清理；旧短流程默认仍为 1 小时。只有 `notarized` 作业启用 `MACOS_NOTARIZATION_SIGNING=1`：对嵌套 Mach-O、辅助 App、framework 和主 App 由内向外签名，使用安全时间戳及 Hardened Runtime。主 App、Renderer 和 GPU 的 entitlements 读取自已验证构建身份中的 Chromium commit，不读取包装工作树中的可变文件，也不启用调试权限。参数依据 [Apple 公证要求](https://developer.apple.com/documentation/security/resolving-common-notarization-issues) 和 [Chromium 签名角色](https://chromium.googlesource.com/chromium/src/+/main/chrome/installer/mac/signing/parts.py)。

DMG 生成后执行 `notarytool submit --apple-id --team-id --password --wait`，再 `stapler staple` 与 `stapler validate`，然后才封 manifest。不执行 `notarytool store-credentials`。密钥是 `AEGIS_MACOS_NOTARY_APPLE_ID`、`AEGIS_MACOS_NOTARY_PASSWORD`，Team ID 用 `AEGIS_APPLE_TEAM_ID`。低层 `macos-delivery-receipt.json` 仍是 `notarized=false`，另记 `notarizationSigning`；最终包种类以封存的 `macos-delivery-manifest.json` 为准。低层打包成功后只清理本次复制的 staging，源 App 保留；失败 staging 保留用于诊断。封存仍拒绝意外文件或目录。

控制器不能仅凭整个工作流的绿色状态报告完成：必须验证同一次 attempt 的 admission 和所选 package 作业成功；候选操作还要求 candidate 作业成功。它核验完整产物清单，并下载大小受限的 `macos-dmg-evidence-<run>-<attempt>`，校验归档摘要、manifest、包装回执、源码和包坐标。主 DMG 归档也必须存在；候选 Release 上的 DMG 摘要和大小必须匹配。跳过作业、缺失或过期产物、来源不符均保持失败，不再次调度。

稳定发布只在上游，还要 Environment `aegis-macos-dmg-stable`。Promote 先检查候选 Release 上已上传 DMG 的身份和摘要，再创建指向候选源码的稳定 tag，并将同一 Release 改为稳定版及 Latest，保留同一 DMG asset ID。原 annotated candidate tag 保留为来源证据；不会创建没有 DMG 的新 Release，也不会重新上传二进制。稳定 tag 已存在或写入结果不明时须先核对，不重复发布。fork 矩阵未同步前不要 Promote。

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
