# Aegis Browser Agent v1 实施方案

- 版本：Plan v1.0
- 日期：2026-08-28
- 状态：**历史 65+2 Agent 快照已完成 macOS 本地验收；当前 67+2 整合 HEAD 需重新验证，公开发行仍为 No-Go**
- 产品边界：Aegis Chromium Browser 桌面端原生 Agent，不恢复 Extension 产品线
- 实施边界：已授权本地源码、测试、构建与独立 Profile 验收；未授权推送、部署、正式
  签名、公证、公开发布或真实交易
- 配套计划：[Aegis Browser Agent v1 详细开发执行计划](./aegis-browser-agent-v1-development-execution-plan-2026-08-28.md)
- 验收记录：[Aegis Browser Agent v1 macOS 本地验收](./audit/aegis-browser-agent-v1-acceptance-2026-08-29.md)
- 安全记录：[Aegis Browser Agent v1 安全审计与修复验证](./audit/aegis-browser-agent-v1-security-fix-verification-2026-08-29.md)
- 跨平台关系：本轮只实施 macOS Desktop Profile；iOS 按用户要求跳过，Android 后置

## 0. 结论与推荐

推荐把 Aegis Browser Agent v1 定义为一个受浏览器权限约束的任务执行平台，而不是在
`chrome://aegis` 继续增加孤立的 AI 按钮。

v1 应形成完整闭环：

```text
用户目标
  → 生成可查看的计划与作用域
  → 获取任务级授权
  → 观察网页或浏览器状态
  → 调用类型化工具执行
  → 浏览器侧验证结果
  → 失败重试、暂停或交还用户
  → 输出证据、变更清单与撤销入口
```

首版交付四个内置工作流：

1. **深度研究**：跨站搜索、读取、比较、引用来源并输出结果。
2. **浏览器管家**：整理标签页与收藏夹，检查失效链接，支持预览、应用和撤销。
3. **安全下载**：寻找官方来源，识别系统与架构，下载并核对可获得的签名或哈希。
4. **购物助手**：比较商品、卖家、配送与退货条件，加入购物车并停在最终确认页。

网页执行复用 Chromium Actor；收藏夹、标签页、下载等浏览器内部能力使用 Chromium
原生服务；WebMCP 只作为渐进增强；CDP 仅保留为关闭状态下的开发和兼容通道。模型只
负责提出计划和类型化工具调用，最终权限、参数检查、秘密使用、动作提交和结果判定全部
由 Browser Process 掌握。

## 1. 目标、关键假设与确认项

### 1.1 产品目标

v1 的目标不是覆盖所有网站，而是证明以下平台能力可以稳定组合：

- 能理解一个多步骤目标，而不要求用户逐次发出点击指令。
- 能同时管理网页和浏览器自身数据。
- 能跨标签页执行、在失败后重新规划，并在用户接管后继续。
- 能在浏览器重启后恢复安全的未完成任务。
- 能说明将读取什么、发送到哪里、执行什么以及最后改变了什么。
- 页面内容、模型输出或网站工具不能扩大用户授予的权限。

### 1.2 推荐默认假设

本方案采用以下默认值；用户确认本方案即表示同意这些默认边界，除非另行修改：

1. **平台（Desktop Profile）**：本文件的 v1 只实现和验收 macOS 桌面端；Windows/Linux
   做源码兼容审查，Android 只保留可编译边界。独立的 iOS Profile 按 iOS 立项文档实施
   和验收，不继承桌面运行时证据。
2. **Profile**：仅普通 Profile；无痕、Guest、System Profile 和登录前页面禁用 Agent。
3. **模型**：本地或数值 loopback 模型优先；云模型必须由用户显式配置，并在任务开始前
   显示数据目的地和脱敏摘要。
4. **后台**：监控任务只在浏览器运行时执行；浏览器关闭期间不安装常驻守护进程，重启后
   补做一次到期检查。
5. **交易**：公开 v1 可完成比较、表单准备、加购和结账页准备；最终付款、下单、退款、
   取消订单、发送消息和发布内容由用户接管。类型化站点工具的最终提交只进入受控测试，
   不作为 v1 默认能力。
6. **删除**：v1 不自动删除历史记录、Cookie、密码、下载文件或收藏夹；收藏夹整理仅使用
   可撤销的移动、重命名和新建文件夹。
7. **联网**：不启用 Google/Glic 模型编排或新的隐式遥测；Agent 自身联网仅限用户任务、
   已配置模型端点和明确的监控目标。

### 1.3 需要用户确认的产品决策

