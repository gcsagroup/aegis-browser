# GCSA-aegis iOS 项目详细开发执行计划

- 版本：Execution Plan v1.0
- 日期：2026-08-28
- 状态：**EXECUTION_BASELINE / 原始执行基线（非实时里程碑状态）**
- 上位方案：[iOS 产品架构与 Aegis Agent v1 整合方案](./ios-product-architecture-and-agent-integration-2026-08-28.md)
- 桌面参考：[Agent v1 实施方案](./aegis-browser-agent-v1-implementation-plan-2026-08-28.md) / [执行计划](./aegis-browser-agent-v1-development-execution-plan-2026-08-28.md)
- 授权边界：后续可按里程碑做本地源码、测试、模拟器和真机开发；正式签名、TestFlight、
  App Store、生产密钥、真实交易和线上部署不在本计划的默认授权内
- Profile 边界：本计划只授权 iOS Profile 及必要的共享合同工作；桌面 Agent 文档仍为
  `PLAN_ONLY`，不授权桌面运行时代码

> **2026-08-28 状态更新：** 当前源码与 Simulator 实现已覆盖 M0–M5 的部分能力，并完成
> [iOS Simulator 硬化验收](./audit/ios-simulator-hardening-2026-08-28.md)。这不等于任何正式
> milestone 已完整退出：M0 的登记真机签名冒烟、entitlement/预算/冻结协议，以及 M6/M7、
> Archive、正式签名和发布门仍未完成，项目保持 release No-Go。

## 0. 执行结论

建议以 6–8 人团队、28–32 周完成内部 RC，约 7–9 个月。Agent 不是后贴功能，而是从 M0
开始与 Profile、标签页、文档身份、收藏夹、下载和审计共同设计。

本项目取消独立“WebKit 浏览器 + 同一套源 WebExtension”POC 的 Go/No-Go 门，但 M0 工程
基础不能跳过。计划采用里程碑内验证：每个功能在进入下一阶段前完成对应的模拟器、真机和
安全验收，避免把平台风险推迟到最后。

开发顺序遵循：

```text
产品拓扑和合同
→ 浏览器与 Profile 基础
→ 安全策略和原生数据能力
→ Agent Broker 与页面执行
→ 四个工作流
→ 攻击、生命周期和性能验证
→ 当前源码 RC 与发布准备
```

## 1. 团队与职责

推荐配置：

- iOS 技术负责人 1 人：架构、WebKit、合并门和当前源码 RC。
- iOS/WebKit 工程师 2–3 人：浏览器外壳、数据能力、扩展、下载与系统集成。
- Agent/模型协议工程师 1 人：Schema、Planner、Broker、工具、确认和结果验证。
- 安全与隐私工程师 1 人：威胁模型、DLP、SSRF、提示注入、审计和商店隐私边界。
- QA/自动化工程师 1 人：XCTest、XCUITest、JS harness、真机矩阵和证据包。
- UI/UX 0.5 人：iPhone/iPad、任务中心、授权与接管流程。
- 构建/发行 0.5 人：Scheme、CI、Archive、身份清单和发布准备。

少于 5 名核心工程人员时，应缩减 Safari companion 或高级工作流范围，不应降低 Agent
授权、文档绑定、秘密隔离和生命周期门槛。

## 2. 工作区与实施规则

### 2.1 开工前基线

每次开始里程碑前必须记录：

- 根仓库分支、HEAD、`git status` 和本次允许修改的文件范围。
- 当前 Xcode、Swift、iOS SDK、部署目标和可用真机清单。
- 生成策略、Agent Schema、黄金向量和资源哈希版本。
- 现有用户改动与研究材料；不得自动 stash、覆盖、清理或批量暂存。

### 2.2 修改原则

- 新产品代码只进入 `apps/ios` 和明确的共享合同/生成脚本。
- 保持 `apps/browser` 运行时与 iOS 运行时解耦；共享语义，不共享平台实现。
- 外部依赖必须有版本、许可证、隐私与供应链记录。
- 不执行 `git add .`，不清理未知文件，不把构建目录或签名材料混入源码证据。
- 功能开关默认关闭；每个能力只在对应测试和真机门通过后打开。

### 2.3 证据分层

每个里程碑分别记录：

1. 源码身份与 diff。
2. Schema、单元和集成测试。
3. 模拟器运行结果。
4. 真机与生命周期结果。
5. Archive 和安装产物身份。
6. 签名、TestFlight 与 App Store 状态。

前一层通过不替代后一层；开发版 App 可启动也不等于可发布。

## 3. 里程碑总览

```text
M0  第 1–2 周    工程、拓扑与合同基线
M1  第 2–6 周    浏览器、标签页、Profile 与基础 UI
M2  第 4–10 周   隐私安全策略与事件
M3  第 7–14 周   收藏夹、历史、下载、摘要与 companion targets
M4  第 9–16 周   Agent Broker、模型协议、确认、审计与任务 UI
M5  第 14–22 周  四个 Agent 工作流和可撤销执行
M6  第 21–27 周  攻击、生命周期、性能和真机矩阵
M7  第 27–32 周  当前源码 RC、Archive 与发布准备
```

