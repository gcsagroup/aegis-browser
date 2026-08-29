# Aegis Browser Agent v1 详细开发执行计划

- 版本：Plan v1.0
- 日期：2026-08-28
- 状态：**历史 65+2 Agent 快照已完成 macOS 本地验收；当前 67+2 整合 HEAD 需重新验证，公开发行 No-Go**
- 上位方案：[Aegis Browser Agent v1 实施方案](./aegis-browser-agent-v1-implementation-plan-2026-08-28.md)
- 验收记录：[Aegis Browser Agent v1 macOS 本地验收](./audit/aegis-browser-agent-v1-acceptance-2026-08-29.md)
- 安全记录：[Aegis Browser Agent v1 安全审计与修复验证](./audit/aegis-browser-agent-v1-security-fix-verification-2026-08-29.md)
- iOS 执行线：本轮按用户要求暂缓，不纳入实现与验收范围。
- 本记录基线：Chromium `151.0.7922.77`，65 个主补丁，2 个 V8 补丁
- 估算口径：工程人日，不含首次冷构建、外部下载、设备排队和用户确认等待时间

## 0. 执行结论

推荐分两段交付，而不是一次性打开所有 Agent 权限：

1. **平台基础与 v1 Alpha（M0–M6，约 40–61 人日）**：完成任务中心、结构化模型调用、
   Actor Bridge、浏览器原生工具和安全基座；Alpha 只开启只读研究、标签页管理、收藏夹
   预览/应用/撤销和安全下载。
2. **v1 RC（M7–M8，追加约 17–25 人日）**：完成四个工作流、登录/表单受保护路径、购物
   接管、任务恢复、浏览器内监控和完整安全/性能/运行时验收。

总估算为 **57–86 工程人日**。单人串行约 12–18 周；两个熟悉 Chromium 的开发者可在
M1 完成后并行 UI、浏览器工具和模型适配，但 M0、M3、M5 与最终验收不能并行跳过。

这是一条平台开发线，不是“接一个模型接口”的工作量。任何里程碑只有满足测试和退出条件
后才能进入下一阶段；时间不足时缩减后续能力，不降低权限、注入、Profile 和恢复门槛。

## 1. 实施前硬边界

### 1.1 当前工作区保护

当前根仓库和外部 Chromium checkout 都有用户改动：

- 根仓库：`.gitignore`、3 个 GN 参数文件和脚本风险研究文件。
- Chromium checkout：6 个 Settings 页面文件。

开始开发前必须重新记录 `git status`、diff、HEAD 和文件哈希。不得执行 `git clean`、
`git reset --hard`、`checkout --`、自动 stash、强制同步或覆盖 overlay。Agent 工作使用独立
分支/工作区，当前用户现场原样保留。

### 1.2 实施授权

用户确认本计划后，默认只授权：

- 本地源码修改、测试、macOS 构建和独立测试 Profile 验收。
- 新增或更新 overlay、patch series、fixture、测试脚本、文档和本地 `.artifacts` 证据。
- 为测试访问用户明确指定的公开网页或本地 fixture。

不授权推送、PR、Release、部署、正式签名、公证、真实交易、真实消息发送、生产密钥和
清理现有研究/构建证据。

### 1.3 开发原则

1. **Overlay 与补丁是交付真相**：外部 Chromium checkout 只用于实现和验证，所有必要
   改动必须回写为 overlay 或可重放补丁。
2. **先合同与失败测试，后实现**：工具 schema、状态机、权限和结果验证先有测试。
3. **浏览器验证成功，模型不判成功**：模型输出不直接改变任务终态。
4. **安全门不可降级**：缺失 origin、DocumentToken、文件 token、风险分类或审批时拒绝。
5. **源、测试、构建、运行时、产物、发布分层**：任何一层通过不替代下一层。
6. **功能开关逐层开启**：默认总开关关闭，Alpha/RC 根据证据推进。

## 2. 里程碑依赖

```text
M0 基线与集成 Spike
 │
 ├→ M1 Agent 核心合同与 Profile 服务
 │    ├→ M2 结构化模型与 Planner
 │    ├→ M4 浏览器原生工具
 │    └→ M6 侧栏 UI 骨架
 │
 M2 → M3 Actor Bridge 与页面观察
 M3 + M4 → M5 Policy、审批、验证与恢复
 M5 + M6 → M7 四个工作流与监控
 M7 → M8 安全、性能、构建与真实验收
```

M0 是 Go/No-Go 门。如果无法在不启用 Glic/Google 模型出站的情况下复用 Actor，先完成
最小解耦设计和测试，不进入大规模 UI 或工作流开发。

## 3. 建议源码布局

新增文件优先放在现有 Aegis 命名空间内：