实施前只需确认以下四项，不要求再决定底层实现细节：

- 接受“macOS 桌面优先，Android 后置”。
- 接受“最终交易默认交还用户，受控测试另设门槛”。
- 接受“云模型按任务展示目的地，本地模型优先但不强制”。
- 接受“本地开发、测试和本地构建，不发布、不部署、不使用生产签名密钥”。

## 2. 已核对的项目基线

### 2.1 立项时源码事实

- 根仓库当前分支为 `codex/aegis-local-dev`，HEAD 为 `659891a`。
- Chromium 固定版本为 `151.0.7922.77`，base commit 为
  `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`。
- 立项时序列包含 56 个 Chromium 主补丁和 2 个 V8 补丁；完成、入口与侧栏就绪修正后为 65 + 2。
- `<chromium-checkout>` 的 patched HEAD 为
  `910672213c5fcd18167b5ee26f690cf0023415e6`。
- Chromium checkout 当前有 6 个设置页未提交改动；根仓库也有 GN 参数和脚本风险研究
  改动。它们属于用户现场，Agent 实施不得清理、覆盖或混入补丁。
- 当前 Release App 早于 checkout HEAD，`args.gn` 与当前 Release 配置不一致，构建身份
  无效；Android 产物未构建。因此现有产物不能作为 Agent 验收基线。

### 2.2 可复用能力

| 能力 | 当前证据 | v1 处理 |
|---|---|---|
| 网页语义动作 | Chromium Actor 已有点击、输入、选择、拖拽、滚动、导航、等待等工具 | 通过 Aegis Actor Bridge 复用，不复制执行引擎 |
| 标签页和窗口 | Actor 已有创建、激活、关闭标签页/窗口 | 复用并增加 Aegis 任务作用域 |
| 登录与表单 | Actor 已有登录、表单和 OTP 工具 | 密码和 OTP 不进入模型；由浏览器代填 |
| 页面观察 | Actor 可按任务请求页面上下文与截图 | 增加文档绑定、裁剪和模型出站预览 |
| 任务控制 | Actor 有 Task、暂停、恢复、用户接管和 Journal | Aegis 负责编排、持久化和用户可见时间线 |
| WebMCP | 当前 Chromium 源码已有 ScriptTool 路径 | 作为实验性增强，不能成为站点兼容性的唯一依赖 |
| 收藏夹 | BookmarkModel 支持新建、移动、重命名、更新 URL | 增加 dry-run、冲突检查和 grouped undo |
| 下载 | Chromium DownloadManager/DownloadItem 与 Aegis 下载中心已存在 | 只新增 Agent 受控入口和验证结果，不重写下载器 |
| 摘要安全 | SummarySession 已有精确文档、Profile、TTL 和确认检查 | 抽取为 Agent 动作确认的参考模式 |
| 模型后端 | 已有 OpenAI、Anthropic、Gemini 兼容请求与本地端点边界 | 新建结构化工具调用客户端，不把摘要客户端硬扩成 Agent |

### 2.3 当前缺口

- 当前 Aegis 模型客户端只处理普通文本对话，没有统一的 tool-call 流、并行工具结果、
  流式恢复和模型能力探测。
- `AegisService` 仍是进程单例，并在源码中注明长期应迁移到 ProfileKeyedService；Agent
  不能继续扩大该单例的职责。
- 现有本地 CDP 自动化边界过宽，且页面 DOM 默认不等同于经过 Agent 数据策略裁剪的
  上下文，不能直接成为产品 Agent 的执行接口。
- Chromium Actor 仍保留 Glic/OptimizationGuide 类型和依赖。Aegis 可以复用执行层，
  但必须证明没有因此启用 Google 模型、Glic UI 或新的隐式出站。
- 当前 `chrome://aegis` 是安全与隐私中心，不适合同时承担长任务、聊天、审批和时间线。

## 3. v1 产品范围

### 3.1 必须交付

#### A. Agent 任务中心

- 原生侧栏入口、工具栏入口和快捷键。
- “问 / 做 / 自动”三种模式，显示当前模式和权限范围。
- 计划预览、域名范围、数据范围、时间/步骤预算和模型目的地。
- 实时步骤时间线、暂停、继续、接管、停止和失败说明。
- 任务结束后显示来源、文件、浏览器变更、未完成项和撤销入口。

#### B. 通用任务引擎

- 多轮规划和反思，但设置工具调用与重试硬上限。
- 单任务可控制多个标签页，但默认最多 8 个，硬上限 20 个。
- 每次动作绑定 Profile、Tab、Frame、DocumentToken、最后提交 URL 和目标节点。
- 浏览器重启后只恢复无外部副作用的任务；待确认动作恢复为“需要重新确认”。
- 用户在受控标签页操作时自动暂停 Agent，重新观察后才能继续。