允许的重叠必须满足以下依赖：

- M1/M2：BrowserShell 与 PolicyKit 接口冻结后并行。
- M3/M4：原生数据工具接口和 Agent Schema 冻结后并行。
- M4/M5：M5 可提前开发 fixture 与只读流程，但任何副作用端到端执行必须等 M4 安全退出门。
- M5/M6：M6 可提前准备攻击语料和设备矩阵，最终攻击/生命周期签核必须覆盖 M5 冻结实现。

M0、M4 安全退出门和 M7 当前源码验收不能并行跳过。

## 4. M0：工程、拓扑与合同基线（第 1–2 周）

### 目标

建立正式产品工程，不制作一次性 POC。

### 步骤

1. 创建 `apps/ios` Xcode workspace/project、App target、测试 targets 和 Debug/Release Scheme。
2. 建立 `AegisApp`、`BrowserKit`、`AegisPolicyKit`、`AgentKit`、`SharedWebExtension`、
   `SafariWebExtension`、`ShareExtension` 与 `Tests` 边界；暂不开放完整 Agent 权限。
3. 锁定 bundle ID 规则、最低系统、版本来源、资源生成目录和 Debug 本地签名方式。
4. 建立 capability/entitlement 矩阵；由发行负责人在 M0 准备默认浏览器 managed
   entitlement 申请材料并核对专用功能/Info.plist 要求，同时检查 WebExtension、App Group、
   Keychain Group、Associated Domains、后台模式和商店限制。实际向 Apple 提交申请需用户
   单独确认，没有公开支持的能力不得模拟。
5. 把仓库检查从“browser-only”演进为产品拓扑合同：
   - JavaScript workspace 仍只包含 `apps/browser + packages/core`。
   - 必须存在 `apps/browser + apps/ios` 两个产品根。
   - 永久禁止独立 `apps/extension`、独立版本和独立发布入口。
   - 允许 `apps/ios` 内随 App 打包的 extension/share targets。
6. 定义 `Agent Contract v1 — iOS Profile`、版本协商、失败码和黄金向量。
7. 完成首版威胁模型和跨进程数据流：主 App、WebContent、Safari JavaScript、native app
   extension、Share Extension、App Group、Keychain 和模型端点；列出每条边的字段 allowlist。
8. 建立策略与 Schema 生成命令，禁止手工复制后漂移。
9. 锁定首轮资源预算：单任务步骤、时间、标签页、模型调用、网络字节、费用、内存和耗电
   指标，并明确最低性能设备上的测量方法与超限策略。
10. 冻结验收协议：30 页受控浏览器语料、30 个当前公开站点、四类 Agent 各 12 个任务、
   模型/provider/版本/采样参数、重复次数、成功/假成功/越权阈值和清单哈希。正式候选失败后
   不得在同名协议下替换难例或调参。
11. 建立无生产密钥的本地 CI：Swift build/test、Schema、JS harness、资源漂移和仓库合同。
12. `apps/ios` 工程存在后，同步 README、Roadmap 和 Architecture 的“当前实现”与“已批准
   路线”边界。本轮已执行该文档同步，并以 Simulator 硬化审计记录当前证据；这项完成不替代
   本里程碑其余真机、entitlement、预算和冻结协议退出条件。

### 验证

- 全新 checkout 能用一条记录明确的命令生成并构建 iOS 工程。
- App、测试和 companion targets 的 Scheme 可枚举，部署目标一致。
- 使用本地开发签名在一台登记测试设备完成安装和启动冒烟；这只证明工具链可用，不证明
  WebKit、WebExtension 或 Agent 功能可行。
- 未知合同版本、未知工具和未知字段默认拒绝。
- 修改生成资源后，漂移检查会失败；重新生成后通过。
- 仓库合同继续拒绝历史独立 Extension 产品线。
- capability/entitlement 矩阵对“已具备、待申请、不适用、明确不支持”逐项给出证据。
- 默认浏览器申请有负责人、材料清单、待补项和回退决策；未经用户确认不执行外部提交，若已
  获确认则另行保存 Apple 回执。未提交或审批未完成不阻塞 M1–M6 本地开发，但在 M7 前不能
  标为发布就绪。
- 资源预算、测量设备和 fail/降级策略形成可版本化基线。
- 浏览器、Agent 与攻击验收 manifest 有固定哈希，阈值和正式候选规则已版本化。
- 跨进程数据流和字段 allowlist 有机器可读版本；不存在“可信 App Group”或“可信页面”捷径。

### 退出条件与产物