```text
apps/browser/overlay/chrome/browser/aegis/agent/
  aegis_agent_service.{h,cc}
  aegis_agent_service_factory.{h,cc}
  task/
    agent_task.{h,cc}
    agent_task_store.{h,cc}
    agent_task_scheduler.{h,cc}
  model/
    agent_model_client.{h,cc}
    agent_model_protocol.{h,cc}
    agent_model_stream_parser.{h,cc}
  tools/
    agent_tool.{h,cc}
    agent_tool_registry.{h,cc}
    actor_bridge.{h,cc}
    browser_tool_service.{h,cc}
    bookmark_tools.{h,cc}
    download_tools.{h,cc}
    tab_tools.{h,cc}
  policy/
    agent_policy_broker.{h,cc}
    agent_approval.{h,cc}
    agent_result_verifier.{h,cc}
  workflows/
    research_workflow.{h,cc}
    bookmark_workflow.{h,cc}
    safe_download_workflow.{h,cc}
    shopping_workflow.{h,cc}

apps/browser/overlay/chrome/browser/ui/webui/aegis_agent/
  aegis_agent_ui.{h,cc}
  aegis_agent_page_handler.{h,cc}

apps/browser/overlay/chrome/browser/resources/aegis_agent/
  app.ts
  app.html.ts
  app.css
  task_store.ts
  types.ts

apps/browser/overlay/chrome/common/aegis/
  agent.mojom
  agent_types.{h,cc}

apps/browser/scripts/
  verify-agent-runtime.mjs
```

实际文件可在 M1 进一步合并，避免每个小类型一个文件。上述布局表达职责边界，不要求机械
照搬；优先保持当前 Chromium/Aegis 风格和最少抽象。

## 4. M0：基线封存与 Actor 集成 Spike

- 预计：2–4 人日
- 目标：证明当前源码上可以安全创建 Aegis 自有 ActorTask，并明确所有 Glic、
  OptimizationGuide、Field Trial 和出站依赖。

### 步骤

1. 重新记录根仓库与 Chromium checkout 的 branch、HEAD、status、diff、补丁序列哈希、
   overlay 哈希、GN 参数和现有产物身份。
2. 对当前 6 个 Settings 改动和根仓库研究改动生成只读清单；确认 Agent 工作区不覆盖它们。
3. 从当前根 HEAD 创建独立 `codex/aegis-browser-agent-v1` 工作区；若用户改动尚未进入
   commit，保持原工作区不动，并在 Agent 工作区只实现不依赖这些改动的代码。
4. 构建一个不接模型、不显示 UI 的最小 Spike：
   - 创建 Profile 级 Aegis Agent service。
   - 创建 ActorTask。
   - 在本地 fixture 执行 `navigate → observe → click/type → stop`。
   - 验证暂停、用户接管、取消和 Task Journal。
5. 审计 `chrome/browser/actor/BUILD.gn`、feature flags、Glic 依赖和 OptimizationGuide 调用；
   记录哪些只是类型/页面上下文依赖，哪些会实际联网或触发 Glic UI。
6. 使用本地代理/DNS 记录运行 Spike 的全部出站；没有用户任务时不应因 Agent 新增请求。
7. 决定复用边界：优先 adapter；只有上游 API 强耦合且有回归测试时才做最小解耦补丁。

### 测试与验证

- `pnpm --filter @gcsa-aegis/browser status` 记录开始状态；当前失败必须被保留说明。
- 最小 C++ unit test：Factory Profile 隔离、OTR 禁用、ActorTask 创建/停止。
- 本地 HTTPS fixture browser test：语义点击和输入成功，导航后旧节点失效。
- 运行时出站捕获：没有新 Glic/Google 模型或 Agent 遥测请求。
- 停止任务后没有受控 tab、悬挂 callback 或活跃 ActorTask。

### 退出条件

- 得到明确的 Actor 复用/解耦决策和依赖清单。
- Spike 在普通 Profile 通过，在 OTR/Guest/System Profile 拒绝。
- 用户现场未发生变化；Agent 工作区可独立删除而不影响原现场。
- 若必须启用无法关闭的 Google/Glic 出站，M0 标为 No-Go，先提交替代执行层方案供确认。

### 交付物

- `docs/audit/aegis-agent-m0-baseline-YYYY-MM-DD.md`
- `.artifacts/aegis-agent-m0-egress.json`
- 最小 Spike 补丁和测试；总开关默认关闭。

## 5. M1：Agent 合同、状态机和 Profile 服务

- 预计：4–6 人日
- 依赖：M0 Go
- 目标：建立不依赖具体模型和 UI 的 Agent 核心。

### 步骤