#### C. 网页与浏览器原生工具

- 网页读取、导航、点击、输入、选择、滚动、拖拽、等待、媒体控制。
- 标签页、窗口、工作区、收藏夹、历史搜索、下载、权限查看和保存 PDF。
- 登录、表单和 OTP 走 Chromium 已有受保护路径，不向模型暴露秘密值。
- WebMCP 工具发现和调用，但所有描述、参数与返回值均标记为页面不可信数据。

#### D. 四个内置工作流

- 深度研究。
- 浏览器管家。
- 安全下载。
- 购物助手。

#### E. 本地任务与监控

- 保存未完成任务、授权收据、动作日志和脱敏后的结果摘要。
- 价格、库存、页面变化和失效链接的浏览器内监控。
- 浏览器关闭时不运行；下次启动执行一次补偿检查，不进行高频追赶。

### 3.2 明确后置

- Android Agent UI、Android 多标签执行和移动端后台任务。
- 浏览器关闭后的 OS 常驻 Agent。
- 无人值守最终付款、下单、退款、取消订单、发帖、发消息或签署法律文件。
- 任意 JavaScript、Shell、Python、CDP `Runtime.evaluate` 或文件系统通用执行工具。
- 自动读取剪贴板、密码明文、Cookie、银行卡号、完整聊天记录或本地任意文件。
- 历史/Cookie/密码/下载文件的批量删除。
- 第三方技能市场、远程技能自动更新、跨设备任务同步和多人协作。
- 语音、屏幕圈选和“录制一次自动生成技能”；这些可在 v1 稳定后单独评估。

## 4. 用户体验设计

### 4.1 入口

v1 使用以下入口，按实现优先级排序：

1. 工具栏 Aegis Agent 按钮，打开专用侧栏。
2. `Cmd+Shift+A` 快捷键。
3. 页面、链接、选中文本和下载链接的右键菜单“交给 Aegis”。
4. `chrome://aegis` 中的“打开 Agent”链接，但安全中心和 Agent 任务中心保持分离。
5. 地址栏 `@aegis` 作为后续增强；不阻塞 v1 主闭环。

### 4.2 侧栏结构

```text
┌──────────────────────────────┐
│ Aegis Agent       问 | 做 | 自动 │
├──────────────────────────────┤
│ 目标输入 / 当前页面上下文       │
│ 快捷任务：研究、整理、下载、购物  │
├──────────────────────────────┤
│ 计划卡                         │
│ 域名 · 数据 · 动作 · 预算 · 模型 │
│ [开始] [调整范围]              │
├──────────────────────────────┤
│ 执行时间线                     │
│ ✓ 读取 3 个页面                │
│ → 比较价格                     │
│ ! 等待确认 / 用户接管           │
├──────────────────────────────┤
│ [暂停] [接管] [停止]            │
└──────────────────────────────┘
```

侧栏使用独立的 untrusted WebUI 和窄 Mojo 接口。模型输出与网页内容按纯文本或经过严格
schema 验证的结构渲染，不允许插入任意 HTML。权限判断、审批和工具执行不放在 WebUI。

### 4.3 标准任务流程

1. 用户输入目标或从右键菜单创建任务。
2. Agent 生成计划，但此时不能执行写操作。
3. 浏览器显示任务卡：允许域名、将读取的数据、可用工具、模型目的地、预算和高风险点。
4. 用户开始任务后，Agent 逐步观察和执行。
5. 发生跨域、秘密使用、文件上传或不可逆动作时，任务进入等待确认或用户接管。
6. 每个工具结果由浏览器验证后再返回模型；模型自述“成功”不算成功。
7. 任务结束展示证据、变更、失败和撤销能力。

## 5. 技术架构

```text
Aegis Agent Side Panel / Toolbar / Context Menu
                     │
              AegisAgentService
        任务状态、预算、调度、恢复、事件流
          ┌──────────┼───────────┐
          │          │           │
 AgentModelClient  PolicyBroker  TaskStore
 计划与 tool-call  权限与审批     本地状态与日志
          │          │
          └───── ToolRegistry ───────────────┐
                    │                        │
             AegisActorBridge        AegisBrowserTools
          页面观察与语义动作       标签/收藏/下载/权限
                    │                        │
              Chromium Actor          Chromium 原生服务
                    │
        WebMCP → 语义节点 → 坐标兜底
                    │
               ResultVerifier
           后置条件、证据、冲突与撤销
```

