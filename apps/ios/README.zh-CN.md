[English](./README.md) | [**简体中文**](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# Aegis 原生 iOS 工程

本目录是 GCSA-aegis 的原生 iOS 产品线，不是 Chromium 的 WebKit 包装层，也不是独立扩展产品。当前源码包含 SwiftUI/WKWebView 浏览器、普通/私密隔离、内嵌 Safari/Share extensions、Agent Broker、共享 Agent Contract v1，以及四个离线确定性工作流。

> **证据状态 — 2026-08-28：`SIMULATOR_QUALIFIED_HARDENED`。** 该状态只覆盖当前具名 iPhone/iPad Simulator 链路，并绑定最新本地硬化证据。真机验证为 `NOT_RUN`；默认浏览器 entitlement 为 `PENDING`；正式签名、Archive、TestFlight 和 App Store 交付均为 `NOT_RUN`。项目整体仍是 **release No-Go**。

## 环境与工程生成

工程声明 iOS 18.4 deployment target、Swift 6 严格并发、iPhone/iPad device family 和 Xcode 26。需要 Xcode 26 系列、可用 iOS Simulator runtime、Node.js 和 XcodeGen。

XcodeGen 没有只读生成模式。先检查工具和已提交工程；只有在明确需要重生成时才执行第三条命令，并复核生成差异：

```bash
xcodegen --version
xcodebuild -list -project apps/ios/Aegis.xcodeproj
xcodegen --spec apps/ios/project.yml
```

无正式签名的 Simulator Debug 构建示例：

```bash
xcodebuild \
  -project apps/ios/Aegis.xcodeproj \
  -scheme Aegis \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/aegis-ios-build-NEW-ID \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`/tmp/aegis-ios-build-NEW-ID` 应替换成新的临时路径。该命令只产生本地 Simulator 构建证据，不等于 Archive、正式签名或可分发包。

## Simulator 测试

先单独校验离线 fixture，再运行默认 dry-run：

```bash
node apps/ios/scripts/verify-fixtures.mjs
bash apps/ios/scripts/run-simulator-tests.sh \
  --dry-run \
  --output-dir /tmp/aegis-ios-NEW-ID
```

dry-run 会校验 fixture 与 Safari 文档身份 Node harness、读取 Simulator runtime/device type，并打印计划命令；不会创建设备、启动测试或创建输出目录。

明确需要执行 iPhone/iPad 测试时，使用一个尚不存在的 `/tmp/aegis-ios-*` 目录：

```bash
bash apps/ios/scripts/run-simulator-tests.sh \
  --execute \
  --output-dir /tmp/aegis-ios-NEW-ID-EXECUTE
```

执行模式默认选择最新可用 iOS runtime，依次使用专用的 `Aegis QA iPhone 17` 和 `Aegis QA iPad Air 11-inch (M4)` Simulator，必要时只创建缺失设备。脚本不会 erase、delete、shutdown、uninstall 或清理任何 Simulator，也不会覆盖已有输出；结果保存在具名日志、metadata、summary 和 `.xcresult` 中。

可用参数包括 `--project`、`--workspace`、`--scheme`、`--test-plan`、`--runtime` 和 `--output-dir`。默认 scheme 为 `Aegis`；仓库还声明 `Aegis-Debug` 与 `Aegis-Release`。原生 iOS 工程不属于 pnpm workspace，不应把 `pnpm run quality:fast` 当作 Xcode 测试替代品。

## 模块结构

- `AegisApp`：SwiftUI App、iPhone/iPad 布局、浏览器与 Agent 任务中心、Share inbox 消费入口。
- `BrowserKit`：WKWebView 标签页、导航、普通/私密配置、历史/收藏和 WebExtension 资源加载。
- `AegisPolicyKit`：链接清理、PII 扫描、钓鱼评分和策略快照解析。
- `AgentKit`：Agent Contract v1 codec、授权与租约、资源登记、一次性动作能力、Broker 和四个离线工作流。
- `SafariWebExtension` 与 `SharedWebExtension`：受用户手势和短租约约束的只读页面观察路径。
- `ShareExtension` 与 `Shared/ShareInbox.swift`：受限 HTTP(S) URL 的专用 App Group 交接。
- `Tests` 与 `scripts`：单元/UI 测试源码、离线 fixture 校验和 iPhone/iPad Simulator 执行入口。
- `project.yml` 与 `Aegis.xcodeproj`：XcodeGen 真源和当前生成工程。

## Agent 与安全边界

- 普通与私密配置使用不同的 WKWebsiteDataStore、WKUserContentController 和扩展状态；私密配置不持久化，并禁用历史、收藏和 Agent。
- AgentKit 以不可变任务授权、文档租约、不可复用资源 ID 登记和一次性 capability 约束动作；用户同意前只允许本地确定性工作。
- R1/R2 受保护动作需要独立于任务授权的第二次确认；批准对象使用随机 ID、最长 60 秒 TTL 和完整动作范围摘要，恢复与签发都必须精确匹配，进入签发后无论成功或拒绝都会先销毁该批准，不能重放。
- 四个工作流保持离线受控：浏览器管家会在独立 R1 动作确认后，对当前 Aegis 本地收藏执行去追踪参数、精确去重和稳定排序。事务使用 before/after 树哈希、Keychain 密钥支持的 AES-GCM journal、File Protection、崩溃过渡判定和状态漂移保护；App 重启后只恢复“可撤销”入口，仍需新的任务授权和独立 R1 动作确认，绝不自动写入。深度研究仍不读取真实站点，安全下载不发起真实下载，购物助手不支付或下单；当前没有生产远程模型路径。
- Safari 路径当前只观察有界页面信息，受 profile、tab、frame、origin、route、worker instance、gesture nonce、isolated-world document token、navigation epoch 和短租约绑定。授权前不读取 DOM/location；授权后的单次脚本任务先核对完整 URL 与文档身份再固定快照，导航变化会安全拒绝或主动烧毁租约。结果尚未形成进入主 App/Agent 的完整产品管线，真实 Safari native messaging、Private Browsing 与 worker 生命周期也尚未跑通。
- Share inbox 只接受无 credentials 的 HTTP(S) URL，限制大小、有效期和消费次数；主 App 当前消费后导航，尚未在该路径前接入完整 PolicyKit 扫描。
- BrowserSession 主框架导航已在网络加载前接入 AegisPolicyKit 的 LinkSanitizer 与 PhishingScorer，并显示追踪参数清理或高风险 URL 阻止提示；PII Scanner 仍未接入真实出站/模型网络链。当前 delegate 与 UI 测试不等于网络层零请求仪器，也未覆盖真实重定向逐跳矩阵。
- 共享合同 Schema 和 Golden Vectors 位于 [`packages/core/src/agent/contracts/v1`](../../packages/core/src/agent/contracts/v1/agent-contract-v1.schema.json)，Swift 测试读取同一向量；这证明合同兼容范围。收藏事务另有真实本地 Store 测试，但这些证据都不等于真机或发布安全证明。

## 当前验收证据

2026-08-28 的当前本地工作树构建使用 Xcode 26.6、iOS Simulator 26.5：iPhone 17 共 113 项，112 通过、0 失败、1 项按设计跳过（仅 iPad 分栏）；iPad Air 11-inch (M4) 共 113 项，113 通过、0 失败。安全定向单元/集成测试 70/70、关键 UI 测试 4/4 通过；Safari Node 文档身份测试与 Release 测试入口隔离检查也通过。

Computer Use 可见验收实际完成了高风险导航阻断、追踪参数清理、收藏整理跨重启恢复撤销，以及再次重启不重放。完整范围、结果包路径、截图和剩余风险见[《iOS Simulator 硬化验收记录》](../../docs/audit/ios-simulator-hardening-2026-08-28.md)。旧[资格验收记录](../../docs/audit/ios-simulator-qualification-2026-08-28.md)保留为历史基线；当前结果仍绑定 dirty 本地工作树，不是干净提交、签名产物或发布候选证据。

## 已知发布门禁

- 冻结并提交精确 iOS 源码身份，复核 XcodeGen 重生成差异。
- 完成 Debug/Release 构建、最低系统与多 runtime、真实站点、生命周期、性能、无障碍和隐私矩阵。
- 完成真机安装，以及 Safari 权限、Share App Group、普通/私密隔离和 Agent 安全边界的端到端验收。
- 扩展并验证 PolicyKit 的 PII 出站执行路径；若扩展到真实 DOM、真实下载或远程模型，另做权限、同意、DLP、恢复和出站验收。主框架 URL 导航策略与收藏跨重启撤销 journal 已进入 Simulator 范围，但仍需真实站点和真机矩阵。
- 准备并取得默认浏览器 entitlement；补齐 Privacy Manifest、隐私标签、第三方声明和出口合规材料。
- 配置 Development Team/provisioning，完成正式签名、Archive、TestFlight、App Store、安装/升级/回滚和分发授权。

## 相关文档

- [iOS Simulator 资格验收记录](../../docs/audit/ios-simulator-qualification-2026-08-28.md)
- [iOS Simulator 硬化验收记录](../../docs/audit/ios-simulator-hardening-2026-08-28.md)
- [产品架构与 Agent 整合方案](../../docs/ios-product-architecture-and-agent-integration-2026-08-28.md)
- [iOS 项目执行计划](../../docs/ios-project-execution-plan-2026-08-28.md)
- [Aegis Browser Agent v1 实现方案](../../docs/aegis-browser-agent-v1-implementation-plan-2026-08-28.md)
- [Aegis Browser Agent v1 开发执行计划](../../docs/aegis-browser-agent-v1-development-execution-plan-2026-08-28.md)
- [仓库架构](../../docs/architecture.zh-CN.md)与[路线图](../../docs/roadmap.zh-CN.md)
