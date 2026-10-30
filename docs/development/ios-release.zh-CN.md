# iOS 打包与 TestFlight

Alpha 固定仅内测，原生导出开启 `testFlightInternalTestingOnly`，上传后必须读回 `INTERNAL_ONLY`。Beta 可内外测，禁止生产目的地和正式送审。Release 可用于各目的地，每个阶段显式执行。上传不会自动分发、送审或公开发布。

使用干净的已提交源码、Ruby 3.3.6、锁定的 Bundler/Fastlane、Node 22.23.1、Python 3.11+ 和 Xcode。先运行 `bundle install`，再用 `./release ios plan` 读取来源 SHA/tree、原生输入摘要及可用阶段。每次变更必须显式指定 `--profile`。

```sh
./release ios package --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6
./release ios upload --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256
./release ios wait --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios status --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios compliance --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256 --input compliance.json
./release ios metadata --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256 --input metadata.json
./release ios distribute --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight-internal --groups '现有内测组名' --manifest-sha256 MANIFEST_SHA256
```

示例 build 仅供演示，实际先查 ASC 再选未使用的编号。独立保留 manifest 摘要、IPA、dSYM、校验文件及完成的上传记录；后续改描述和分发复用这些文件，不重新构建或上传。来源 SHA/tree 改变后必须重新打包。签名使用现有 Apple Distribution 私钥和三份 App Store profile，不导出私钥，不改共享钥匙串 ACL。凭据只能通过私密环境或受保护的 Actions 的打包与上传统一使用 **iOS Delivery**；独立保留 **iOS Release Validation** 自动无凭据验证与 **iOS Coverage** 模拟器覆盖率。手动运行三个 iOS 工作流均要求实际仓库 Admin 权限（包含组织所有者授予的 Admin），原发起者和重跑者都必须通过校验。Maintain/Write/Read 和权限未知均在受保护作业排队前拒绝；GitHub 原生界面仍可能向 Write 显示运行按钮。本地流程验证真实 token 用户，runner 在签名探测前验证真实 CLI Admin。fork 交付入口保持停用。

在 main 选择 `operation=package`，默认 Alpha，`destination=auto` 仅保留产物；选择 `github-draft` 必须提供精确 Tag。推送 `candidate/ios/版本-profile.build` 自动解析身份，仅打包到私有 Draft，不自动上传 TF。已有实包在同一工作流选择 `upload|wait|status|metadata|compliance|distribute`，提供原始 `package_run_id`、`manifest_sha256`、精确 `source_attempt`；后续阶段再指定最新成功状态的 `upload_run_id`。`distribute` 必须显式选择内测/外测和现有组，Alpha 外测在准入阶段拒绝。先验证来源和产物，再加载 ASC 凭据。被拒绝或明确未执行的旧作业不会阻塞 Admin；任何可能已开始的变更仍须先读回对账，不能盲目重试。外测 Beta Review 和正式送审均需独立授权，不在自动验收中执行。

`metadata.json` 仅允许 `locales`，每个语言可有 `description` 和 `whatsNew`（非空、最多 4000 字符）。保留反馈联系方式和其他语言。`compliance.json` 必须显式给出布尔型 `usesNonExemptEncryption`、精确 `sourceSha`、`nativeInputsSha256` 及 `authorization`；不推断合规答案，不覆盖冲突的已有答案。

Actions 分为无凭据验证、受保护的签名、私有 Draft、TF 四部分。Tag 格式为 `candidate/ios/版本-profile.build`。TF workflow 用 `package_run_id` 选原始打包 run，后续阶段用 `upload_run_id` 选最新成功的状态 run，同时指定精确 attempt 和原始 manifest 摘要。导入阶段先核对仓库、workflow、来源、attempt、摘要和上传凭据；受保护作业再独立复验，随后才加载 ASC key。外测分发会触发 Beta App Review，需要明确授权；正式送审是独立的 Release 本地阶段，验收中不执行。

任何变更先写不可变 intent。网络失联后结果未知，必须先读回对账，不盲目重试或换 run 丢弃历史。`status` 会显示 buildUploads、处理状态、原生 audience、合规、分组和原始测试员状态；`INSTALLED` 不证明当前 build 已在真机运行。保留失败作业的产物与日志。内置盘至少保留 8 GiB、外置盘至少保留 15 GiB 真正可用空间。

上游合并前必须通过必需 CI 和 iOS 验证；合并后跟进新 main CI，在新来源上复测本地 Fastlane、Actions、Tag→私有 Draft × Alpha/Beta/Release，并逐个上传同一实包、读回 TF 状态。上游验收后仅停用 fork 的 iOS 开关和 iOS 环境入口，保留历史证据与回滚快照，不影响 Android/macOS。完整配置变量、输入 JSON、保护规则、恢复及回滚步骤见 [iOS operations](ios-release.md)。

当前已核验的 Apple 系统加密实现，在实际 Info.plist 中声明布尔型 `ITSAppUsesNonExemptEncryption=false`；导出验证会核对签名 App 的同一声明。加密实现或依赖改变后必须重新评估，历史 IPA 保持原样。验收先读回 TF 自动识别的 `usesNonExemptEncryption=false`，再考虑显式合规更新。