- `apps/ios` 工程基线、模块依赖图、Scheme 清单、生成资源清单。
- Agent Schema v1、TypeScript/Swift 最小黄金向量及 CI 日志。
- entitlement 矩阵、申请材料、开发设备冒烟记录、威胁模型、数据流、资源预算和冻结验收基线。
- M0 是工程基础，不是新的可行性 Go/No-Go；若 Apple entitlement 或公开 API 与锁定范围
  冲突，必须调整范围并记录，不能以占位实现继续。

## 5. M1：浏览器、Profile 与基础 UI（第 2–6 周）

### 目标

完成可持续演进的 iPhone/iPad 浏览器骨架。

### 步骤

1. 实现地址栏、导航、返回前进、刷新、停止、错误页和外部 scheme 处理。
2. 实现多标签页、稳定 Tab UUID、活动标签、分组、顺序、关闭与恢复；标签分组产生可撤销
   的 grouped undo，自动整理不关闭已有标签。
3. 区分普通与私密 Profile，隔离 WebsiteDataStore、历史、审计和模型配置；两者使用不同
   `WKUserContentController`、WebExtension context 和存储。私密 Profile 使用 non-persistent
   data store，不复用普通 Profile 的 extension storage 或 App Group 状态，并禁用 Agent、
   模型调用、任务恢复和持久审计。
4. 实现 Scene 生命周期、WebContent 进程终止、内存警告和冷启动恢复。
5. 完成 iPhone 紧凑布局、iPad 侧栏/多栏布局、Dynamic Type 与 VoiceOver 基线。
6. 预留任务中心入口，但不接入能产生副作用的 Agent 工具。
7. 实现系统 HTTP(S) 入口路由：从冷启动、热启动、新 Scene 和已有 Scene 接收外部链接，
   规范化后只进入普通 Profile；不得把外部链接注入私密 Profile 或恢复旧 Agent 动作。

### 验证

- 标签、Profile、历史和恢复数据不能交叉泄漏。
- 私密 Profile 中任何 Agent 入口、远程/本地模型调用和任务恢复请求均明确拒绝。
- 导航、重载、BFCache、SPA 关键变化和进程终止都会更新文档 generation。
- 前台、后台、锁屏、强杀和恢复在真机上有明确状态，无静默网页执行。
- iPhone/iPad 代表尺寸完成 XCUITest 和人工可访问性检查。
- 冻结的 30 页受控浏览语料全部通过；30 个当前公开站点中至少 27 个完成页面加载、基本
  导航、前后退和标签切换，外部站点阻断单独归因；崩溃和跨 Profile 泄漏均为 0。
- 系统入口路由的冷/热启动、新/旧 Scene 和非法 URL fixture 全部通过。获得默认浏览器
  entitlement 后，必须在真机把 Aegis 设为默认浏览器，并从 Mail、Messages、Notes 和另一
  个测试 App 打开 HTTP(S) 链接；未获批前该真机项明确保持 pending。

### 退出条件与产物

- 浏览器基础功能、Profile 隔离测试、生命周期状态图和真机录像/日志。
- 任何 Profile 泄漏或恢复后自动执行写操作都阻止进入后续 Agent 开启阶段。

## 6. M2：隐私安全策略与事件（第 4–10 周）

### 目标

让现有 Core 语义以可验证方式落到 WebKit，而不是声称与 Chromium 实现等价。

### 步骤

1. 生成并加载规则、钓鱼、PII、链接清洗、设置和策略快照。
2. 实现 WebKit 可见面的导航判定、内容规则、链接清洗和风险提示。
3. 建立 Swift `AegisPolicyKit` 与 TypeScript Core 的黄金向量对照。
4. 实现策略版本、签名、回退和失败关闭；离线时保留最后可信版本。
5. 建立最小事件协议，不记录 URL 查询串、页面内容或凭据。
6. 对 Cookie/bounce/CNAME 等平台差异给出明确 UI 和测试标签。

### 验证

- TypeScript 与 Swift 对全部共享向量结果一致。
- 损坏、未知版本、过期或签名失败的策略不会被静默采用。
- 钓鱼、PII、链接清洗和事件在普通/私密 Profile 上符合各自边界。
- 代表性真实网站只用于验证已声明的 WebKit 能力，不把缺失能力记为通过。

### 退出条件与产物

- 生成策略包、版本/签名记录、跨语言报告、平台差异清单和失败关闭证据。

## 7. M3：浏览器数据、下载、摘要与 companion targets（第 7–14 周）

### 目标

完成 Agent 依赖的原生浏览器工具和受限 Safari 入口。

### 步骤

1. 实现 Aegis 收藏夹稳定 UUID 树、事务批处理、差异预览和撤销日志。
2. 实现历史、搜索和明确的数据删除 UI；不自动删除用户数据。
3. 实现 URL 健康检查：无 Cookie 临时会话、`HEAD` 到有界 `GET`、逐跳 SSRF 检查。
4. 实现 `WKDownload`/受控 `URLSession`、App 管理目录、取消、重名和证据摘要。
5. 实现有界页面观察器和出站 DLP：过滤密码、OTP、支付、自定义表单、Shadow DOM 和动态
   字段，限制可见文本/节点/字节；过滤与字节门通过前只允许 fixture/local mock。