### 5.1 `AegisAgentService`

- 新建 ProfileKeyedService，每个普通 Profile 独立实例。
- 拥有任务、工具注册表、模型会话、策略代理、任务存储和调度器。
- 不把任务状态放入现有进程单例 `AegisService`。
- Profile 销毁时取消工具、释放页面引用并清理未落盘敏感内存。
- OTR/Guest/System Profile 的 Factory 返回空或禁用实例。

### 5.2 `AegisAgentModelClient`

- 与现有摘要客户端分离，共用端点校验、凭据加密和请求取消基础设施。
- 把 OpenAI、Anthropic、Gemini 和本地 OpenAI-compatible 结果规范化为统一事件：
  `message_delta`、`tool_call`、`tool_result_ack`、`usage`、`completed`、`error`。
- 启动任务前探测模型是否可靠支持结构化工具；不支持时降级为“问”模式。
- 模型不能自行添加工具、修改 schema、改变风险等级或扩大 origin/file scope。
- 所有 provider 都通过本地 mock server 做请求、重定向、取消、超时和异常响应测试。

### 5.3 `AegisActorBridge`

- 将 Aegis 类型化网页工具转换为 `ActorKeyedService::PerformActions()` 请求。
- 为每个任务创建独立 ActorTask，并映射暂停、恢复、接管、停止和 Journal 事件。
- 复用 Actor 的页面上下文、交互节点和站点策略，不复制点击/输入实现。
- Aegis 自有策略在调用 Actor 前执行；Actor 的 Safe Browsing、lookalike、URL 和
  enterprise gate 作为第二层检查。
- 不直接打开 Glic UI，不调用 Google 模型或 OptimizationGuide 模型服务；M0/M3 必须
  用出站证据证明该边界。

### 5.4 `AegisBrowserTools`

直接调用 Profile 对应的 Chromium 服务：

- `TabStripModel` / tabs public API：标签页、标签组和激活状态。
- `BookmarkModel` + `BookmarkUndoService`：收藏夹读取、移动、重命名和撤销。
- `HistoryService`：只读搜索。
- `DownloadManager` / `DownloadItem`：下载、暂停、恢复、取消和状态；实际保存继续使用
  Chromium 与 Aegis 下载中心。
- Content settings：只读查看权限；申请权限仍由页面和 Chromium 标准提示完成。
- Print Preview/PDF：保存当前页面时使用 Chromium 标准路径，不绕过系统文件选择。

### 5.5 `AegisPolicyBroker`

PolicyBroker 是 Browser Process 中的确定性门，不调用模型做最终授权决定。它负责：

- 校验任务级 Profile、origin、tab、document、工具、数据类别、文件和预算范围。
- 给每次调用计算风险等级，并决定自动执行、任务级确认、逐次确认、用户接管或拒绝。
- 检查页面导航、Frame/DocumentToken、目标节点和关键参数是否仍与批准时一致。
- 对 WebMCP 工具描述、网页文字和工具返回值强制标记 `untrusted`。
- 记录批准内容的摘要哈希、TTL 和使用次数，防止重放或偷换参数。
- 在站点、工具或风险无法判断时 fail closed。

### 5.6 `AegisTaskStore` 与调度器

- 使用 Profile 内独立 SQLite 数据库保存任务元数据、计划、工具日志和监控定义。
- API key 继续使用 OSCrypt；任务库不保存密码、OTP、Cookie、银行卡号和完整表单值。
- 默认不持久化页面正文或截图；研究结果只保存用户明确保留的摘要和来源 URL。
- 未完成任务保留 7 天，完成任务日志默认保留 30 天，用户可立即清除。
- 外部副作用步骤不自动重放；崩溃恢复后重新观察并重新确认。
- 调度器设置最小间隔、指数退避、站点并发和每日请求上限。

## 6. 任务合同与状态机

### 6.1 任务合同

每个任务必须固化以下字段：

| 字段 | 含义 |
|---|---|
| `task_id` | Profile 内不可复用的任务标识 |
| `goal` | 用户原始目标，不允许页面修改 |
| `mode` | `ask`、`act` 或 `automate` |
| `allowed_origins` | 精确 origin 或用户确认的站点集合 |
| `allowed_tools` | 该任务可调用的工具集合 |
| `data_classes` | 可读取/发送的数据类别 |
| `file_scope` | 用户选择的文件或下载目录能力，不接受任意路径 |
| `budgets` | 时间、标签页、工具调用、模型调用和网络请求上限 |
| `model_destination` | 本地/云、provider、host、model 和脱敏策略 |
| `approval_policy` | 风险等级到确认方式的映射 |
| `created_document` | 发起页面的 Tab/Frame/DocumentToken 快照 |
| `retention` | 结果和日志保留策略 |