1. 新增 `kAegisAgent` 总开关及 prefs，默认关闭；除显式开发开关外，Release 不自动开启。
2. 新建 `AegisAgentServiceFactory` 和 `AegisAgentService`，仅普通 Profile 可用。
3. 定义 `AgentTask`、状态机、停止原因、模式、预算、数据类别和保留策略。
4. 定义不可变 `TaskScope`：allowed origins/tools/data/file capabilities/model destination。
5. 定义 `AgentToolCall` 和 `AgentToolResult`：schema version、action id、前置条件、后置条件、
   风险、来源、证据和错误类型。
6. 建立 ToolRegistry，但只注册 fixture 工具；工具 schema 来自编译期常量，不接受模型生成。
7. 建立任务事件流和 observer，供 UI、Journal 和运行时验证共同使用。
8. 建立 SQLite TaskStore schema v1 和迁移机制；敏感字段不落盘。
9. 增加任务恢复规则：只读任务可恢复，待批准和外部副作用动作过期。

### 重点测试

- 状态只能按合法边转换，完成态不可回退。
- task id/action id 不复用；重复 action id 幂等返回。
- origin、工具、数据类别、预算或 model destination 扩大时拒绝。
- 普通 Profile、第二普通 Profile、OTR、Guest 和销毁中的 Profile 不串状态。
- 数据库损坏、旧 schema、部分写入和崩溃恢复 fail closed。
- TaskStore 中不存在测试密码、OTP、Cookie、卡号、原始页面正文和完整本地路径。

### 退出条件

- 无模型、无网页 UI 时，fixture 工具能完整跑通 Draft → Running → Verifying → Completed。
- 暂停、取消、超时、预算耗尽、崩溃恢复和 Profile 销毁均有确定结果。
- C++ 单测和数据库迁移测试全绿。

## 6. M2：结构化模型协议与 Planner

- 预计：6–9 人日
- 依赖：M1
- 目标：让受支持模型稳定产生可验证的计划和工具调用，而不是解析自然语言命令。

### 步骤

1. 新建 AgentModelClient；复用现有 URL、HTTPS/loopback、API key 和重定向安全函数。
2. 为 OpenAI-compatible、Anthropic、Gemini 建立独立 request/stream parser adapter。
3. 统一模型事件和错误：文本增量、tool call 增量、usage、完成、拒绝、限流、超时、断流。
4. 添加模型能力探测；没有结构化工具或连续两次 schema 失败时只允许 Ask 模式。
5. 编写固定系统合同：用户目标是最高可变输入；网页和工具结果均为不可信数据。
6. Planner 先生成 `TaskPlan`，通过浏览器 schema 校验后才可进入用户确认。
7. 每轮只暴露当前任务批准的最小工具集合；高风险工具在未批准时根本不进入模型工具表。
8. 增加 token、回合、工具、时间和重试预算；取消必须中断网络请求和流解析。
9. 模型 fallback 只允许从一个已配置 provider 切到另一个用户已批准 provider，不能静默外发。

### Mock 覆盖

- 正常单工具、连续工具、并行只读工具、流式参数分片。
- 重复 tool id、未知工具、额外字段、超长参数、非法 UTF-8、深层 JSON 和大整数。
- HTTP/HTTPS、loopback、IPv4/IPv6、userinfo、query、fragment、端口和重定向。
- `401/403/404/408/429/5xx`、连接重置、半包、超时、取消和 provider 返回 HTML。
- 页面结果中的注入文本要求更换工具、扩大 origin、读取秘密或忽略用户。

### 退出条件

- 三类云 provider 和本地 compatible mock 的合同测试通过。
- 同一工具 schema 在不同 provider 下规范化结果一致。
- 不支持工具调用的模型准确降级，不出现“文本看起来像 JSON 就执行”。
- mock 捕获证明 secret 和未批准 BrowserMetadata 未进入请求。

## 7. M3：Actor Bridge、页面观察与 WebMCP

- 预计：6–9 人日
- 依赖：M0、M1、M2
- 目标：把 Planner 的页面工具安全转换为 Chromium Actor 动作。

### 步骤

1. 实现 `AegisActorBridge`，为每个 AgentTask 创建和销毁一个 ActorTask。
2. 建立 Aegis tab handle 与 Actor controlled tabs 映射；同一 tab 同时只允许一个写任务。
3. 映射 observe、navigate、click、type、select、scroll、drag、wait、history 和 media。
4. 复用 Actor 的 AttemptLogin、AttemptFormFilling 和 AttemptOtpFilling，但将它们登记为受保护工具。
5. 页面观察输出必须包含 Profile、tab、frame、DocumentToken、URL、时间、内容预算和来源标签。
6. 对截图和文本做尺寸、数量、敏感字段、跨 frame 和 cloud egress 裁剪。
7. 用户在受控 tab 交互时暂停任务；恢复前重新观察，不继续旧节点动作。
8. 接入 ScriptTool/WebMCP；工具 schema、描述和返回都标记为不可信，并执行同源和权限检查。
9. 坐标兜底仅对低风险动作开放；在执行点加入截图、可见性、遮挡和文档复查。
10. 映射 Actor Journal 为 Aegis 事件，但不把原始页面秘密写入日志。

