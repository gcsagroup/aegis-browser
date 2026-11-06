# iOS 打包与 TestFlight

仓库提供的 `scripts/release/ios-runner.py` 签名 runner 启动入口已禁用。即使已验证 Admin，也会在读取 payload、探测签名密钥、注册或启动 listener 前拒绝；没有绕过开关。队列快照、唯一标签和执行后的身份检查不能保证签名主机隔离。重新启用必须另行实现并审查执行前授权或服务端 workflow 隔离；不得用手动注册的共享或同标签 runner 绕过。本次只禁用该源码入口，未改动任何现存主机、钥匙串或注册；无凭据验证、交付合同和只读查询仍可用。

Alpha 固定仅内测，原生导出开启 `testFlightInternalTestingOnly`，上传后必须读回 `INTERNAL_ONLY`。Beta 可内外测，禁止生产目的地和正式送审。Release 可用于各目的地，每个阶段显式执行。上传不会自动分发、送审或公开发布。

## cloud 默认与显式 manual 回退

CLI、Fastlane、Simple/Full Actions 和 candidate tag 创建的新 iOS 包默认使用 `cloud`。云签名在获准的 GitHub-hosted macOS runner 上使用 Xcode 26.6 和有 cloud-managed Distribution 权限的 ASC key，执行新的 archive→export，不导入分发 P12。

需要回退时显式选择：CLI 使用 `--signing-mode manual`，Fastlane 使用 `signing_mode:manual`，Actions 将 **Signing mode** 选为 **manual**。本机打包使用此显式回退。cloud 失败会停止当前尝试；核对回执和远端状态后，使用未占用 build 与新 run ID 发起 manual 打包，不自动重试上传。