### 6.2 状态机

```text
Draft
  → Planning
  → AwaitingTaskConsent
  → Running ⇄ Reflecting
       ├→ AwaitingActionApproval
       ├→ PausedByUser
       ├→ UserTakeover
       ├→ Recovering
       └→ Verifying
  → Completed | Failed | Cancelled | Expired
```

- 只有 `AwaitingTaskConsent` 可以建立初始任务授权。
- 计划改变 origin、工具、数据类别或外部副作用时，必须返回重新授权。
- 用户接管后，旧页面观察和未执行动作全部失效。
- `Completed` 只能由 ResultVerifier 根据后置条件设置，不能直接采用模型文本。

## 7. 风险等级与审批

| 等级 | 典型动作 | 默认策略 |
|---|---|---|
| R0 只读 | 读取可见页面、搜索历史、列出标签页、查看下载状态 | 任务级一次确认；纯本地问答可直接执行 |
| R1 可逆本地 | 新建/移动收藏夹、分组标签页、暂停下载、保存工作区 | 计划预览后批量执行，提供撤销 |
| R2 外部或敏感 | 跨域导航、登录、填表、上传文件、开始下载、加入购物车 | 首次触发逐项确认；参数或页面变化后重确认 |
| R3 财务/法律/公开 | 下单、付款、退款、取消、发送、发布、授权、签署 | v1 默认用户接管；仅受控 fixture 可自动提交 |
| 禁止 | 读取秘密明文、绕过验证码/DRM/安全警告、任意代码执行 | 始终拒绝 |

确认卡必须显示用户可理解的事实，而不是工具参数堆栈。例如购买确认至少包含商家、商品、
数量、总额、币种、配送地址摘要、付款方式摘要、最终按钮含义和当前页面域名。

## 8. v1 工具目录

工具名是 Aegis 逻辑合同，不要求与 Chromium Actor 类名一一相同。

### 8.1 页面观察与动作

| 工具 | 能力 | 风险/验证 |
|---|---|---|
| `page.observe` | 获取当前文档的结构、可见文本、交互节点和可选截图 | R0；绑定 DocumentToken，正文裁剪 |
| `page.extract` | 按 schema 提取列表、表格、文章或商品字段 | R0；返回来源节点与缺失字段 |
| `page.webmcp.list` | 列出当前文档公开的 WebMCP 工具 | R0；描述和 schema 视为不可信 |
| `page.webmcp.invoke` | 调用一个结构化站点工具 | 按语义升至 R2/R3；同源、参数和结果校验 |
| `page.navigate` | 当前或新标签页导航 | R0/R2；URL、重定向和站点策略复查 |
| `page.click` | 点击语义节点 | R1/R2；节点、文档、可见性与遮挡复查 |
| `page.type` | 向普通字段输入非秘密文本 | R2；字段类别、长度和目标 origin 检查 |
| `page.select` | 选择下拉或控件值 | R1/R2；验证最终值 |
| `page.scroll` | 滚动页面或节点 | R0 |
| `page.drag` | 有界拖拽 | R1/R2；起止节点和页面稳定性检查 |
| `page.wait` | 等待条件、导航或网络稳定 | R0；有超时，不允许无限等待 |
| `page.history` | 当前标签页前进/后退 | R1；验证提交 URL |
| `page.media` | 播放、暂停、跳转 | R1；不提供媒体提取或绕过 DRM |

### 8.2 浏览器原生工具

| 工具组 | v1 能力 | 约束 |
|---|---|---|
| `browser.tabs.*` | list/create/activate/close/group | 关闭仅限任务创建或用户授权的标签；固定页不自动关闭 |
| `browser.windows.*` | list/create/activate/close | 不关闭最后一个正常窗口；关闭前检查下载/表单状态 |
| `browser.workspace.*` | save/restore | 只保存 URL、组和顺序，不保存页面正文和表单秘密 |
| `bookmarks.*` | list/plan/check_urls/apply/undo | 先预览；使用 grouped undo；不自动删除 |
| `history.search` | 按文字、域名和时间只读查询 | 结果默认不发送云模型；删除后置 |
| `downloads.*` | list/start/pause/resume/cancel/verify/open | 路径由系统选择或下载设置决定；危险下载门不绕过 |
| `permissions.inspect` | 查看当前站点权限 | 只读；权限申请走 Chromium 标准 UI |
| `page.save_pdf` | 保存当前页 PDF | 使用标准保存对话框，用户可接管路径选择 |