6. 将模型配置放入 Keychain，接入独立普通摘要；端点固定 HTTPS host，禁止重定向、Cookie、
   缓存、私网、DNS rebinding 和 SSRF，并覆盖 SDK 自动日志。真实模型端点在本阶段网络/DLP
   测试通过前保持关闭。
7. 打包 Shared WebExtension、Safari companion 和 Share Extension；保持相同 App 版本与签名链。
8. Safari v1 固定为当前页 R0：只允许 `page.observe`、`page.extract` 和确定性 URL 健康
   检查，不开放 click、type、navigate、下载启动或收藏夹写入，也不依赖 `browser.downloads`。
   Safari 不调用本地或远程模型，解释只使用确定性规则和固定文案。
9. 在 native app extension 进程实现 `SafariReadOnlyGate`，绑定 extension ID、
   `SFExtensionProfileKey`、tab/page/frame/Origin 和用户手势；App Group 不保存 bearer
   capability、秘密、原始页面或可重放 lease。
10. 实现实例绑定短 lease：popup port 断开、worker 新实例、扩展进程重启、跨域或权限变化时
   旧 lease 失效；Manifest 禁止 `<all_urls>` 和不必要的 `externally_connectable`。
11. 为 Share Extension 建立独立专用 Share Inbox App Group；组内只允许版本化一次性
    envelope。Extension 只接收 `public.url` 或不超过 8 KiB 的 `public.plain-text` HTTP(S)
    URL，通过随机 nonce 传递，60 秒或消费后清理；禁止文件、任意 URL scheme、Agent、模型，
    也不授予其他产品 App Group entitlement。

### 验证

- 500 条收藏夹可预览、应用并按逻辑树哈希完整撤销。
- URL 矩阵覆盖 2xx、3xx、401/403、429、404/410、5xx、NXDOMAIN、TLS、私网和
  重定向到私网。
- 下载覆盖重定向、重名、取消、MIME 不符、哈希匹配/不匹配和信息“未提供”。
- Safari 权限拒绝、扩展禁用、Private Browsing、弹窗关闭和 worker 回收均安全停止。
- 内容脚本不能绕过 background/service worker 直接获得原生权限。
- 页面直调 handler、伪造 extension/profile/tab/frame/Origin、跨 frame nonce 重放、复用旧 lease
  和读取 App Group 秘密全部失败。
- 密码/OTP/支付/自定义表单、Shadow DOM、动态改名字段和超限页面不能进入观察结果；普通摘要
  的 host 固定、重定向、Cookie/缓存、SSRF/DNS rebinding、DLP 与 SDK 日志测试全部通过。
- Safari 最终 Manifest 只含批准权限且 Private Browsing 默认拒绝；产物扫描证明没有
  click/type/navigate/download 写路由，Safari 进程无模型请求。
- Share Extension 的 UTType、8 KiB、HTTP(S)、nonce、60 秒 TTL、单次消费和清理测试通过；
  entitlement 只包含专用 Share Inbox，组内容扫描只有当前版本 envelope，无其他文件。
- 至少一台真机完成 Share → 主 App 冷/热启动、过期/重复 envelope，以及 Safari 权限拒绝、
  popup/worker/进程重启与跨域 lease 失效，结果必须为 PASS，不只是生成清单。
- 在 M4 安全门通过前，Safari 和 Aegis Browser 的 Agent 写工具均保持不可用。
- 观察器/DLP/普通摘要网络门或 companion 产物扫描任一失败时，Safari 真实页面提取和真实
  模型端点保持关闭，M3 标为 `PARTIAL`，不能以 fixture 通过替代。

### 退出条件与产物

- 收藏夹事务报告、URL fixture、下载证据、观察器/DLP 与模型网络报告、Keychain 测试、
  companion 产物扫描和 Safari/Share Extension 真机验收清单。

## 8. M4：Agent Broker、模型协议与任务 UI（第 9–16 周）

### 目标

完成“模型提议，Broker 授权、执行并验证”的平台基座。

### 步骤

1. 复用共享状态机：`Draft → Planning → AwaitingTaskConsent → Running/Reflecting →
   AwaitingActionApproval/PausedByUser/UserTakeover/Recovering/Verifying →
   Completed/Failed/Cancelled/Expired`。冷启动发现未完成写任务时进入 `Recovering`，随后转为
   `UserTakeover` 或 `Failed`，不得另建一套 iOS wire enum 或自动续跑。`unknown/needs_user`
   是 result code，分别映射到 `Verifying/UserTakeover`；“已中断”只是 `Recovering` 的 UI 标签。