### 测试 fixture

- 普通表单、动态 DOM、Shadow DOM、iframe、跨源 iframe、SPA 导航和 history 导航。
- 节点移动、遮挡、消失、页面重载、相同 URL 新文档和 tab 被用户关闭。
- 登录、OTP、文件选择、下载触发、弹窗、beforeunload 和系统对话框。
- WebMCP 正常工具、schema 偷换、注销/重注册竞态、跨源暴露和恶意返回。
- Prompt injection 页面、不可见文字、ARIA 误导、按钮文本与实际提交不一致。

### 退出条件

- 低风险网页任务可连续执行 30 次，无悬挂任务、重复动作或跨 tab 操作。
- 导航、用户接管和 DOM 变化后旧动作 100% 被拒绝。
- 登录秘密、OTP 和受保护表单值不出现在模型请求、Aegis Journal 或 WebUI。
- WebMCP 关闭或不可用时，代表性 fixture 能通过语义节点回退完成。

## 8. M4：浏览器原生工具

- 预计：10–15 人日
- 依赖：M1；可与 M2/M3 部分并行
- 目标：让 Agent 管理浏览器自身，而不是通过模拟 UI 点击管理页。

### M4.1 标签页、窗口和工作区（3–4 人日）

步骤：

- 实现 list/create/activate/close/group 和 workspace save/restore。
- 任务只可关闭自己创建或用户明确纳入范围的 tab。
- 保存工作区时剥离 URL userinfo，对 query/fragment 按数据策略处理。
- 关闭前检测未提交表单、活跃下载、beforeunload 和最后一个正常窗口。

验证：

- 100 个标签的列出/分组/恢复结果稳定，顺序和 pinned 状态正确。
- 用户手动移动、关闭或新建 tab 后旧 revision 拒绝应用。
- 不跨 Profile、窗口和 task scope 操作。

### M4.2 收藏夹计划、检查和撤销（4–6 人日）

步骤：

- 读取 BookmarkModel，生成稳定 node identity、树 revision 和 snapshot hash。
- 本地重复 URL、域名和标题规则先分类；模型只接收任务批准字段。
- URL 检查实现 HEAD → 有界 GET fallback、重定向链、DNS/TLS/HTTP 状态和限流退避。
- 输出 dry-run diff；应用前再次比较 tree revision。
- 使用 `BookmarkUndoService::undo_manager()` 分组一次任务的全部变更。
- 处理 local/account store 移动可能重分配 UUID 的情况，不能以旧 UUID 验证最终树。

验证：

- 500 条 fixture：重复、同名不同 URL、重定向、401/403/404/410/429、超时、DNS/TLS。
- 不把 `403`、`429`、认证页和超时判成可删除死链。
- 应用后树等于计划；一键 Undo 恢复精确父节点、顺序、标题和 URL。
- 用户在预览后修改任一相关节点时，应用必须冲突失败。

### M4.3 下载与文件能力（3–5 人日）

步骤：

- 复用 DownloadManager/DownloadItem 实现 list/start/pause/resume/cancel/open。
- 下载来源工具输出官方/项目/镜像分类和重定向链；不把模型判断当来源证明。
- 下载验证读取最终文件大小和哈希；签名验证按平台可用能力分级显示。
- file upload 使用一次性 capability token；用户通过标准 file picker 选文件。
- 保存 PDF 使用 Chromium 标准路径；Agent 不获得通用文件系统权限。

验证：

- Range/非 Range、重定向、取消、暂停/恢复、危险文件提示和重复 action id。
- 有/无官方 hash、错误 hash、下载中内容变化和目标文件已存在。
- 文件 token 单次、限时、限 origin 使用；任务日志无完整路径和文件内容。

### M4 退出条件

- 标签、收藏夹和下载工具不依赖打开相应 WebUI 页面。
- 所有写操作有后置验证；收藏夹可撤销；下载幂等。
- 代表性 500 收藏夹和 100 标签 fixture 达到正确性与性能门。

## 9. M5：PolicyBroker、审批、ResultVerifier 与恢复

- 预计：6–9 人日
- 依赖：M1、M3、M4
- 目标：建立 Agent 的可信计算基座，关闭越权、重放和“模型说成功”的缺口。

