# GCSA-aegis iOS 产品架构与 Aegis Agent v1 整合方案

- 版本：Project Charter v1.0
- 日期：2026-08-28
- 状态：**PROJECT_APPROVED / 已正式立项**
- 立项决策：取消“WebKit 浏览器 + 同一套源 WebExtension”的独立真机垂直切片和单独
  Go/No-Go 门，直接进入完整产品开发
- 证据边界：已批准产品范围、架构和开发路线；本文件不代表 iOS 产品代码、真机构建、签名、
  TestFlight 或 App Store 发布已经完成
- 授权归属：本次批准只作用于 iOS Profile 及其所需的共享合同；桌面 Agent 运行时仍保持
  `PLAN_ONLY`，不因本文件自动进入开发
- 执行计划：[GCSA-aegis iOS 项目详细开发执行计划](./ios-project-execution-plan-2026-08-28.md)
- 桌面 Agent：[实施方案](./aegis-browser-agent-v1-implementation-plan-2026-08-28.md) / [开发执行计划](./aegis-browser-agent-v1-development-execution-plan-2026-08-28.md)

> **2026-08-28 实施状态更新：** `apps/ios`、共享 Agent Contract 与本地确定性 Agent 工作流已进入源码，
> 并完成 iPhone/iPad Simulator 范围的硬化复验；当前事实与剩余门禁以
> [iOS Simulator 硬化验收记录](./audit/ios-simulator-hardening-2026-08-28.md)为准。本文件仍是
> Project Charter，不代表真机、正式里程碑退出、RC、签名或发布已经完成；项目仍为 release No-Go。

## 0. 立项结论

GCSA-aegis iOS 版按独立 WebKit 产品正式立项，并把 Aegis Agent 作为首版一级能力整合，
不另建一个孤立的“AI App”或恢复独立 Extension 产品线。

首版包含两个能力面，但能力不等价：

1. **Aegis Browser**：完整 Agent 产品面，覆盖研究、浏览器管家、安全下载和购物助手。
2. **Safari Web Extension**：随 iOS App 同版本打包的受限入口，只处理用户主动授权的当前
   标签页和 R0 只读提取、解释与确定性 URL 检查。

跳过垂直切片只取消独立 POC 的决策门。M0 仍需建立工程和合同基线，并用本地开发签名完成
最小安装/启动冒烟；从首个可运行功能里程碑 M1 起，逐阶段执行模拟器、真机、生命周期、
安全和发布前验证。任何未通过的硬门都不能用“项目已立项”替代。

本次立项允许后续从 M0 开始进行本地源码开发和测试，但不授权正式签名、TestFlight、
App Store 提交、线上部署、生产密钥或真实交易。

立项时 [Roadmap](./roadmap.zh-CN.md) 和 [Architecture](./architecture.zh-CN.md) 只描述 Chromium
产品现状；本文件当时记录已批准但尚未实现的 iOS 项目。当前 `apps/ios` 与总览文档已建立并
同步到 Simulator 实现边界，但不得据此把 iOS 写成真机合格、RC 或已交付产品。

## 1. 目标、假设与完成标准

### 1.1 产品目标

- 在 iPhone 和 iPad 提供由 Aegis 自己控制的隐私浏览器，而不是 Safari 的外壳。
- 复用现有 Core 的钓鱼、PII、链接清洗、策略快照和测试向量语义。
- 让模型只提出计划和类型化工具调用，由原生 Broker 决定授权、执行和结果。
- 支持深度研究、收藏夹整理与失效链接检查、安全下载、商品比较与结算准备。
- 对所有页面内容、扩展消息、模型输出和站点工具实行“不可信输入”原则。
- 将源码、测试、真机、Archive、签名、TestFlight 和 App Store 证据分别记录。

### 1.2 锁定假设

- 产品形态：原生 SwiftUI/UIKit 外壳 + `WKWebView`/WebKit。
- 设备：iPhone 与 iPad；最低系统暂定 iOS 18.4。
- 市场：面向全球 App Store，隐私文案、权限和地区能力需独立审查。
- 默认浏览器：首版发布目标包含成为系统可选默认浏览器；M0 准备 Apple managed
  entitlement 申请材料和专用功能核对，实际提交属于外部动作，需用户单独确认。
- 扩展：WebExtension/Share Extension 只能作为 `apps/ios` 内的 companion target 随 App
  打包，不拥有独立版本、独立发布或独立产品叙事。