2. 固定状态 I/O 矩阵：consent 前的 `Planning` 只做本地用户目标解析，不观察页面、不调用远程
   Planner、不联网、不用工具；task grant 后才允许授权内页面读取和远程 Planning。
3. 实现 `AgentPlanner` 和结构化 ToolCall；现有文本 Chat/摘要接口保持独立。
4. 拆分不可变 Task Grant、每标签/frame 的短期 document lease 和 append-only resource
   registry。Task Grant 绑定精确 `allowed_top_origins`、工具/数据/风险/预算、模型目的地、
   批准的既有 tab/download IDs、收藏夹 roots 和 `may_create/may_start/may_write`；registry
   登记任务创建的 tab/download 及当前 bookmark snapshot/plan/transaction。范围扩大必须再授权。
5. 为所有 R1 写入和 R2 动作实现一次性 action capability。公共字段绑定 task/grant/profile、
   process instance、surface、policy version、独立不超过 30 秒的 TTL、规范化参数、高影响确认值
   和调用序号；页面 target 绑定 lease/session/WebView/tab/frame/Origin/文档/节点，原生 target
   绑定 resource registry revision 与 bookmark plan/transaction、tab 或 download ID。执行前
   原子 compare-and-consume；不落盘、失败后不复用，也不为原生动作借用无关页面 lease。
6. 建立 WebKit 消息硬校验：WKWebView、隔离 content world、frame security Origin、已提交
   顶层 URL、navigation epoch 和 document nonce；nonce 不进入 DOM，节点复核与动作在同一
   隔离调用内完成。
7. 实现页面观察、有限语义节点、敏感字段过滤和动作后 ResultVerifier；无法独立验证时返回
   `unknown/needs_user`，不接受页面或模型自报成功。
8. 实现共享 R0–R3 风险、原生确认和 `UserHandoffCoordinator`。进入登录、Passkey、支付、
   最终提交、OTP、CAPTCHA、3DS 或系统 UI 时，撤销待执行能力、停止观察/Planner 并释放控制；
   返回后轮换 document lease，范围变化时重新取得 task consent。
9. 实现暂停/取消：同步增加 cancellation epoch，立即阻止新动作；模型、`URLSession`、page
   wait 在 250 ms 内收到取消并于 2 秒内结束/放弃，`WKDownload` 在 250 ms 内请求取消、最多
   等待 5 秒；不可取消的外部动作进入 `unknown` 并只读对账。
10. 实现出站 DLP、Keychain 模型端点，以及机器可验收且彼此独立的 `AuditEvent`、
   `Checkpoint`、`UndoRecord` allowlists。三者共享 Profile 加密、File Protection、默认
   不备份和无默认遥测；Audit/Checkpoint 默认 30 天，UndoRecord 默认 24 小时或消费后删除。
   只有 UndoRecord 的最小加密 inverse payload 可为精确撤销保存必要 URL query/fragment，且
   不进入预览导出、模型、系统或崩溃日志。
11. 在打开任何写工具前运行最小 P0 攻击集：参数污染、action 重放/并发、文档变化、bridge
   spoof、跨 Origin、提示注入、DLP、隐藏 fetch/XHR/GraphQL 副作用、凭据化同源 GET、重定向
   逐跳变化、history POST/form 重放、伪造成功、后台和强杀。
12. 更新 M0 威胁模型和跨进程数据流，并构建 iPad 侧栏与 iPhone 任务中心，显示计划、权限、
   当前步骤、证据和撤销入口。

### 验证

- 未知工具、未知版本、过期授权、越权 Origin、跨 Profile/Tab 重放全部拒绝。
- `Draft/Planning/AwaitingTaskConsent` 的页面观察、远程模型和其他网络请求均为 0。
- 新顶层 Origin 未经原生再授权不能继续；页面、模型和重定向不能扩大 grant。
- 每个受控标签独立轮换 document lease；跨标签 lease 重放失败。收藏夹 root/revision/事务和
  download ID 越界失败；`downloads.open` 需原生确认，带未保存状态的已有标签不能被自动关闭。
- task grant 在运行中保持字节不变；resource registry 只允许 Broker append/状态转换，跨任务
  注入、ID 复用、revision 回退和页面/模型写入全部失败。
- 页面 action capability 在跨 task/grant/Profile/lease、过期、策略切换、同任务重复、并发
  双击、参数偷换、跨 surface/session/WebView、失败、重启和跨进程重放时全部拒绝；原生动作
  对错误 registry revision、plan/transaction、tab/download ID 或伪造页面 lease 同样拒绝。
  每次执行尝试只能原子消费一次。
- 页面直调 message handler、错误 content world、伪造 frame/Origin/document nonce 和同源
  iframe 自导航重放全部拒绝。
- 导航、DOM、价格、数量或目标变化后，旧节点和旧确认全部失败。
- 使用 Cookie/凭据的同源/跨域 navigate 默认进入 R2；logout/unsubscribe/delete/confirm GET、
  重定向风险变化和 history POST/form 重放均不能绕过 capability 或用户接管。