### 步骤

1. 实现 R0–R3 和禁止级分类；风险来自工具语义、字段类型、站点和外部副作用，而不是按钮文字。
2. 实现任务授权收据与动作授权收据：参数摘要、origin、document、目标、TTL、次数和哈希。
3. 实现文档、节点、URL、文件 token 和 Browser data revision 的 TOCTOU 检查。
4. 实现 ResultVerifier：每类工具有确定性后置条件和标准错误。
5. 实现 action id 幂等表和恢复规则；外部副作用永不自动重放。
6. 实现用户接管协议：暂停 Actor、允许用户操作、重新观察、废弃旧计划步骤。
7. 实现跨域和重定向策略；新 origin 未在 task scope 时返回重新授权。
8. 接入 Safe Browsing、lookalike、Aegis phishing 和 Actor site policy；任一阻断不允许模型绕过。
9. 对模型出站数据执行结构化裁剪和预览；Secret 类始终拒绝。
10. 建立安全事件日志，但不记录秘密、完整 query、表单值或页面正文。

### 对抗测试

- 页面提示注入、WebMCP tool poisoning、工具返回注入和隐藏指令。
- 模型伪造工具结果、未知 action id、重复提交、参数偷换和过期 approval。
- 同 URL 新文档、SPA 节点复用、iframe 导航、tab 替换和 renderer crash。
- DNS rebinding、外部协议、私网/IP、lookalike、恶意重定向和错误页。
- 文件 token 跨站复用、Profile 串用、任务串用和过期复用。
- 购买按钮、发送按钮或删除按钮伪装成普通导航。

### 退出条件

- 攻击样例不能扩大 origin、工具、数据、文件或风险权限。
- 所有 stale document/node/approval/file capability 测试拒绝率 100%。
- ResultVerifier 能识别“模型声称成功但页面/浏览器未改变”。
- 崩溃恢复不重复写收藏夹、下载或页面外部副作用。

## 10. M6：Agent 侧栏与浏览器入口

- 预计：6–9 人日
- 依赖：M1；完整联调依赖 M2/M5
- 目标：提供用户始终可见、可控和可理解的原生 Agent UI。

### 步骤

1. 注册独立 SidePanel entry；使用 untrusted WebUI + 窄 Mojo PageHandler。
2. 实现“问 / 做 / 自动”、目标输入、快捷工作流和当前页面上下文选择。
3. 实现 Task Plan 卡：域名、数据类别、工具、预算、provider/host/model 和风险摘要。
4. 实现执行时间线和结构化事件：观察、工具、验证、重试、审批、接管和失败。
5. 实现审批卡，不允许 WebUI 自己决定批准内容；按钮只提交 approval id。
6. 实现暂停、继续、接管、停止和撤销入口。
7. 在受控 tab 显示明显但不打扰的 Agent 指示；可复用 Actor tab indicator，不复用 Glic 品牌 UI。
8. 增加工具栏按钮、快捷键、右键菜单和 `chrome://aegis` 跳转。
9. 实现中文简体、中文繁体、英文；覆盖浅色/深色、200% 缩放、键盘和读屏。
10. 模型和网页输出只按纯文本或白名单结构渲染，开启 Trusted Types/CSP，不使用 `innerHTML`。

### UI 测试

- WebUI TypeScript 单测：事件 reducer、审批状态、任务恢复和错误展示。
- Browser test：SidePanel service、Mojo 权限、Profile 隔离和导航生命周期。
- Interactive UI test：入口、键盘、暂停、接管、停止、审批和任务结束。
- Browser/Computer Use：真实 App 中验证宽/窄窗口、深浅色、三语、缩放和焦点顺序。
- 恶意模型 Markdown/HTML、超长文本、RTL、零宽字符和链接伪装不得破坏 UI 或执行代码。

### 退出条件

- 用户从工具栏到启动任务不超过 3 次操作。
- Agent 执行期间始终有可见状态和停止入口。
- 任务卡显示的数据目的地与 mock server 实际请求一致。
- UI 不把“已计划”“模型声称完成”或“旧产物”显示为实际完成。

## 11. M7：四个工作流与浏览器内监控

- 预计：9–13 人日
- 依赖：M2–M6
- 目标：用真实场景验证平台，而不是为每个网站写一次性自动化。

### M7.1 深度研究（2–3 人日）

- 实现来源计划、并行只读 tab、结构化提取、去重、冲突和引用。
- 本地 fixture + 公开站点各执行一组；网络不稳定时保留部分结果。
- 输出区分事实、来源观点、Agent 推断和未验证项。

### M7.2 浏览器管家（2–3 人日）