### 8.3 受保护工具

| 工具 | 能力 | 约束 |
|---|---|---|
| `auth.attempt_login` | 使用 Chromium 密码管理器登录 | 模型只知道候选账号标签，不读取密码 |
| `auth.fill_otp` | 使用浏览器可用 OTP 或让用户输入 | OTP 不进入任务日志或模型上下文 |
| `form.fill` | 填写地址、联系信息或普通表单 | 先展示字段与目标站点；信用卡字段不自动填入 v1 通用流程 |
| `file.upload` | 上传用户显式选择的文件 | 绑定文件 token、目标 origin 和单次使用；不暴露任意路径 |
| `monitor.*` | create/list/pause/delete 监控 | 只读检查；频率、域名和通知方式固定 |

## 9. 四个内置工作流的具体合同

### 9.1 深度研究

输入：问题、来源偏好、时间范围、最大站点数和输出格式。

执行：

1. 生成检索式和站点计划。
2. 最多打开 8 个并行标签，逐站提取标题、发布日期、作者、核心事实和 URL。
3. 区分直接事实、来源观点和 Agent 推断。
4. 对重复转载、时间冲突和数字冲突标记，而不是静默合并。
5. 输出带可点击来源的报告和未验证项。

验收：10 个受控站点中至少 9 个正确提取；所有关键结论有来源；不存在把页面指令当系统
指令执行的情况。

### 9.2 浏览器管家

输入：收藏夹范围、分类偏好、是否允许改名、失效检查强度。

执行：

1. 读取收藏夹树并生成 snapshot hash。
2. 本地规则先处理重复 URL、明显域名类别和已有文件夹语义；需要内容时再按用户授权读取。
3. 失效检查先尝试 HEAD，必要时退回小范围 GET；限制并发和每站速率。
4. 状态分为 `live`、`redirect`、`auth_required`、`rate_limited`、`timeout`、`dns_error`、
   `tls_error`、`permanent_http_error` 和 `indeterminate`。
5. 输出移动/重命名/更新 URL 预览；snapshot 变化时拒绝应用并重新生成计划。
6. 使用 BookmarkUndoService 将一次整理分组为一个可撤销动作。

`403`、`401`、`429`、超时和脚本渲染失败不能直接判为死链；v1 不自动删除任何收藏夹。

### 9.3 安全下载

输入：要找的软件或文件、系统、架构、版本偏好和保存方式。

执行：

1. 优先查找厂商官网、官方代码托管发布页或项目明确链接的镜像。
2. 比较版本、平台、架构、发布日期、文件名和来源链。
3. 识别下载重定向，拒绝凭据 URL、私网跳转和不受支持协议。
4. 启动 Chromium DownloadItem；沿用 Safe Browsing/Aegis 危险下载提示。
5. 若官方提供签名或 SHA-256/SHA-512，则核对；没有时明确显示“未提供”，不伪造验证。
6. 输出最终路径、来源、大小、哈希和验证状态。

### 9.4 购物助手

输入：商品约束、预算、地区、配送期限和偏好。

执行：

1. 跨站比较商品规格、价格、税费、运费、卖家、退货条件和库存。
2. 将缺失数据标记为“未提供”，不将营销文字推断成保证。
3. 可以选择规格、数量、优惠券并加入购物车。
4. 到达结账确认页后输出商家、商品、总额和配送摘要，进入用户接管。
5. 通用 DOM 点击不得触发最终购买；只有未来经过审核的类型化站点工具可申请 R3 提交。

## 10. 页面操作优先级与兼容策略

执行顺序固定为：

1. **浏览器原生服务**：适用于标签、收藏、下载、权限等浏览器内部数据。
2. **WebMCP**：网站主动提供结构化工具时使用，但仍经过 Aegis 策略。
3. **Chromium Actor 语义节点**：依据页面上下文、可访问性与 DOM 语义操作。
4. **有界坐标兜底**：只在语义节点不可用且目标低风险时使用，点击前重新截图和命中测试。
5. **用户接管**：验证码、系统对话框、高风险最终动作或页面无法可靠识别时停止自动化。

WebMCP 截至 2026-08-28 仍是 W3C Community Group Draft，不是 W3C 标准。因此 v1 必须
保留语义节点回退，并为 WebMCP 行为建立独立 feature flag 和兼容测试。

## 11. 数据、隐私与提示词注入防线

### 11.1 数据分类