- 模型、网页和扩展均拿不到 bearer capability、Cookie、Keychain 或任意 JS 执行能力。
- 普通 Chat 历史不进入 Agent 请求；provider/host 中途切换、URL userinfo/query/fragment、
  自定义表单值和 SDK 自动日志外泄均被 DLP 拒绝。
- 金融、医疗、政务和身份凭据 fixture 在未出现密码/OTP 字段时也禁止云模型；漏判后任何
  出站直接使测试失败。
- 用户接管期间观察器和 Planner 停止，敏感字段在普通 DOM、Shadow DOM 和动态改名后仍不出站；
  返回页面后旧 document lease/action capability 不可用，范围变化时旧 task grant 也不可用。
- 非幂等动作超时后不自动重放；`Recovering` 不自动回到 `Running`。
- 暂停/取消满足 cancellation epoch 与 250 ms/2 秒/5 秒时限；不可取消动作进入 `unknown`
  后只读对账。
- `AuditEvent/Checkpoint/UndoRecord` 分别完成正向序列化/反序列化与恢复 round-trip；各自
  allowlist/负向快照证明 DOM、截图、完整 prompt/输出、表单值和文件路径均不落盘，未知字段
  被拒绝或剥离；query/fragment 只在 UndoRecord 最小加密 payload 中 round-trip，并在 24 小时、
  撤销消费或用户清除后删除。
- 最小 P0 攻击集未经授权动作、假成功和秘密外泄均为 0。

### 退出条件与产物

- Agent Contract v1 实现、状态 I/O 矩阵、授权重放/bridge spoof 测试、DLP、确认/接管 UI、
  审计负向快照、最小攻击报告和更新后的威胁模型/数据流。
- 未通过本阶段安全门时，所有写工具必须保持编译或运行时关闭，只能继续只读确定性能力；
  不能以 feature flag 对外隐藏风险后进入 M5 或 RC。

## 9. M5：四个 Agent 工作流（第 14–22 周）

### 目标

在统一 Broker 上交付可用工作流，不为每个站点创建绕过合同的特例执行器。

### 步骤与验证

正式验收使用 M0 冻结的 48 个任务，每个工作流 12 个；对锁定的 provider/model/version/
采样参数各重复 3 次，共 144 次。通过线为：总成功率至少 90%，每工作流至少 85%，未经授权
动作、不可逆最终提交和“未验证却报告完成”均为 0。正式运行后不得替换失败任务或用同一
协议名调参；新候选必须新版本重跑。

#### 深度研究

- 实现多标签搜索、读取、来源去重、比较、引用和失败重规划。
- 用至少 10 个来源的代表性任务验证引用可核对，网页提示注入不能改变用户目标或授权。

#### 浏览器管家

- 实现标签整理、收藏夹规则去重、语义分类建议、健康标注、差异应用和撤销。
- 用 500 条混合收藏夹验证预览与回滚；疑似失效项只能进入“待确认”。
- 用 60 个混合标签验证分组计划、顺序和 grouped undo；撤销后的 Tab UUID、顺序与分组逻辑
  哈希一致，自动整理关闭的已有标签数为 0。

#### 安全下载

- 实现官方来源选择、平台/架构识别、下载候选检查和可用签名/哈希核对。
- 用 macOS/iOS/Windows/Linux、多架构、重定向和缺失元数据 fixture 验证选择及“未提供”状态。

#### 购物助手

- 实现商品、卖家、规格、数量、价格、配送与退货比较，加购和结算预览。
- 使用 sandbox/fixture 验证：最终提交前停止；商家、价格、数量、费用或订阅状态变化后
  旧确认失效；密码、支付、OTP、CAPTCHA 和 3DS 始终由用户处理。

### 退出条件与产物

- 四个端到端任务证据包、144 次运行汇总、失败样例、引用报告、撤销报告、下载证据和购物
  接管录像；结果按整体、每工作流、假成功和安全违规分别报告。
- 另用 20 个当前公开站点做时点烟测，外部阻断与产品失败分开；不能替代冻结 fixture。
- Safari companion 不继承上述完整能力，只保留当前页 R0 提取、解释和确定性 URL 检查。

## 10. M6：攻击、生命周期、性能与真机矩阵（第 21–27 周）

### 目标

在 M4 最小安全门基础上扩大恶意站点、设备、网络和性能覆盖；M6 不是第一次检查写工具安全。

### 步骤

1. 固化提示注入语料：可见文字、隐藏 DOM、ARIA、OCR、搜索结果、跨域 iframe、
   WebMCP/扩展消息和恶意工具返回。
2. 测试 TOCTOU 与参数污染：确认后替换节点、href、form action、商家、收件人、价格、数量、
   目标地址和 URL 参数；确认值必须由 Broker 重新读取并规范化。