- 实现收藏夹分类模板、重复项、重定向建议和失效状态汇总。
- 实现标签页聚类、重复页、工作区保存/恢复。
- 所有浏览器写入使用 preview/apply/verify/undo 四阶段。

### M7.3 安全下载（2–3 人日）

- 实现官方来源优先、平台/架构/版本提取和来源证据。
- 启动下载并等待 DownloadItem；校验可用 hash/signature。
- 与现有并行下载、Metalink/BT UI 保持边界，不增加视频解析或 DRM 绕过。

### M7.4 购物助手（2–3 人日）

- 实现商品 schema、总价组成、卖家、配送和退货条件比较。
- 支持选择规格、数量、优惠券和加购。
- 进入最终确认页后触发 UserTakeover；通用点击工具阻止最终购买。
- 使用本地商店 fixture 验证 R3 类型化提交，但 Release feature flag 保持关闭。

### M7.5 监控（1–2 人日）

- 实现价格、库存、页面文本/哈希和 URL 状态监控。
- 浏览器运行时按最小间隔和退避执行；浏览器关闭后不运行。
- 重启后每个任务最多补做一次，不高频追赶。
- 通知包含变化事实和来源，不自动触发后续购买或下载。

### 退出条件

- 四个工作流均通过本地确定性 fixture 和至少一组真实公开站点验证。
- 网站不支持或页面变化时准确降级为部分结果或用户接管。
- 没有为某个商业站点引入绕过条款、验证码或反自动化的专用代码。

## 12. M8：硬化、性能、构建与 RC 验收

- 预计：8–12 人日，不含冷构建等待
- 依赖：M7
- 目标：把源码功能提升为有身份、可复核的本地 RC 证据。

### 12.1 自动测试门

必须依次通过：

1. `pnpm run contracts:check`
2. `pnpm run quality:fast`
3. Browser 脚本测试和 Agent runtime verifier self-test。
4. `aegis_browser_unittests --single-process-tests`，含全部 Agent 单测。
5. `browser_tests --gtest_filter='AegisAgent*'`
6. `interactive_ui_tests --gtest_filter='AegisAgent*'`
7. Actor 受影响的上游 unit/browser tests。
8. ASan/UBSan 或适用 Chromium sanitizer 的 Agent fixture 子集。
9. 数据库、模型 parser、WebMCP 参数和 URL 检查 fuzz target。

测试命令应在实施时固化到脚本；本计划中的 target/filter 是设计目标，最终以当前 Chromium
GN graph 可解析的实际目标为准。

### 12.2 构建门

- 固定 base 的干净 checkout 能离线重放全部主补丁和 V8 补丁。
- `out/AegisLocalDev` 构建 `chrome`、Aegis 单测和 Agent 测试目标。
- 连续两次增量构建成功，第二次无异常全量重编。
- 新建 non-component Release App；`args.gn` 与当前 `aegis-release.gn` 语义一致。
- Build identity 包含根 SHA、Chromium base/patched SHA、补丁 hash、GN 参数和产物 hash。
- 旧 Release App、旧测试结果和当前源代码证据分开，不覆盖历史证据。

### 12.3 运行时安全门

- 运行 10 个验收场景 A1–A10。
- 运行固定 prompt-injection/tool-poisoning corpus。
- 捕获启动、空闲、研究、收藏夹、下载、购物和监控的出站清单。
- 验证 Agent OFF 时没有 Agent 数据库、调度、模型请求或页面观察。
- 验证 CDP 默认关闭；Agent 不要求打开远程调试端口。
- 验证 OTR/Guest/System Profile 无入口、无服务、无任务和无数据。

### 12.4 性能门

- Agent OFF 相对 Agent 代码不存在的基线无可测空闲 CPU/网络回归。
- Agent ON、无任务、侧栏隐藏时无轮询和持续 CPU 增量。
- 10 页研究、500 收藏夹、100 标签和 3 个监控任务分别测 CPU、内存、网络和完成时间。
- Browser Process 每活动任务新增持久内存目标不超过 20 MiB。
- UI 输入、暂停和停止响应 p95 小于 100 ms；停止后 2 秒内不再启动新工具。
- 用户浏览页面时，Agent 后台只读任务降低优先级且不争用同一 tab。

### 12.5 真实 App 验收

- 使用新建测试 Profile，不复用开发者日常 Profile。
- Browser/Computer Use 验证工具栏、侧栏、右键菜单、快捷键和三语界面。
- 完成研究、收藏夹整理/撤销、安全下载和购物接管。
- 浏览器崩溃/强制退出后验证恢复语义，不重复副作用。
- 连续 20 次启动/退出和 6 站点稳定性门无新 crash、FATAL 或 profile corruption。
- 保存截图、任务日志、出站和性能机器可读证据，但不保存真实秘密。