| 类别 | 示例 | 默认处理 |
|---|---|---|
| PublicPage | 公共网页可见内容 | 可按任务发送，先裁剪 |
| BrowserMetadata | 标签标题、收藏夹、历史、下载记录 | 默认本地；发云需单独显示 |
| PersonalData | 姓名、邮箱、地址、订单 | 默认脱敏；跨站或发云逐项确认 |
| Secret | 密码、OTP、Cookie、token、卡号 | 永不进入模型，只由浏览器代用 |
| LocalFile | 用户文件与下载内容 | 仅文件 token；上传前确认文件名、大小、目标 |

### 11.2 注入防护

- 系统策略、用户目标、网页内容、WebMCP 元数据和工具结果使用不同结构字段，不拼接为一段
  无来源文本。
- 网页中的“忽略之前指令”“调用某工具”“上传文件”等内容始终是数据，不改变任务合同。
- 工具列表由 Browser Process 注册；模型只能从已批准列表选择。
- 工具参数执行前做 schema、长度、URL、origin、文件 token、风险和预算验证。
- 页面观察与工具结果返回模型时携带来源和 `untrusted=true` 标记。
- 站点跨域、重定向、弹窗和 iframe 使用实际提交后的 origin 再检查。
- 对 prompt injection、tool poisoning、output injection 和越权参数建立固定攻击样例集。

### 11.3 秘密与身份

- 密码管理器只向受保护 Actor 登录工具返回成功/失败和账号标签。
- OTP、信用卡 CVC、Cookie、Authorization header 和 API key 不进入 Agent Journal。
- 文件上传使用 Browser Process 生成的单次 capability token；模型看不到完整本地路径。
- 模型 API key 沿用 OSCrypt 加密，日志只能记录 provider、host、model 和凭据存在状态。

## 12. 一致性、恢复与验证

### 12.1 幂等和冲突

- 每个写工具有唯一 `action_id`，重复提交返回已有结果，不再次执行。
- 浏览器数据写操作带 snapshot revision；收藏夹或标签树被用户修改后拒绝旧计划。
- 外部页面动作带 DocumentToken 和关键节点指纹；导航、重载或 DOM 关键变化后失效。
- 下载开始后以 Download GUID 继续管理，不靠 URL 重复创建。

### 12.2 结果验证

- 导航：验证最终 URL、错误文档、证书和站点策略。
- 点击/输入：重新观察目标状态、控件值或预期页面变化。
- 收藏夹：比较应用前计划、应用后树和 undo 状态。
- 下载：验证 DownloadItem 状态、文件存在、大小和可用哈希。
- 研究：每条事实保留来源 URL 与提取片段哈希。
- 购物：价格、币种、数量和商家在接管前重新读取，不能使用旧计划值。

### 12.3 恢复

- 浏览器崩溃或重启后，任务先进入 `Recovering`，不直接恢复动作。
- 重新加载 Profile 服务、标签映射和任务日志；无法恢复的标签标为缺失。
- 所有待批准动作过期；所有外部副作用动作要求人工核对是否已经发生。
- 只读研究和监控可重新观察后继续；表单、上传、登录和购物流程默认交还用户。

## 13. 资源与性能预算

- 侧栏隐藏且无任务时不轮询页面，不产生可测的持续 CPU 增量。
- 默认同时运行 1 个交互任务、最多 3 个只读监控检查；同一 Profile 不并行操作同一标签。
- 单次页面上下文默认最多 128 KiB 文本；截图最多 2 张，并在发送前缩放和裁剪。
- 单任务默认最多 60 次工具调用、20 次模型回合、15 分钟；达到上限后暂停并说明。
- 工具失败最多重试 2 次；只有页面状态发生可解释变化时才允许第三次重新规划。
- 收藏夹 URL 检查默认并发 4、每 origin 并发 1，并尊重 `429` 与退避。
- 监控默认最短 15 分钟；失败使用指数退避，不形成高频请求。
- Browser Process 每个活动任务新增持久内存目标不超过 20 MiB，不含页面 Renderer 和外部
  模型进程；正式门以 Aegis ON/OFF 运行时采样为准。

## 14. 功能开关与发布层级

建议新增独立开关：

- `kAegisAgent`：RC 验收后默认开启入口层；Profile 执行偏好仍默认关闭。
- `kAegisAgentPageActions`：已验收网页能力的入口层默认开启，实际执行受 Profile 偏好、scope 与审批约束。
- `kAegisAgentBrowserTools`：已验收浏览器原生能力的入口层默认开启，实际执行受 Profile 偏好、scope 与审批约束。
- `kAegisAgentWebMcp`：实验性 WebMCP。
- `kAegisAgentWorkflows`：已验收工作流入口层默认开启；未显式启用 Profile 时不启动任务或监控。
- `kAegisAgentTransactionPilot`：R3 受控测试，Release 永久默认关闭。