3. 测试导航副作用：带 Cookie 的同源 logout/unsubscribe/delete/confirm GET、跨域及同源
   redirect 风险变化、history POST/form 重放和认证状态变化。
4. 测试秘密：Cookie、密码、OTP、卡号、CVV、API Key、文件路径和已填表单不得出站。
   同时覆盖金融、医疗、政务和身份凭据页面在没有明显敏感字段时仍默认禁云。
5. 测试网络：端点重定向、DNS rebinding、私网 IP、IPv6-only、Wi-Fi/蜂窝切换和离线。
6. 测试状态：同 URL 重载、BFCache、SPA、跨域 frame、标签关闭、Profile 切换、锁屏、
   后台、WebContent 终止、强杀、内存压力和设备旋转。
7. 测试普通 click 经 `fetch`/XHR/GraphQL 产生无导航副作用、页面/工具伪造成功、外部动作
   结果未知、重复调用、预算耗尽、模型循环和 schema 炸弹。
8. 建立 iPhone/iPad、最低系统/当前系统和代表性能档位矩阵。

### 验证

- 固定攻击语料中未经授权动作数为 0。
- 任何秘密均不出现在观察结果、模型请求、审计、日志或崩溃记录。
- 旧文档、旧节点、旧确认和跨任务 token 重放全部失败。
- 高影响参数无法独立读取或结果无法独立验证时，必须进入 `unknown/needs_user`，不得假成功。
- 后台、锁屏和强杀后无静默写操作；结果未知时先对账，不盲重试。
- 任务步骤、内存、耗电、网络和模型成本达到 M0 锁定预算，超限时可暂停和解释。

### 退出条件与产物

- 攻击矩阵、隐私流量证据、生命周期报告、性能报告、剩余风险和明确 No-Go 项。

## 11. M7：当前源码 RC 与发布准备（第 27–32 周）

### 目标

从冻结的当前源码生成可追溯内部 RC，并把发布准备与发布授权分开。

### 步骤

1. 冻结候选源码、依赖、生成策略、Agent Schema、模型适配和测试语料版本。
2. 从干净环境重跑合同、Swift/JS、XCTest、XCUITest、安全、真机与性能矩阵。
3. 生成 Archive，记录 commit、配置、SDK、资源哈希、二进制、entitlement 和 Privacy Manifest。
4. 完成 VoiceOver、Dynamic Type、本地化、权限说明、数据导出/删除和崩溃恢复复核。
5. 形成 App Store 隐私标签、出口合规、第三方 SDK、模型提供商和地区能力清单。
6. 核对默认浏览器 managed entitlement：未获得外部提交授权时标为
   `BLOCKED_BY_AUTHORIZATION`；已提交但未获批时标为 `PARTIAL`，由用户明确决定延期还是
   降级为普通浏览器发布。
7. entitlement 获批后，在 RC 真机完成系统默认浏览器选择、HTTP(S) 冷/热启动、前后台、
   多 Scene、来源 App 跳转和崩溃恢复矩阵；缺失此证据不能宣称默认浏览器目标完成。
8. 在 RC Archive 对 Safari/Share entitlement、Manifest、target membership、写路由和专用
   Share Inbox 内容做最终扫描，并重跑 Share → 主 App 冷/热启动、TTL/重复消费真机矩阵。
9. 只在获得单独授权后进行正式签名、TestFlight 或 App Store 提交。

### 验证

- 当前源码身份能对应到测试、真机、Archive 和安装产物。
- 安装后的代表性端到端结果与候选源码一致，而不是只证明 App 能启动。
- Debug、内部 RC、正式签名、TestFlight 和 App Store 状态分别报告。
- 所有 entitlement、隐私、许可证和平台差异都有负责人和关闭证据。
- 默认浏览器状态同时包含 Apple entitlement、系统设置可选、代表来源 App 路由和当前 RC
  身份证据；只有材料或审批回执不算功能通过。

### 退出条件与产物

- RC 身份清单、测试总报告、真机矩阵、Archive 哈希、隐私与发布准备清单。
- 未获得正式发布授权时，状态保持“内部 RC / 未发布”。

## 12. 持续测试矩阵

### 12.1 自动化层

- Swift 单元测试：策略、收藏夹事务、URL 判定、Grant、风险、审计和恢复。
- Schema/黄金向量：TypeScript 与 Swift 100% 一致，未知输入 fail closed。
- 状态 I/O：consent 前零页面/远程出站，Recovering 不自动运行，结果码到 wire state 映射固定。
- WebExtension JS harness：观察、节点引用、消息路径、权限拒绝和 worker 回收。
- WebKit 集成测试：导航、frame、document nonce、下载和 WebContent 终止。
- XCUITest：iPhone/iPad 浏览、任务中心、确认、接管、撤销和错误状态。
- 安全 fixture：提示注入、SSRF、秘密外泄、TOCTOU、重放和预算攻击。
- 持久化 Schema：AuditEvent/Checkpoint/UndoRecord 分别做正向 round-trip 和负向快照；canary
  secret 与禁止字段不会进入任一对象、系统或崩溃日志。含 query/fragment 的收藏夹可以由
  加密 UndoRecord 精确恢复，且 TTL/消费/清除测试证明不会超期保留或进入导出。