签名选择仅用于新包。Status/Wait 及已有包的后续阶段按原有身份和签名收据工作；旧 manual 收据继续校验证书指纹与 profile。manual tag 使用[云签名指南](ios-cloud-signing-poc.md#current-signing-default-and-manual-fallback)中的来源绑定注释。

使用干净的已提交源码、Ruby 3.3.6、锁定的 Bundler/Fastlane、Node 22.23.1、Python 3.11+ 和 Xcode。先运行 `bundle install`，再用 `./release ios plan` 读取来源 SHA/tree、原生输入摘要及可用阶段。每次变更必须显式指定 `--profile`。

```sh
./release ios package --profile alpha --signing-mode manual --version 1.0.0 --build 6 --run-id ios-alpha-6
./release ios upload --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256
./release ios wait --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios status --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios compliance --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256 --input compliance.json
./release ios metadata --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256 --input metadata.json
./release ios distribute --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight-internal --groups '现有内测组名' --manifest-sha256 MANIFEST_SHA256
```

示例 build 仅供演示，实际先查 ASC 再选未使用的编号。独立保留 manifest 摘要、IPA、dSYM、校验文件及完成的上传记录；后续改描述和分发复用这些文件，不重新构建或上传。来源 SHA/tree 改变后必须重新打包。本地签名使用现有 Apple Distribution 私钥和三份 App Store profile，不导出私钥，不改共享钥匙串 ACL。凭据只能通过私密环境或受保护的 Actions secrets 提供。

## 本地自动准备签名

在安装好锁定 Ruby/Bundler 依赖的环境中运行：

```sh
python3 scripts/release/local-ios-signing.py --team "$AEGIS_APPLE_TEAM_ID" --certificate-sha1 "$AEGIS_IOS_CERT_SHA1" --unlock
```

脚本从下载目录自动发现现有共享 ASC 配置和私钥，只解析配置赋值、不执行 shell。通过只读 App Store Connect API 下载三份现有 App Store profile，校验 team、bundle ID、证书、有效期与 entitlement，再安装缺失的 profile。文件固定命名为 `Aegis-AppStore-App.mobileprovision`、`Aegis-AppStore-Safari.mobileprovision`、`Aegis-AppStore-Share.mobileprovision`，不加日期。三个产品渠道共用这些 profile，由导出参数控制渠道。ASC 的既有 profile 和 Bundle ID 显示名称也沿用不含日期的命名；脚本不创建或重命名远端资源。

`--unlock` 从证书指纹匹配的材料目录读取私密 `EXISTING-KEYCHAIN-PASSWORD.txt`，通过 macOS Security API 解锁现有非登录签名钥匙串。密码不进入命令行、日志、回执或 AI 操作。脚本不解锁登录/系统钥匙串，不修改共享 ACL、分区列表或搜索列表；既有私钥访问授权仍由系统执行。缺失、冲突、符号链接、非私密凭据和校验失败均停止，不猜密码、不重复尝试、不退回界面自动填写。公有校验回执写入 `.artifacts/ios-signing/app-store/signing-receipt.json`。

## Actions 精简版与完整版

表单英文选项与中英文操作步骤见 [Actions 操作指南](ios-delivery-actions.md)。

默认 cloud 使用 `AEGIS_APPLE_TEAM_ID` 和受保护的 ASC key：`AEGIS_ASC_KEY_ID`、`AEGIS_ASC_ISSUER_ID`、`AEGIS_ASC_KEY_BASE64`。仅显式选择 manual 时导入分发 P12 和 profiles。

显式选择 `manual` 时，打包作业使用 GitHub 托管的临时 macOS，在 `aegis-ios-signing` 环境中保留 team、证书指纹和三份 profile 名称变量，并配置五个加密 secrets：`AEGIS_IOS_DISTRIBUTION_P12_BASE64`、`AEGIS_IOS_DISTRIBUTION_P12_PASSWORD`、`AEGIS_IOS_APP_PROFILE_BASE64`、`AEGIS_IOS_SAFARI_PROFILE_BASE64`、`AEGIS_IOS_SHARE_PROFILE_BASE64`。二进制材料使用单行 Base64。导入前校验 profile 与现有 team、目标和证书一致；打包后清理临时钥匙串与 profiles。签名材料不得输出到日志、提交或放入上传凭据环境。

完整版显式传递 ASC 和签名凭据名称，被调用任务的 `aegis-ios-store` 和 `aegis-ios-signing` 环境值优先生效；不使用 `secrets: inherit`。两个手动入口共用一套后端，表单字段与操作使用英文，本地 CLI 保持原接口。所有手动操作（包括查询）仅限当前仓库 Admin；原操作人和重跑人均需校验。签名、Apple、私有 Draft 各自使用原有受保护环境。

### 精简版 / Simple

选择 `iOS Delivery · Simple`，填写版本（例如 `1.0.0`）与 build（例如 `35`）。表单包含操作、版本、build、目标产物和签名模式；新包默认 cloud，查询和等待时忽略目标产物与签名模式。

| 操作 | 结果 |
|---|---|
| Package | 新 build 的 IPA、dSYM 和清单，不自动上传 |
| Package and upload | 先确认 Apple 无该 build/上传，打包并上传同一份新 IPA，不分发、不送审 |
| Status | 直接按版本/build 查询 Apple；不需要凭据、旧 artifact 或历史源码 |
| Wait | 最多等 30 分钟处理完成；失败、未上传、过期或超时均停止，不重传。超时仍为失败，在 Summary 和状态 artifact 保留最后一次 Apple 状态，可用 Status 或 Wait 再查同一构建 |

查询不会自动选择最新 build，也不会从 `APP_STORE_ELIGIBLE` 猜测 Beta/Release。报告的 `querySource` 是查询代码来源，不是被查询二进制的源码证明。查不到会明确显示 `NOT_FOUND`。查询使用只允许 GET 的 Apple 客户端。

### 完整版 / Full

选择 `iOS Delivery · Full`。它通过本地 reusable workflow 调用同一后端，不复制签名/上传实现。版本/build 供打包、草稿、查询、直接等待使用；**已有包上传、带原包记录的等待、说明、合规与分发**填写最新成功运行 Summary 的完整 **Delivery receipt**。目标产物可用 Auto，分发填写既有组名，说明/合规单独填写审核过的阶段 JSON。

凭据仍固定包型、版本/build、原始 producer、最新状态 run/attempt 与原始清单摘要；不授予权限。旧 `aegis-ios-v1` 凭据继续可用。同一次运行完成新包上传时输出 `aegis-ios-v2:...:uploaded`，用来区分“只有原包”和“同一 run 已上传”；它同样依赖成功 producer、清单和上传记录独立复验。仅版本/build 不能授权上传或其他写操作。

打包并上传的原包 artifact 与后续状态 artifact 分别保留，摘要由成功打包 job 直接传给上传 job。输入不可更改原始来源。运行重试不能重复打包上传；结果未知先读回对账。Package 和候选 Tag 仍只产生包/私有 Draft；仅显式选择 Package and upload 才会上传。

Alpha 只内测；Beta 可内外测、禁止正式送审；Release 通用但每阶段显式选择。外测分发会发起 Beta Review，仍需要另行授权；表单不提供正式送审或公开发布操作。

Actions 保留无凭据验证、受保护签名、私有 Draft、TF 四类作业。导入阶段先核对交付凭据与仓库、workflow、来源、attempt、摘要和上传记录；受保护作业再独立复验，随后才加载 ASC key。正式送审是独立的 Release 本地阶段，验收中不执行。

任何变更先写不可变 intent。网络失联后结果未知，必须先读回对账，不盲目重试或换 run 丢弃历史。`status` 会显示 buildUploads、处理状态、原生 audience、合规、分组和原始测试员状态；`INSTALLED` 不证明当前 build 已在真机运行。保留失败作业的产物与日志。内置盘至少保留 8 GiB、外置盘至少保留 15 GiB 真正可用空间。

上游合并前必须通过必需 CI 和 iOS 验证；合并后跟进新 main CI，在新来源上复测托管 Fastlane、Actions、Tag→私有 Draft × Alpha/Beta/Release，并逐个上传同一实包、读回 TF 状态。上游验收后仅停用 fork 的 iOS 开关和 iOS 环境入口，保留历史证据与回滚快照，不影响 Android/macOS。完整配置变量、输入 JSON、保护规则、恢复及回滚步骤见 [iOS operations](ios-release.md)。

当前已核验的 Apple 系统加密实现，在实际 Info.plist 中声明布尔型 `ITSAppUsesNonExemptEncryption=false`；导出验证会核对签名 App 的同一声明。加密实现或依赖改变后必须重新评估，历史 IPA 保持原样。验收先读回 TF 自动识别的 `usesNonExemptEncryption=false`，再考虑显式合规更新。

候选 Tag 还需独立于工作流代码的仓库保护：[限定规则](../../.github/ios-candidate-admin-ruleset.json) 仅覆盖 `refs/tags/candidate/ios/**/*`，创建、更新、删除只允许仓库 Admin。先以 disabled 准备，通过 GraphQL 确认 role ID5 的 `repositoryRoleName=admin`，再启用并用真实 Admin token 执行 `node scripts/ci/ios-operator.mjs --verify-candidate-tag-policy`。不扩大绕过角色或 Tag 范围。交付权限边界以通过合并流程的 main 代码可信为前提，共享 main 审核治理不在此次 iOS 改动中。