层级：

1. **Developer**：本地 fixture 与内部页面，全部开关显式传入。
2. **Alpha**：只读研究 + 标签/收藏夹预览。
3. **Beta**：可撤销浏览器写操作 + 低风险网页操作。
4. **RC**：四个工作流、恢复、监控、完整权限和运行时证据。
5. **Transaction Pilot**：独立批准，不随 v1 RC 自动开启。

## 15. v1 验收场景

| 编号 | 场景 | 核心完成标准 |
|---|---|---|
| A1 | 10 站点深度研究 | 关键结论均有来源；冲突明确；页面注入不能改计划 |
| A2 | 500 条收藏夹分类 | 先预览；应用结果准确；一键 grouped undo 恢复原树 |
| A3 | 失效链接检查 | 403/429/超时不误删；状态可解释；并发与退避符合预算 |
| A4 | 官方软件下载 | 平台/架构正确；使用 DownloadItem；来源和验证状态完整 |
| A5 | 跨站购物比较 | 总价组成可追溯；加购成功；最终购买停在用户接管 |
| A6 | 中断与重启 | 只读任务可恢复；待确认动作失效；没有重复下载或重复写入 |
| A7 | 用户接管 | Agent 立即暂停；用户操作后重新观察；旧动作不能执行 |
| A8 | Profile 隔离 | 普通 Profile 不串数据；无痕/Guest/System Profile 禁用 |
| A9 | 模型端点异常 | 重定向、超时、畸形 tool-call 和流中断 fail closed |
| A10 | 出站审计 | 没有因启用 Actor 而新增 Google/Glic 隐式模型或遥测请求 |

## 16. v1 完成定义

只有同时满足以下条件，才能把 v1 标为完成：

- 方案中所有 P0 能力都有源代码、自动测试和运行时证据。
- 65 个 Chromium 补丁和 2 个 V8 补丁可从固定 base 在干净 checkout 无人工干预重放。
- `quality:fast`、合同检查、Aegis C++ 单测、Agent browser/interactive UI tests 全部通过。
- 当前源码能构建新的 LocalDev 和 non-component Release App；产物身份匹配源码和 GN 参数。
- 四个内置工作流在新 Profile 上完成代表性真实操作，证据可复核。
- 注入、跨域、Profile、秘密、文件、TOCTOU、恢复和重放攻击门全部通过。
- 用户能随时暂停、接管和停止；收藏夹等可逆操作能真实撤销。
- 运行时出站、CPU、内存和任务数据库保留策略有机器可读证据。
- 文档只声明已验证能力；本地通过不自动等于可公开发布。

## 17. 参考与实现依据

- 当前 Chromium Actor 工具联合：
  `<chromium-checkout>/chrome/browser/actor/tool_request_variant.h`
- 当前 Actor Profile 服务、页面观察和 Journal：
  `<chromium-checkout>/chrome/browser/actor/actor_keyed_service.h`
- 当前 Actor URL 策略：
  `<chromium-checkout>/chrome/browser/actor/site_policy.h`
- 当前收藏夹模型与 Undo：
  `<chromium-checkout>/components/bookmarks/browser/bookmark_model.h`、
  `<chromium-checkout>/components/undo/bookmark_undo_service.h`
- 当前 Aegis 精确文档确认参考：
  `apps/browser/overlay/chrome/browser/aegis/summary_session.cc`
- 当前 Aegis 模型端点边界：
  `apps/browser/overlay/chrome/browser/aegis/model_provider_client.h`
- WebMCP Community Group Draft：<https://webmachinelearning.github.io/webmcp/>
- Chrome DevTools Protocol：<https://chromedevtools.github.io/devtools-protocol/>

## 18. 批准边界

用户确认本方案后，授权范围默认仅包括：

- 在独立开发分支/工作区实施源码和测试。
- 更新 Chromium overlay、可重放 patch series 和中文技术文档。
- 运行本地自动测试、macOS Chromium 构建和独立测试 Profile 的 UI/运行时验收。
- 创建本地测试数据、fixture 和 `.artifacts` 机器可读证据。

不包含：推送、PR、tag、Release、二进制上传、生产部署、Developer ID、公证、Play Store、
生产模型密钥、真实购买或向第三方发送真实消息。任何此类动作必须单独确认。