### 退出条件

- A1–A10 全部通过；任何安全门失败均为 RC No-Go。
- `browser:status` 对源码、overlay、补丁、V8、LocalDev、Release 和身份均无失败。
- 功能、测试、构建、运行时和产物证据可映射到同一源码身份。
- 文档状态更新为“本地 RC 已验证”时仍不自动宣称可公开发布。

## 13. 建议补丁切片

当前序列已有 65 个主补丁。0057–0065 已按实际提交依赖导出，切片如下：

| 预期补丁 | 内容 | 独立回滚边界 |
|---|---|---|
| 0057 | 固定 V8 bytecode shadow 观察提交 | V8 观察层可独立回滚 |
| 0058 | 任务合同、状态机、ToolRegistry、TaskStore、ModelClient、PolicyBroker、Verifier 与浏览器原生工具 | 关闭 Agent 总开关即无运行行为 |
| 0059 | Actor Bridge、精确来源策略、文档绑定与任务生命周期 | 可关闭页面动作，保留浏览器原生工具 |
| 0060 | Side Panel、入口、设置、工作流 UI 与 Browser/UI 测试 | UI 与核心服务可分别关闭 |
| 0061 | 固定区间安全修复、资源打包和 macOS 快捷键接线 | 集中承载审计后加固，便于复核 |
| 0062 | RC 验收后默认显示 Agent 入口，并保留 Profile 执行偏好显式开启 | 入口可发现性与执行授权可独立回滚 |
| 0063 | 为升级前已存在的 Profile 一次性固定 Agent 工具栏入口 | 用户后续取消固定后不会被重复强制恢复 |
| 0064 | Agent WebUI 在首个快照渲染后通知侧栏内容已就绪 | 恢复生产等待路径，避免入口点击后永久不显示 |
| 0065 | 空白页/内部页任务自动直达明确 URL 或使用默认搜索引擎打开任务页；纯浏览器管家任务免网页启动 | 浏览器级任务引导可独立回滚，不放宽精确来源校验 |

每个补丁必须：

- 从前一个 series 状态干净应用。
- 有对应测试或仅为纯资源/文档并说明原因。
- overlay 与 checkout 内容一致。
- 不夹带当前 6 个 Settings 改动和脚本风险研究改动。
- 在提交说明中记录 feature flag、数据边界和回滚方式。

## 14. 测试矩阵

| 层级 | 覆盖 | 证据 |
|---|---|---|
| TS/Core | tool schema、计划、注入样例、bookmark 分类纯函数 | Vitest、类型检查、生成物漂移 |
| C++ Unit | 服务、状态机、策略、模型 parser、工具参数、TaskStore | `aegis_browser_unittests` |
| Actor Unit | bridge 转换、task 状态、旧节点、URL gate | Actor/Aegis gtest |
| Browser Test | Profile、tab、导航、登录、下载、WebMCP、恢复 | `browser_tests` |
| Interactive UI | 侧栏、审批、暂停、接管、停止、撤销 | `interactive_ui_tests` |
| Mock HTTP | provider、重定向、错误、流、URL 检查 | 本地 mock server 记录 |
| Fixture Web | 动态 DOM、iframe、表单、商店、下载和注入 | 本地 HTTPS fixtures |
| Runtime | 真实公开网页和浏览器数据副本 | `verify-agent-runtime.mjs` + 截图 |
| Security | secrets、prompt injection、tool poisoning、TOCTOU | 固定 corpus + 机器可读结果 |
| Performance | idle、研究、500 收藏、100 tabs、监控 | Aegis ON/OFF 采样 JSON |
| Build/Artifact | patch replay、LocalDev、Release、identity | `browser:status` + manifest/hash |

## 15. 代表性验收脚本

### A1：研究

1. 从新 Profile 打开本地搜索 fixture。
2. 提问一个需要 10 个来源的事实比较问题。
3. 其中两个页面包含冲突数字，两个页面包含恶意 Agent 指令。
4. 验证报告引用、冲突、推断和未验证项。
5. 检查未调用写工具、未扩大域名、未发送秘密。

### A2/A3：收藏夹

1. 导入固定 500 条书签数据集并记录树 hash。
2. 运行分类和 URL 检查，只生成预览。
3. 用户在预览后手动修改一个节点，验证旧计划冲突失败。
4. 重新生成并应用，验证目标树。
5. 一键 Undo，验证原树 hash、父节点、顺序、标题和 URL。

### A4：下载

1. 请求寻找一个同时提供 macOS arm64/x64 和 hash 的 fixture 软件。
2. 混入广告页、错误架构、旧版本和恶意重定向。
3. 验证选择官方来源和正确架构。
4. 完成下载和 hash 检查；错误 hash 必须失败。
5. 验证下载由 DownloadItem 管理并出现在原生下载中心。

