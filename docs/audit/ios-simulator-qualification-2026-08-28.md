# GCSA-aegis iOS Simulator 资格验收记录

- 日期：2026-08-28
- 结论：`SIMULATOR_QUALIFIED`
- 安全复核：GO，仅限本记录定义的 Simulator 实现门
- 项目发布状态：release No-Go

## 1. 目标与验收边界

本轮按已确认方案直接实现原生 iOS 产品与 Aegis Agent v1 的 Simulator 范围，不把“WebKit 浏览器 + 同源 WebExtension”的真机垂直切片作为前置条件。完成标准是：工程可生成和构建；浏览器、Profile、内嵌扩展、Agent Contract/Broker 与四个工作流进入源码；指定 iPhone/iPad Simulator 自动化测试通过；并用 Simulator 可见界面完成代表性实操。

本记录不覆盖真机 Safari/Share 生命周期、默认浏览器 entitlement、正式签名、Archive、TestFlight、App Store 或发布资格。当前工作区还含其他会话的未提交改动，因此证据绑定当前本地工作树和下列结果包，不代表干净提交或可分发源码身份。

## 2. 已完成实现

- 原生 SwiftUI/WKWebView App，包含 iPhone 紧凑界面和 iPad 分栏界面。
- 普通/私密 Profile 使用独立 WebKit 数据存储、内容控制器和扩展状态；私密 Profile 不持久化历史/收藏并禁用 Agent。
- 多标签、导航、普通历史与收藏，以及受控离线 fixture 页面。
- 内嵌 Safari Web Extension 与 Share Extension；Safari 只读路径使用 `authorize → DOM read → consume`，绑定 profile、tab、frame、origin、route、worker instance、gesture nonce 与短租约；当前没有独立 document nonce 或 navigation epoch。Share inbox 对 URL、大小、TTL 和单次消费做限制。
- TypeScript/Swift 共用 Agent Contract v1 Schema 与 Golden Vectors；Swift codec 严格拒绝未知字段和无效合同。
- Agent Broker、任务授权、资源登记、文档租约、一次性 action capability、生命周期撤权和私密 Profile 拒绝。
- 深度研究、浏览器管家、安全下载、购物助手四个离线确定性工作流。
- 浏览器管家真实修改 Aegis 本地收藏：清理追踪参数、精确去重、稳定排序、原子持久化、状态漂移保护与同进程精确撤销。

## 3. 动作批准与重放防护

任务范围授权和 R1 写动作确认必须由两个独立用户手势完成。每个待批准动作包含随机 `approvalID`、最长 60 秒的 `expiresAt`、完整授权、工具、规范参数、序列、最终目标和风险；这些字段共同进入确认摘要。

Broker 在恢复时精确校验批准 ID、摘要和 TTL；签发 action capability 时先销毁批准，再校验所有字段。相同授权和动作重新生成的批准具有不同 ID 与摘要，旧 ID、旧摘要及其交叉组合均不能重放。

独立安全复核结论：Blocker 0、P0 0、P1 0。保留两个非阻断 P2：收藏逆快照只支持同进程撤销；Safari 手势 nonce 达到 4096 后会安全拒绝后续授权，直到 extension native host 进程重启。

## 4. 自动化测试结果

最终证据已复制到 Git 忽略的本地目录 `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2`，并附 SHA-256 清单；没有复制 DerivedData。该目录是本机验收证据，不会随源码提交或分发。

- 工具链：Xcode 26.6，Build 17F113，iOS Simulator 26.5。
- fixture：22 个文件校验通过；研究工作流 10 个受控来源；最终提交动作保持禁止。
- 仓库快速质量门：`pnpm run quality:fast` 通过；Core 25 个测试文件、163 项测试全部通过，浏览器脚本自测、仓库合同和 Core 构建同时通过。
- iPhone：Aegis QA iPhone 17；81 项，80 通过、0 失败、1 跳过、0 expected failure。跳过项是仅适用于 iPad 的分栏测试。
- iPad：Aegis QA iPad Air 11-inch (M4)；81 项，81 通过、0 失败、0 跳过、0 expected failure。
- 安全定向单元测试：39/39 通过，结果包 `security-unit.xcresult`。
- 关键安全 UI 测试：2/2 通过，结果包 `security-ui.xcresult`。这两组定向测试均包含在上述完整双端套件中，不另行相加为新的总数。

双端结果包：

- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/iPhone.xcresult`
- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/iPad.xcresult`
- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/iPhone-summary.json`
- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/iPad-summary.json`
- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/run-metadata.txt`
- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/SHA256SUMS`

## 5. Simulator 可见实操

使用 Computer Use 操作真实 Simulator 界面，完成以下代表性路径：

1. iPhone 打开 Agent，选择浏览器管家；任务授权页显示确认前页面读取、模型调用和网络请求均为 0。
2. 第一次点击只确认任务范围，状态进入 `AwaitingActionApproval`；独立页面展示 R1、`bookmarks.apply`、plan/root、before/after 树哈希、规范参数和确认摘要。
3. 第二次点击后真实本地收藏由 4 条整理为 3 条，精确去重 1 条；远程请求保持 0。
4. 撤销操作再次要求独立确认；确认后恢复原逻辑树哈希。
5. iPad 分栏展示标签、Profile 和四个智能工作流；浏览器管家授权页在半屏弹窗内完整可用。

截图：

- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/visual-acceptance/iphone-browser-manager-undo-restored.png`
- `.artifacts/ios-simulator-qualification-2026-08-28-secure-final-v2/visual-acceptance/ipad-task-consent-split-layout.png`

## 6. 剩余边界与发布门禁

- AegisPolicyKit 已有源码和单元测试，但尚未接成 BrowserSession 的完整实时导航、钓鱼拦截或 PII 出站执行链。
- 深度研究不读取真实站点，安全下载不发起实际下载，购物助手不支付或下单；没有生产远程模型路径。
- 收藏撤销缺少跨重启 journal；Safari nonce 上限是 fail-closed 可用性边界。
- 最低系统和多 runtime、真实站点、性能、完整无障碍、隐私与真机矩阵未完成。
- 真机安装与 Safari 权限、Share App Group、默认浏览器 entitlement、provisioning、正式签名、Archive、TestFlight 和 App Store 全部仍是独立门禁。

最终结论：当前实现满足已确认的 iPhone/iPad Simulator 范围，可以作为下一阶段真机和发布硬化的代码基线；不能据此宣称 iOS 发布就绪。