- 接管 fixture：登录、Passkey、Apple Pay、最终提交、订阅、退款、OTP、CAPTCHA、3DS 和
  系统权限 UI，验证观察/Planner 停止及返回后重新授权。

### 12.2 真机层

- 设备：至少一台最低性能支持设备、一台当前 iPhone 和一台 iPad。
- 系统：最低部署版本与当前正式版本；候选系统单列，不替代正式版本。
- 网络：Wi-Fi、蜂窝、IPv6-only、切换、离线、限速和证书失败。
- 生命周期：前后台、锁屏、强杀、重启、WebContent 终止和内存压力。
- Safari：权限允许/拒绝、禁用扩展、Private Browsing、跨域和 worker 回收。
- 高风险流程：Passkey、Apple Pay sandbox、CAPTCHA、3DS 和 OTP 只验证用户接管。

Safari WebExtension 的 JavaScript API 和 Safari UI 不能只依赖 XCTest 声称覆盖；保留独立
JS harness 与真机人工验收清单。

## 13. 硬性 No-Go 条件

发现以下任一项，停止提升里程碑状态并修复后重验：

- 任意 JS/CDP/文件系统工具可被模型或页面调用。
- `Draft/Planning/AwaitingTaskConsent` 阶段发生页面观察、远程 Planner 或其他网络出站。
- 未授权 Origin、frame、Profile、标签或过期 grant 能成功执行。
- action capability 缺少公共 task/grant/Profile/policy/TTL 字段或正确的页面/原生 target binding，
  或可重复/并发消费、参数偷换、跨进程/会话/WebView 重放、过期/策略切换后使用或失败后复用。
- 不可变 task grant 在运行中被修改，或 resource registry 可被页面/模型写入、跨任务注入、
  复用 ID、回退 revision。
- 页面能伪造 WebKit handler、content world、frame/Origin 或 document nonce 身份。
- 凭据化或副作用未知的 `page.navigate/page.history` 未经 R2 capability 执行，重定向未逐跳
  重分类，或 history 静默重放 POST/form。
- 提示注入能新增工具、提升风险、改变预算或绕过确认。
- 凭据、Cookie、OTP、支付信息、完整页面或敏感 URL 出现在出站或持久日志。
- 金融、医疗、政务或身份凭据页面能调用云模型，即使尚未出现明显敏感字段。
- Private Profile 能启动 Agent/模型、复用普通 Profile 扩展状态或创建持久任务/审计。
- 页面变化后旧节点、价格或确认仍可提交。
- 页面/工具能伪造成功，或普通点击产生未分类的隐藏网络副作用。
- 用户接管时观察、Planner 或待执行能力仍在运行，或 Agent/合成事件能完成登录、Passkey、
  最终下单、支付、订阅、退款、OTP、CAPTCHA、3DS 或系统权限确认。
- 写操作在后台、锁屏、强杀或结果未知后自动恢复或重试。
- `Recovering` 自动回到 `Running`，暂停/取消后仍产生新 I/O，或取消时限未满足且未进入
  `unknown` 对账。
- 收藏夹批处理不能完整撤销，或疑似失效项被自动删除。
- Safari 依赖未公开 API、原生书签写入、`browser.downloads` 或常驻后台。
- Safari 最终 Manifest/产物含超额权限或写路由，或 Share Extension 接收文件/任意 scheme、
  启动 Agent/模型、拥有专用 Share Inbox 之外的 App Group entitlement、写入 envelope 之外
  的文件、复用/超时保留 envelope。
- AuditEvent/Checkpoint/UndoRecord/系统或崩溃日志包含各自 allowlist 外的敏感字段，三套
  Schema 被合并，合法恢复/撤销记录无法 round-trip，或 UndoRecord URL 原值未加密、超范围、
  超过 24 小时/消费后保留、进入导出或其他日志。
- entitlement、最低系统、Archive 身份或 Privacy Manifest 无法从当前源码复现。

## 14. 汇报与变更控制

每个里程碑用同一格式汇报：

```text
结论：PASS / PARTIAL / BLOCKED / NO-GO
完成：本阶段实际交付
验证：测试、模拟器、真机、产物与身份
未完成：明确缺口，不用计划项代替完成项
风险：最多 3–4 个最高优先级问题
下一步：进入下一阶段或回到具体修复项
发布状态：未签名 / 内部 RC / TestFlight / App Store
```

范围变化必须更新上位架构、Agent 合同、威胁模型、测试矩阵和排期。不得只在 UI 或 Roadmap
中勾选完成；代码、运行时和产物证据必须一致。