- Agent：只控制 Aegis App 管理的标签页；Safari 侧只控制用户当前授权的页面。
- 私密 Profile：继续启用确定性的本地浏览保护，但 iOS v1 禁用 Agent、远程模型、任务恢复
  和持久审计，不提供“本地模型例外”。
- 生命周期：网页交互任务只在前台执行；后台、锁屏、页面失效或进程终止时暂停并撤销授权。
- 模型：远程模型必须由用户配置并在发送前显示目的地和脱敏摘要；没有模型时，确定性安全
  能力仍可使用。

最低系统和商店范围可在 M0 复核后收紧，但不能在不重做兼容性和权限验收的情况下放宽。
M0 同时核对默认浏览器资格、WebExtension、App Group、Keychain Group、Associated Domains
等 entitlement 和商店要求。未获外部提交授权时状态记为 `BLOCKED_BY_AUTHORIZATION`；已经
提交但 RC 时仍未获批时记为 `PARTIAL / 默认浏览器资格未完成`。两种情况都由用户明确决定
延期还是降级为普通浏览器发布；不得静默缩减范围、提前宣称支持，或用私有 API/未授权
entitlement 补齐。

参考：[准备成为默认浏览器](https://developer.apple.com/documentation/xcode/preparing-your-app-to-be-the-default-browser)。

### 1.3 总体完成标准

项目只有同时满足以下条件才可称为 iOS RC：

- Aegis Browser 的浏览、隐私策略、收藏夹、下载和四个 Agent 工作流达到执行计划中的验收线。
- Safari companion 在拒绝权限、禁用扩展、Private Browsing 和后台回收时安全失败。
- TypeScript 与 Swift 对版本化合同和黄金向量的结果一致。
- 固定提示注入与越权语料中，未经授权的动作数为 0。
- iPhone、iPad、最低系统和当前系统完成真机生命周期与网络矩阵。
- 当前源码可重复生成 Archive，并有独立身份、隐私、签名和发布准备证据。

## 2. 产品拓扑与代码边界

```text
GCSA-aegis/
├── apps/browser/                 Chromium 桌面产品
├── apps/ios/                     WebKit iPhone/iPad 产品
│   ├── AegisApp/
│   ├── BrowserKit/
│   ├── AegisPolicyKit/
│   ├── AgentKit/
│   ├── SharedWebExtension/
│   ├── SafariWebExtension/       随 App 打包的受限 companion target
│   ├── ShareExtension/
│   └── Tests/
└── packages/core/                构建期策略、Schema 与跨平台测试向量来源
```

约束如下：

- `apps/browser` 与 `apps/ios` 是两个产品运行时，不互相嵌入。
- iOS 不直接运行 TypeScript Core；构建过程生成版本化 JSON 资源和黄金向量，由 Swift 实现
  等价行为。
- Agent 合同优先放在 `packages/core/src/agent/` 或版本化 Schema 目录，避免仅为合同新增一个
  无必要的 pnpm 包。
- 历史独立 `apps/extension`、`@gcsa-aegis/extension`、独立扩展构建和独立发布入口继续禁止。
- `SharedWebExtension` 表示复用同一套页面观察与窄执行资源，不表示 Aegis Browser 与 Safari
  拥有相同权限。
- `ShareExtension` 首版只接收 `public.url` 或不超过 8 KiB 的 `public.plain-text` HTTP(S)
  URL，经独立专用 Share Inbox App Group 中的一次性 envelope 交给主 App；该组不存放
  Profile、Safari、审计或其他产品数据。Extension 不接收文件、不启动 Agent/模型，envelope
  在 60 秒或消费后删除。

当前仓库合同仍以 `apps/browser + packages/core` 为 JavaScript workspace，同时已演进为
“集成式浏览器产品拓扑合同”：`scripts/check-repo-contracts.mjs` 会识别纯 Xcode 的
`apps/ios`，检查工程、targets、schemes、部署版本和共享合同/黄金向量入口；iOS 不进入 pnpm
workspace。生成资源与 Swift/TypeScript 语义仍需由各自测试和发布前身份门继续验证。

## 3. iOS 总体架构

```text
SwiftUI / UIKit UI
        │
BrowserShell ─── Tabs / History / Bookmarks / Downloads / Profiles
        │
AegisPolicyKit ─── 生成策略、钓鱼、PII、链接清洗、事件
        │
AgentCoordinator / Planner
        │  只产生计划和类型化 ToolCall
        ▼
AegisAgentBroker
  ├── Task Grant 与一次性动作能力
  ├── Profile / Tab / Document / Origin 绑定
  ├── 风险分级、用户确认与出站 DLP
  ├── 步骤、时间、流量和费用预算
  ├── 审计、暂停、撤销与崩溃恢复
  └── ResultVerifier
        │
        ├── WebKitActionAdapter ─── WKWebView / SharedWebExtension
        └── NativeTools ────────── 收藏夹、URL 检查、下载、标签页
```

模型、网页和扩展均不能直接获得 `WKWebView`、`evaluateJavaScript`、Cookie、Keychain、
文件系统或原生消息桥。Broker 是唯一授权主体，执行器只接受经过校验的窄合同。

### 3.1 与桌面 Agent 的关系

桌面与 iOS 共享：

- 任务状态机、工具语义、Schema、风险等级、确认摘要、审计字段和黄金向量。
- 深度研究、浏览器管家、安全下载、购物助手四个产品工作流。
- “模型提议，浏览器授权、执行并验证”的信任边界。

iOS 不复用：

- Chromium Actor 二进制、裸 CDP、`RenderFrameHost`、桌面下载服务或桌面 UI。
- V8/Blink 注入、渲染器级脚本阴影能力和桌面持续运行假设。

桌面 `ActorBridge` 在 iOS 映射为 `WebKitActionAdapter`；桌面侧栏在 iPad 映射为侧栏，在
iPhone 映射为全屏或底部任务中心。两个 Profile 独立实现和验收，任何桌面通过结果都不能
作为 iOS 运行时证据。

共享合同以桌面方案当前定义的 canonical wire format 为基线：字段名使用 `snake_case`，
风险等级使用 `R0–R3`，状态机使用相同枚举。Swift 可以提供符合平台习惯的属性包装，但
序列化合同不能另起一套。iOS 只实现工具子集；新增通用工具时必须先更新共享 Schema 和
两端黄金向量，不能在 iOS 内私自同名异义。

## 4. 能力迁移边界

### 4.1 高复用语义

- 钓鱼检测、PII 脱敏、链接跟踪参数清理和风险分类。
- 策略快照、更新签名、事件 Schema、共享测试向量和失败码。
- Agent ToolCall、Grant、Confirmation、Audit 与 Result 的版本化合同。
- 研究引用、安全下载证据和购物确认摘要的产品规则。

### 4.2 iOS 原生重写

- 窗口、标签页、地址栏、返回前进、恢复、私密 Profile 与 iPhone/iPad UI。
- WebKit 导航、文档身份、页面观察、节点执行和 WebContent 进程恢复。
- 收藏夹、历史、下载、Keychain、生命周期、系统分享和权限 UI。
- Agent Broker、确认界面、审计存储、远程模型网络层和任务中心。

### 4.3 降级或后置

- Cookie/bounce/CNAME 防护按 WebKit 可见面降级，并在 UI 和测试中明确差异。
- Metalink、复杂断点续传和跨设备任务恢复后置。
- Safari 原生收藏夹只支持用户导出后的显式导入，不承诺实时遍历、移动或删除。

### 4.4 iOS v1 明确不支持

- Blink 指纹扰动、V8 shadow、裸 CDP、本地调试端口或任意 JavaScript 工具。
- Torrent、Magnet、通用媒体抓取和任意安装。
- 模型读取 Cookie、密码、银行卡、CVV、OTP、钱包助记词或文件内容。
- 自动付款、下单、退款、订阅、发送消息、发帖、CAPTCHA 或 3DS 绕过。
- 关闭 App 后持续控制网页，或依靠后台任务伪装常驻 Agent。

## 5. Agent Contract v1 — iOS Profile

### 5.1 首版工具集合

```text
browser.tabs.list / browser.tabs.create / browser.tabs.activate / browser.tabs.close
browser.tabs.group
bookmarks.list / bookmarks.plan / bookmarks.check_urls / bookmarks.apply / bookmarks.undo
page.observe / page.extract / page.navigate / page.click / page.type
page.select / page.scroll / page.wait / page.history
downloads.list / downloads.start / downloads.pause / downloads.resume
downloads.cancel / downloads.verify / downloads.open
```

购物工作流首版组合 `page.observe`、`page.extract` 与受控页面动作，不增加可直接提交交易的
通用工具。`monitor.*` 因 iOS 后台限制不进入 iOS v1；任务暂停和取消属于状态机控制，不作为
网页可调用工具。深度研究依赖 `browser.tabs.*`，因此它是 Aegis Browser 的必需工具组，
Safari companion 不提供。

`browser.tabs.group` 属于 R1：先预览标签到组与顺序的变化，执行后产生 grouped undo；自动
整理不关闭已有标签。`browser.tabs.close` 只可关闭任务自己创建或用户逐项批准的标签。

不提供 `page.eval`、任意 CSS/XPath、通用文件系统、Cookie 导出、任意上传、坐标点击或
绕过浏览器/系统 UI 的工具。

### 5.2 授权对象

授权使用原生内存中的随机不透明句柄，模型和网页只看到可引用 ID，不得到 bearer token。
范围授权与页面身份拆成两个对象。

不可变 `task_grant` 记录用户批准的任务范围：

```text
task_id / grant_id / surface / profile_id
allowed_top_origins / allowed_frame_origins
allowed_tools / data_classes / risk_ceiling
max_steps / time_budget / byte_budget / cost_budget
tab_scope { approved_existing_tab_ids / may_create_tabs }
bookmark_scope { root_ids / may_write }
download_scope { approved_existing_ids / may_start_downloads }
expires_at / policy_version / model_version
model_destination { provider / exact_https_host / purpose / data_classes / max_request_bytes }
```

每个受控标签/frame 另有短期 `document_lease`：

```text
lease_id / task_id / grant_id / profile_id / process_instance_id / browser_session_id
web_view_id / tab_id / frame_id / committed_top_origin / frame_origin
navigation_epoch / document_nonce / call_sequence / expires_at
```

Task Grant 只能在 `AwaitingTaskConsent` 经原生 UI 确认后签发，并推动任务进入 `Running`。
`allowed_top_origins` 是用户事先看到的精确集合；导航或重定向到集合外 Origin 时停止，只有
原生 Broker 在再次确认后才能签发新版 task grant，模型、页面、扩展和工具结果均不能签发。
范围内导航只轮换对应标签/frame 的 document lease，不改变 task grant；每个受控标签都有
独立 lease。已有标签或下载的静态 ID 必须由用户明确批准；grant 只声明是否允许创建新标签或
启动新下载，不保存运行中增长的资源 ID。

Broker 另维护绑定 `task_id/grant_id/process_instance_id` 的 append-only resource registry，
登记任务实际创建的 tab/download ID，以及收藏夹 snapshot revision、plan ID 和 transaction ID。
资源关闭、取消或完成只改变状态，不复用 ID；页面和模型不能写 registry。扩大到新的既有资源
必须重新取得 task consent，任务自己创建的资源可按静态 `may_*` 范围登记。

收藏夹写入必须匹配批准的 root 和 registry 中当前 snapshot/plan/事务；下载工具只能操作任务创建或用户
明确批准的 download ID。`downloads.open` 需要原生即时确认或用户接管。已有标签存在未保存
表单/编辑状态时，`browser.tabs.close` 必须拒绝并交给用户。

所有 R1 写入和所有 R2 动作另用不落盘、绑定 `process_instance_id` 的一次性
`action_capability`。其 `action_digest` 公共部分必须覆盖 `task_id`、`grant_id`、`profile_id`、
`policy_version`、`expires_at`、规范化工具名和参数、surface、调用序号，以及适用时的商家、
收件人、商品、数量、币种、金额和 `confirmation_digest`。目标使用判别联合：

- 页面动作绑定 `document_lease`、session/WebView/tab/frame/Origin、文档摘要和节点指纹。
- 原生动作绑定 resource registry revision，以及 bookmark plan/transaction、tab ID 或 download ID。

原生动作不得伪造或借用无关页面 lease。能力独立 TTL 最长 30 秒；页面动作 TTL 还不得超过
document lease，所有能力都不得超过 task grant。
Broker 在执行尝试前进行原子 compare-and-consume；并发双击只能有一个成功，失败、超时、
取消、参数或策略变化、进程重启或结果未知后均不得复用或自动重放。只有
`AwaitingActionApproval` 经原生确认后能签发该能力。

导航、BFCache 恢复、关键 SPA 变化、WebContent 进程切换、标签关闭、切换 Profile、App
进入后台或设备锁定时，旧 document lease 和动作能力必须失效。进程重启后只恢复脱敏任务
元数据，不恢复任何 lease、动作能力、凭据或待执行写操作。

### 5.3 状态与 I/O 权限

共享 wire 状态机不新增 iOS 私有状态，但每个状态允许的 I/O 固定如下：

- `Draft`：只接收本地用户目标。
- `Planning`：同意前只允许本地确定性解析目标和生成作用域草案；不得观察页面、调用远程
  Planner、发送网络请求或使用浏览器工具。
- `AwaitingTaskConsent`：原生 UI 显示 Origin、页面读取、工具、数据类别、provider/host、
  脱敏摘要和预算；仍不得出站。
- `Running/Reflecting`：task grant 签发后，才允许在授权范围内读取页面、调用远程 Planner、
  执行 R0，并生成/预览 R1 变更计划；任何 R1 写入和 R2 动作都进入
  `AwaitingActionApproval`。
- `AwaitingActionApproval`：可读取当前状态用于确认，不执行目标动作；确认后签发一次性能力。
- `PausedByUser/UserTakeover`：立即阻止新页面观察、Planner 和工具调用，只允许用户 UI。
- `Recovering`：不得自动回到 `Running`；只能进入 `UserTakeover`、`Failed` 或 `Cancelled`，
  用户要求继续时重新进入 task consent 并签发新 grant/lease。
- `Verifying`：只做范围内只读对账，不产生新的外部副作用。
- `Completed/Failed/Cancelled/Expired`：不允许页面、模型或工具 I/O。

`needs_user` 是工具结果码并映射到 `UserTakeover`；`unknown` 是结果码并映射到 `Verifying`，
之后只能进入 `UserTakeover` 或 `Failed`，不能直接 `Completed`。“已中断”只是重启后的 UI
标签，对应 `Recovering`，不是新的 wire state。任何 task consent 前页面读取或模型出站直接
No-Go。

### 5.4 固定执行链

```text
Schema 校验
→ 平台能力检查
→ 任务与 Profile 授权检查
→ Origin / Document / Node 新鲜度检查
→ 风险分类和预算检查
→ 必要时显示原生确认
→ 核对 action_digest 并原子消费一次性动作能力
→ 执行动作
→ 重新观察并验证结果
→ 写入最小审计或生成撤销记录
```

非幂等动作失败、超时或结果未知时不得盲目重试；必须先查询可见结果或交给用户处理。

### 5.5 风险等级

- **R0 只读**：页面观察、钓鱼解释、单个 URL 检查。任务内可执行。
- **R1 本地可撤销**：收藏夹改名、移动、分类。先显示差异，后事务应用并提供撤销。
- **R2 外部或敏感**：普通字段输入、明确语义点击、加购、启动下载。动作时确认。
- **R3 财务、法律或公开**：登录提交、上传、发帖、下单、订阅、支付、退款。iOS v1
  交还用户。

普通 `click` 不固定属于低风险。目标语义不明、坐标操作、提交控件或可能触发隐藏网络写入
时，Broker 必须升级风险或拒绝。

`page.navigate` 和 `page.history` 也不天然只读。使用现有 Cookie/凭据的导航默认 R2，同源也
一样；只有 Broker 通过无 Cookie、无凭据、独立只读通道证明请求无副作用时才能降为 R0。
每次重定向逐跳重新分类；logout、unsubscribe、delete、confirm 等凭据化 GET，以及可能重放
POST/form 的 history entry 必须确认或用户接管，绝不静默重放。

## 6. 页面、注入与秘密边界

### 6.1 文档和节点身份

- 每次顶层导航生成新的 `navigationEpoch + documentNonce`。
- 节点引用绑定 frame/document、node ID、角色、可见名称、关键属性摘要和 DOM revision。
- 消息 handler 只注册在隔离 content world；`documentNonce` 不写入 DOM，也不暴露给页面脚本。
- 每条 WebKit 消息必须同时核对 WKWebView 身份、content world、frame security Origin、已提交
  顶层 URL/Origin、navigation epoch 和 document nonce；`WKFrameInfo` 只作当次校验，不能
  单独充当稳定 frame 身份。
- 节点复核与动作在同一次隔离调用中完成；目标、链接、表单 action、价格或数量变化时返回
  `stale_document`，动作后再由独立 ResultVerifier 观察结果。
- 首版只支持主文档和同源 frame；跨源 frame 需要独立授权，否则交还用户。
- `data:`、`blob:`、不透明 origin、自定义 scheme 和内部页面默认拒绝。
- `WKContentWorld` 只隔离 JavaScript 命名空间，不能被当作 DOM 副作用或权限隔离层。

参考：[WKContentWorld](https://developer.apple.com/documentation/webkit/wkcontentworld)。

### 6.2 提示注入

网页文字、隐藏 DOM、ARIA、OCR、搜索结果、扩展消息、WebMCP 描述和工具返回值全部标记为
不可信数据。只有用户目标和原生策略能授予权限。

- 页面不能新增工具、扩大 Origin、提高风险上限、改变预算或要求泄露秘密。
- 模型只能选择 Broker 注册的类型化工具；未知工具、字段和版本一律拒绝。
- 每个动作后重新观察，不能连续消费旧快照。
- 商家、收件人、商品、数量、金额、URL 等高影响参数由 Broker 从当前页面/原生状态重新读取、
  规范化并生成确认，不能照抄模型或页面给出的值。
- 普通点击若可能通过 `fetch`、XHR、GraphQL 或表单产生写入，按真实副作用升级或拒绝。
- 页面和工具返回的“成功”不改变任务终态；无法独立验证时返回 `unknown/needs_user`。
- 分隔符、提示词和模型自报安全不能替代确定性授权。

### 6.3 模型和数据

现有文本摘要能力继续独立；新增 `AgentPlanner`，不得把普通 Chat 接口直接当工具调用接口。

- API Key 存入 Keychain；端点固定 HTTPS host、禁止重定向、Cookie 和缓存，并防御私网、
  DNS rebinding 与 SSRF。
- 远程模型只接收任务所需的裁剪可见文字、角色和交互节点；发送前展示目的地和脱敏摘要。
- Task Grant 精确绑定 provider、HTTPS host、用途、允许数据类别和单请求最大字节；任务中途
  不能切换 provider/host，普通 Chat 历史不得自动并入 Agent 请求。
- 不发送完整 HTML、Cookie/Storage、URL userinfo/query/fragment、密码、自定义或已填表单、
  文件路径或默认截图；模型 SDK 的自动日志和崩溃附件使用同一 DLP。
- Private Profile 完全不进入 Agent；普通 Profile 中的金融、医疗、政务和身份凭据页面默认
  禁用云模型。
- iOS 26+ 可选 Apple Foundation Models，但运行时能力必须检测，且不能成为唯一路径。

本地模型也不因此获得读取秘密、扩大工具或绕过确认的权限。

### 6.4 用户接管

登录、Passkey、Apple Pay、最终下单、订阅、退款、OTP、CAPTCHA、3DS、系统权限提示和
文件选择统一进入 `UserHandoffCoordinator`。进入接管时撤销所有待执行 action capability，
停止 Planner 和页面观察，释放页面控制权；用户完成或取消后必须重新观察，并由 Broker 根据
新文档和状态签发新 document lease；只有范围变化时才重新取得 task consent 和 task grant，
不能沿用旧页面上下文。

观察器必须按语义、HTML input type、系统 AutoFill 标记、Shadow DOM 和动态属性变化过滤
敏感字段；密码、passkey、OTP、银行卡、CVV 和系统授权结果的值永不进入节点观察、模型上下文
或审计。Agent 或 JavaScript 合成事件能够完成上述最终动作时直接 No-Go。

## 7. 四个 Agent 工作流

### 7.1 深度研究

- 在 Aegis Browser 中跨标签页搜索、读取、去重、比较并生成可核对引用。
- 引用必须保存标题、来源、访问时间和与结论对应的摘录摘要。
- 站点登录、CAPTCHA、权限提示或跨域高风险操作时暂停并交还用户。
- Safari companion 只提取当前授权页信息，不执行自主多站研究。

### 7.2 浏览器管家

- Aegis 收藏夹使用稳定 UUID 树；先规则化 URL、清理追踪参数、精确去重和健康标注。
- 模型只提出语义分类建议；用户看到完整差异后才事务应用，并能一键撤销。
- 重复或疑似失效项移动到“待确认”，不自动删除。
- URL 检查使用无 Cookie、无凭据、无 Referer、无缓存的临时 `URLSession`，先 `HEAD`，
  必要时回退到有字节预算的 `GET`。
- 每次重定向重新检查目标，拒绝 loopback、私网、链路本地、`.local` 和带 userinfo 的 URL。
- AI 只解释结果，不决定 HTTP、DNS、TLS 或失效事实。
- Safari 原生收藏夹不做实时写入；如导入用户主动导出的 Safari 数据，只解析书签文件，忽略
  密码与支付卡数据。

参考：[导入 Safari 数据](https://developer.apple.com/documentation/safariservices/importing-data-exported-from-safari)。

### 7.3 安全下载

- Aegis Browser 使用 `WKDownload`/`WKDownloadDelegate` 或受控 `URLSession`。
- 保存位置由 Broker 选择到 App 管理目录，模型不能指定任意路径。
- 记录最终 URL、MIME、文件名、大小、SHA-256，以及发布者实际提供的签名或哈希；缺失项
  显示“未提供”。
- Safari companion 只做候选检查，然后由用户正常下载或“在 Aegis 中打开”，不依赖
  `browser.downloads`。

参考：[WKDownloadDelegate](https://developer.apple.com/documentation/webkit/wkdownloaddelegate)。

### 7.4 购物助手

- 支持报价提取、商品比较、规格与数量选择、加入购物车和结算预览。
- 确认摘要覆盖商家、域名、商品、型号、数量、币种、税费、运费、总额和订阅状态。
- 任一字段或文档身份变化后，旧确认立即失效。
- 密码和支付字段只由用户或系统 AutoFill 处理。
- 最终下单、Apple Pay、3DS、CAPTCHA、OTP、订阅和退款始终由用户完成。
- Safari v1 只做当前页报价提取和比较，不进入结算操作。

## 8. Safari Web Extension 边界

Apple 在 iOS 18.4 起提供 `WKWebExtensionController`，允许自有 App 将 WebExtension 资源
加载进 `WKWebView`。这解决的是资源复用，不会让 Safari 与自有浏览器获得相同权限。

参考：[WKWebExtensionController](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller)。

Safari companion 首版规则：

- 优先申请 `activeTab` 和必要的窄权限，不默认申请 `<all_urls>`。
- 固定为当前页 R0：只允许 `page.observe`、`page.extract` 和确定性 URL 健康检查；不开放
  click、type、navigate、下载启动、收藏夹写入或任何多步骤写任务。
- Safari companion 不调用本地或远程模型；“解释”来自本地确定性风险规则和固定文案。
- Safari JavaScript、native app extension 与主 App 属于独立进程/沙箱。内容脚本必须经
  background/service worker 转发到 native app extension，不能假设可直连主 App 内存 Broker。
- native app extension 内实现最小 `SafariReadOnlyGate`，同时绑定 extension ID、
  `SFExtensionProfileKey`、Safari tab/page/frame/Origin 和当前用户手势。
- 每次弹窗/用户手势只签发短 lease；popup port 断开、worker 新实例、扩展进程重启、页面跨域
  或权限变化时，旧 lease 因实例绑定而失效，不能依赖 Safari 自然回收来代替撤权。
- App Group 不保存 bearer capability、秘密、原始页面、模型请求或可重放 lease。
- Manifest 默认禁止 `<all_urls>` 和不必要的 `externally_connectable`。
- 最终 Safari 构建产物的 Manifest 只含批准权限，Private Browsing 默认拒绝；target membership
  和产物扫描必须证明不包含 click/type/navigate/download 等写路由，即使共享源码中存在。
- 不承诺 Safari 原生收藏夹写入、程序化下载、后台持续控制或跨站多步骤 Agent。
- 未授权站点、用户拒绝权限、扩展禁用和 Private Browsing 都必须有明确且安全的拒绝状态。
- WebExtension 权限只是平台许可，不等于 Aegis 的任务级授权；ReadOnlyGate 仍需校验页面、
  Origin、固定工具白名单和 lease。
- 如未来开放 Safari 动作能力，必须另行立项并在 extension process 内实现动作 Broker；不能
  直接继承 Aegis Browser 的工具目录或本次 iOS v1 批准。

参考：[权限管理](https://developer.apple.com/documentation/safariservices/managing-safari-web-extension-permissions)、
[原生消息](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)、
[兼容性评估](https://developer.apple.com/documentation/safariservices/assessing-your-safari-web-extension-s-browser-compatibility)。

## 9. 生命周期、恢复与审计

- App 进入后台、Scene inactive、锁屏、标签关闭或 WebContent 进程终止时撤销当前
  document leases 和 action capabilities，取消页面调用并释放控制权。
- `BGTaskScheduler` 只可用于用户开启的只读 URL 检查或索引维护，不用于持续网页自动化。
- 每步按需要分别写入 `AuditEvent` 和脱敏 `Checkpoint`；只有产生可逆本地变化时才创建
  `UndoRecord`，三类数据不相互塞入额外字段。
- 暂停/取消先同步增加 cancellation epoch，立即阻止新动作；模型请求、`URLSession` 和页面
  wait 在 250 ms 内收到取消信号并在 2 秒内结束或放弃，`WKDownload` 在 250 ms 内发出取消并
  最多等待 5 秒。无法取消的外部动作进入 `unknown` 并只读对账。
- 强杀后任务以“已中断”UI 进入 `Recovering`；写操作不自动恢复。外部提交结果未知时先对账，
  再进入用户接管或失败，不自动回到 `Running`。

持久数据使用三套独立、机器可读的字段 allowlist：

- `AuditEvent`：随机任务 ID、相对时间、工具、风险、域名/Origin 摘要、策略决定、确认摘要、
  结果码、耗时、provider、模型和输入输出字节数。
- `Checkpoint`：任务 ID、wire state、计划游标、工具结果码、scope/policy/model 哈希、resource
  registry revision、哈希化外部幂等引用和有界脱敏任务摘要。
- `UndoRecord`：任务/事务 ID、资源类型与作用域、pre/post revision hash、过期时间，以及由
  存储层加密的类型化 inverse-operation payload；为精确还原收藏夹，payload 只在必要时允许
  保存原 URL 的 query/fragment，默认 24 小时、执行撤销或用户清除后立即删除。明文不进入
  AuditEvent、Checkpoint、模型、导出、系统或崩溃日志。

每套 Schema 的未知字段都拒绝或剥离。原始 DOM、截图、完整 prompt/模型输出、表单值、凭据、
Cookie 和文件路径不得落盘；query/fragment 仅有上述 UndoRecord 最小加密例外。三者共享按
Profile 加密、File Protection 和默认不备份规则，但字段与保留期独立。

普通 Profile 的 `AuditEvent/Checkpoint` 按 Profile 独立加密密钥保存，启用完整 File
Protection，默认保留 30 天；用户可预览后导出 AuditEvent，或立即删除三类数据。所有数据
默认不备份、无默认遥测；日志、系统日志和崩溃附件执行相同脱敏。私密 Profile 禁用 Agent，
不创建任务、checkpoint 或持久审计，退出后清除临时状态。

参考：[BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler)。

## 10. 发布与 No-Go 边界

以下任一项成立，iOS Agent 不得进入 RC 或发布候选：

- 模型能调用任意 JavaScript、CDP、文件系统或未经注册的工具。
- `Draft/Planning/AwaitingTaskConsent` 阶段发生页面读取、远程模型或其他网络出站。
- action capability 未绑定完整公共字段和正确的页面/原生 target binding、不能原子消费，或能在并发、失败、跨进程、
  跨 task/grant/Profile/surface/session/WebView、过期、策略/参数变化后重放。
- 密码、Cookie、OTP、支付信息或完整敏感页面进入模型请求、日志或崩溃记录。
- 导航、DOM、价格、数量或目标变化后，旧授权仍能成功执行。
- 页面提示注入能扩大工具、Origin、预算或绕过确认。
- 凭据化或副作用未知的 `page.navigate/page.history` 未经 R2 capability 执行，重定向未逐跳
  重分类，或 history 静默重放 POST/form。
- 页面能伪造 WebKit bridge 身份、nonce、frame/Origin，或跨 Origin 导航能自动扩大 grant。
- 不同 Profile、标签、任务或 frame 之间可以重放授权。
- App 后台、锁屏或强杀后自动恢复写操作。
- Private Profile 能启动 Agent/模型/持久任务，或用户接管时观察与待执行能力没有停止。
- 金融、医疗、政务或身份凭据页面能调用云模型，即使页面尚未出现密码/OTP 字段。
- Agent 或合成页面事件能完成登录、Passkey、最终下单、支付、订阅、退款、OTP、CAPTCHA、
  3DS 或系统权限确认。
- Safari 交付依赖未公开或不受支持的书签、下载、后台或 WebExtension API。
- Safari 构建产物包含写路由/超额权限，或 Share Extension 能接收文件、启动 Agent/云模型、
  拥有专用 Share Inbox 以外的 App Group entitlement、在组内写入 envelope 以外的文件，或
  复用/超时保留一次性 envelope。
- AuditEvent/Checkpoint/UndoRecord/系统或崩溃日志包含各自 allowlist 外的敏感字段，三套
  Schema 被错误合并，或 UndoRecord 的 URL 原值未加密、超出最小 inverse payload、超过
  24 小时/消费后仍保留、进入导出或其他日志。
- 最低系统、entitlement、签名、隐私清单或当前源码身份无法核对。

立项完成不等于发布批准。TestFlight、App Store、生产模型端点和正式签名必须在 M7 后根据
当前源码、真机、Archive 与隐私证据单独批准。

## 11. 相关依据

- [当前架构](./architecture.zh-CN.md)
- [当前路线图](./roadmap.zh-CN.md)
- [Core 平台端口](../packages/core/src/ports.ts)
- [桌面 Agent v1 实施方案](./aegis-browser-agent-v1-implementation-plan-2026-08-28.md)
- [桌面 Agent v1 开发执行计划](./aegis-browser-agent-v1-development-execution-plan-2026-08-28.md)