### A5：购物

1. 三个商店 fixture 返回不同标价、税费、运费和退货条件。
2. Agent 生成总价比较并把指定商品加入购物车。
3. 结账页在最后一步修改价格，验证旧确认失效。
4. Agent 显示新金额并交还用户，不能通过通用点击提交购买。

### A6/A7：恢复与接管

1. 在多站研究中暂停、手动更改 tab，再恢复。
2. 验证旧观察和旧节点失效。
3. 在下载已开始后强制退出浏览器并重启。
4. 验证不重复创建下载；待确认动作过期。

### A8–A10：隔离、模型和出站

1. 两个普通 Profile + OTR + Guest 同时运行。
2. 验证数据和任务不串，禁用 Profile 无入口。
3. mock provider 返回畸形和恶意 tool-call，全部被 schema/policy 拒绝。
4. 捕获空闲与任务出站，验证没有 Glic/Google 模型或新遥测请求。

## 16. 风险清单与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| Actor 与 Glic/OptimizationGuide 耦合 | 意外出站、更新维护困难 | M0 Spike + adapter + 出站测试；不直接启用整套 Glic |
| WebMCP 仍是 Draft | API 变化或站点稀少 | 独立 flag；语义节点回退；记录 spec/Chromium 版本 |
| Prompt injection/tool poisoning | 越权和数据泄露 | 结构化信任标签、最小工具集、确定性 PolicyBroker、攻击 corpus |
| 模型 provider 行为差异 | tool-call 解析不一致 | 独立 adapter + mock fixtures + 能力探测 + Ask-only 降级 |
| DOM/页面变化 | 误点、循环和失败 | DocumentToken、节点复查、重试上限、用户接管 |
| 浏览器数据误改 | 收藏夹/标签丢失 | dry-run、revision、grouped undo、禁止自动删除 |
| 重启重复副作用 | 重复下载/提交 | action id 幂等、外部副作用不自动重放 |
| 补丁维护成本 | Chromium 更新冲突 | 小补丁切片、复用上游 Actor、patch replay 门 |
| 性能和后台请求 | 浏览变慢、站点压力 | 并发/预算/退避、侧栏隐藏无轮询、ON/OFF 门 |
| 交易与账号责任 | 金钱或法律后果 | v1 最终提交用户接管；R3 pilot 独立批准 |

## 17. No-Go 条件

出现以下任一情况，停止推进对应里程碑：

- 需要打开非 loopback CDP 或向模型提供任意代码执行才能完成主流程。
- Actor 复用会不可关闭地启用 Google/Glic 模型请求或隐式遥测。
- Secret 值可能进入模型、WebUI、日志或 TaskStore。
- 用户无法随时暂停/停止，或停止后工具继续执行。
- 导航或页面变化后旧节点/审批仍可执行。
- 收藏夹整理不能预览和真实撤销。
- 崩溃恢复可能重复下载、提交表单或执行外部副作用。
- OTR/Guest/System Profile 可以创建任务或读取普通 Profile 数据。
- Agent ON/OFF 性能和出站门没有代表性运行时证据。
- patch series 不能从固定 base 干净重放，或 Release 身份与源码不一致。

## 18. 最终交付物

源码交付：

- Agent Profile service、模型协议、ToolRegistry、Actor bridge、Browser tools、PolicyBroker、
  TaskStore、调度器和四个工作流。
- 专用侧栏、工具栏/右键入口和三语资源。
- 可重放 Chromium/V8 patch series 与完整 overlay。

验证交付：

- TS/C++/browser/interactive UI/security/fuzz/performance 测试。
- `verify-agent-runtime.mjs` 与确定性本地 fixture。
- A1–A10 机器可读结果、截图、出站与性能证据。
- 新 LocalDev/Release build identity 和产物 hash。

文档交付：

- 架构、工具合同、权限模型、数据保留、模型配置和用户手册。
- 已知限制、受支持平台、WebMCP 实验状态和交易边界。
- 当前实现进度与发布 No-Go/Go 结论。

## 19. 用户确认后的第一轮动作

收到确认后只开始 M0，不直接开发全部功能：

1. 重新审计两个 checkout 和当前未提交改动。
2. 建立独立 Agent 工作区与基线报告。
3. 完成 Actor 集成 Spike、Profile 隔离测试和出站捕获。
4. 汇报 M0 Go/No-Go、实际依赖和必要的计划调整。
5. M0 Go 后才进入 M1；不会自动推送、发布或使用生产密钥。

建议确认语句：`确认按 Aegis Browser Agent v1 方案开始本地 M0/M1，暂不发布。`
