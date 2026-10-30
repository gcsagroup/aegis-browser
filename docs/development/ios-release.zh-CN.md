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

示例 build 仅供演示，实际先查 ASC 再选未使用的编号。独立保留 manifest 摘要、IPA、dSYM、校验文件及完成的上传记录；后续改描述和分发复用这些文件，不重新构建或上传。来源 SHA/tree 改变后必须重新打包。签名使用现有 Apple Distribution 私钥和三份 App Store profile，不导出私钥，不改共享钥匙串 ACL。凭据只能通过私密环境或受保护的 Actions secrets 提供。

Actions 的打包与上传统一使用 **iOS Delivery**；独立保留 **iOS Release Validation** 自动无凭据验证与 **iOS Coverage** 模拟器覆盖率。手动运行三个 iOS 工作流均要求实际仓库 Admin 权限（包含组织所有者授予的 Admin），原发起者和重跑者都必须通过校验。Maintain/Write/Read 和权限未知均在受保护作业排队前拒绝；GitHub 原生界面仍可能向 Write 显示运行按钮。本地流程验证真实 token 用户，runner 在签名探测前验证真实 CLI Admin。fork 交付入口保持停用。

表单精简为 7 项。新打包通常只填 `version`、未使用的 `build`；其余保持默认，生成 Alpha 产物。后续操作只选择 `operation` 并把上次成功运行 Summary 的整行**交付凭据**复制到 `source`，包类型保持 `auto`、版本和构建号留空即可；显式填写冲突身份会拒绝。

| 输入 | 用途 |
| --- | --- |
| `operation` | 本次执行什么；默认 `package` 只打包 |
| `profile` | 新包选择 Alpha/Beta/Release；`auto` 新打包默认 Alpha，后续沿用凭据 |
| `version`、`build` | 仅打包必填，build 必须未使用 |
| `source` | 上传及后续操作必填，从上次成功运行摘要复制整行凭据 |
| `groups` | 仅分发填写现有组名，多组以逗号分隔 |
| `stage_input` | 仅更新描述或合规时填写已确认 JSON |

| 操作 | 实际作用 |
| --- | --- |
| `package` | 签名打包并保留产物，不上传 |
| `draft` | 打包到私有 GitHub Draft；从版本、包型、构建号推导精确已有 Tag 并核对来源 |
| `upload` | 上传凭据指定的原 IPA 到 TF，不自动分发或送审 |
| `wait` / `status` | 等待处理 / 查询处理、受众、合规及分组状态 |
| `metadata` | 更新指定语言的 Beta 描述、测试内容，保留反馈联系方式 |
| `compliance` | 写入经过确认且与来源绑定的加密合规答案 |
| `distribute-internal` | 分发到指定现有内测组 |
| `distribute-external` | 外测分发，Alpha 禁用；涉及 Beta Review，需独立授权 |

凭据包含不可变包型、版本、构建号、原始打包 run、最新状态 run、精确 attempt 和独立固定的 manifest 摘要，替代原来分散的来源字段。凭据只是身份定位，不是权限或信任凭证；后台仍检查 Admin、来源 SHA/tree、当前 attempt、成功生产者、产物摘要、原始来源与上传记录。每次操作等待整次运行成功，再使用它输出的新凭据；失败或结果未知先读回对账，不能换旧凭据重传。

推送 `candidate/ios/版本-profile.build` 自动解析身份，仅打包到私有 Draft，不自动上传 TF；正常 Draft 打包优先用 Tag 触发。先验证来源和产物，再加载 ASC 凭据。被拒绝或明确未执行的旧作业不会阻塞 Admin；任何可能已开始的变更仍须先读回对账。外测 Beta Review 和正式送审均需独立授权，不在自动验收中执行。

`metadata.json` 仅允许 `locales`，每个语言可有 `description` 和 `whatsNew`（非空、最多 4000 字符）。保留反馈联系方式和其他语言。`compliance.json` 必须显式给出布尔型 `usesNonExemptEncryption`、精确 `sourceSha`、`nativeInputsSha256` 及 `authorization`；不推断合规答案，不覆盖冲突的已有答案。

Actions 保留无凭据验证、受保护签名、私有 Draft、TF 四类作业。导入阶段先核对交付凭据与仓库、workflow、来源、attempt、摘要和上传记录；受保护作业再独立复验，随后才加载 ASC key。正式送审是独立的 Release 本地阶段，验收中不执行。

任何变更先写不可变 intent。网络失联后结果未知，必须先读回对账，不盲目重试或换 run 丢弃历史。`status` 会显示 buildUploads、处理状态、原生 audience、合规、分组和原始测试员状态；`INSTALLED` 不证明当前 build 已在真机运行。保留失败作业的产物与日志。内置盘至少保留 8 GiB、外置盘至少保留 15 GiB 真正可用空间。

上游合并前必须通过必需 CI 和 iOS 验证；合并后跟进新 main CI，在新来源上复测本地 Fastlane、Actions、Tag→私有 Draft × Alpha/Beta/Release，并逐个上传同一实包、读回 TF 状态。上游验收后仅停用 fork 的 iOS 开关和 iOS 环境入口，保留历史证据与回滚快照，不影响 Android/macOS。完整配置变量、输入 JSON、保护规则、恢复及回滚步骤见 [iOS operations](ios-release.md)。

当前已核验的 Apple 系统加密实现，在实际 Info.plist 中声明布尔型 `ITSAppUsesNonExemptEncryption=false`；导出验证会核对签名 App 的同一声明。加密实现或依赖改变后必须重新评估，历史 IPA 保持原样。验收先读回 TF 自动识别的 `usesNonExemptEncryption=false`，再考虑显式合规更新。

候选 Tag 还需独立于工作流代码的仓库保护：[限定规则](../../.github/ios-candidate-admin-ruleset.json) 仅覆盖 `refs/tags/candidate/ios/**/*`，创建、更新、删除只允许仓库 Admin。先以 disabled 准备，通过 GraphQL 确认 role ID5 的 `repositoryRoleName=admin`，再启用并用真实 Admin token 执行 `node scripts/ci/ios-operator.mjs --verify-candidate-tag-policy`。不扩大绕过角色或 Tag 范围。交付权限边界以通过合并流程的 main 代码可信为前提，共享 main 审核治理不在此次 iOS 改动中。
