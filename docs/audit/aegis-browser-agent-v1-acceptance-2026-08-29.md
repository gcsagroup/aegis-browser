# Aegis Browser Agent v1 macOS 本地验收记录

- 日期：2026-08-29
- 结论：**macOS 桌面端本地 RC 已验证；公开发行仍为 No-Go**
- 平台范围：macOS arm64，本地 Chromium build-tree，新建隔离 Profile
- 不在范围：iOS（按用户要求跳过）、Android（后置）、Windows/Linux 运行时、真实购买、
  生产模型密钥、Developer ID、Apple 公证、安装包分发、推送或发布

## 1. 源码与产物边界

Agent 代码在隔离工作区完成，不修改用户原有 dirty 工作区。验收时的代码身份如下：

- 根仓库交付提交：`c142f041a4f51acb25725db3961e4ec57789d17a`
- Chromium：`f810a39ebc9efa9c7e94ab003439e05460a9ca8e`
- V8：`9c0b1f276ba116e8b25a55466207e6586b44be16`
- Chromium 固定 base：`ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`
- 补丁谱系：65 个 Chromium 顶层补丁 + 2 个 V8 补丁

65 个 Chromium 补丁已在临时 index 中从固定 base 完整重放，重放树与 checkout HEAD 树
一致，树哈希均为 `46a3200e712329c177a5295baeabcfceeb48cc32`。严格
`--whitespace=error` 首次被历史补丁 0012 的 EOF 空白阻断；保留失败证据后用
`--whitespace=nowarn` 重放并完成精确树比较。该例外只说明历史补丁格式，不替代树、提交
顺序、stable patch-id 和 overlay 一致性门。

最终 build-tree 清单由本记录提交后的增量构建生成，避免文档自引用改变根提交。以
`out/AegisRelease/.aegis/build-manifest.json` 为机器可读事实源；要求
`qualification=candidate`、`releaseBoundary=internal-local-only`、根/Chromium/V8 均 clean、
65 + 2 补丁精确匹配、overlay 精确匹配、`localSourceArtifactBinding=true`。该构建只使用
ad-hoc 本地签名，`trustedBuildAttestation=false`，不是可分发产品包。
本次最终 manifest SHA-256 为 `da6e05df833e96435f4d2c6401ab473a76ce21d0ca487c140d23062510ac8c01`，
App 树 SHA-256 为 `36315c55f6fc926acb0177c1953f5da610d8ec049b7522ee23e34f3e4e1f30e6`。

## 2. 验证总览

| 验证层 | 结果 | 证据边界 |
|---|---:|---|
| Core Agent gtest | 50/50 | 状态机、Planner、Policy、Verifier、TaskStore、WebMCP、恢复 |
| 模型客户端 gtest | 5/5 | loopback、provider 格式、取消、密钥与错误脱敏 |
| Aegis common gtest | 78/78 | 含 Agent 稳定入口默认开启、WebMCP/交易默认关闭 |
| Browser Aegis unit gtest | 115/115 | Agent 与既有 Aegis 服务组合；三组共 170 次测试执行 |
| Browser tests | 7/7 | 新/旧 Profile 入口固定、真实 Action、生产就绪等待、隔离、untrusted side panel、scope、空白页自动开页、收藏夹免网页启动 |
| Interactive UI | 2/2 | macOS `Cmd+Shift+A`、设置入口、侧栏、模式控件、监控按钮与关闭路径 |
| V8 | 3/3 | bytecode shadow 有界观察 |
| ASan/libFuzzer | 3 个目标 × 1000 次 | 共 3000 次，无 crash |
| 根仓库快速门 | 20 个 Vitest 文件、130 tests | lint、typecheck、tests、脚本合同、构建 |
| 生命周期 | 20/20 | 同一 App 每轮 ready → TERM → stopped，无残留主进程 |
| 真实桌面界面 | 通过 | 最终 App 从 `chrome://newtab` 实际打开 Agent，提交空来源任务后自动切到 `https://example.com`，标题为 `Example Domain` |

机器可读或可视证据保存在 `.artifacts/aegis-agent-v1/`，包括 gtest XML、browser/UI
结果、V8 结果、fixture 自测、netlog 和桌面截图。`.artifacts` 是本地证据，不属于发布物。

## 3. A1–A10 结果

| 编号 | 结果 | 通过证据与边界 |
|---|---|---|
| A1 十来源研究 | **通过（本地确定性夹具）** | 10 个来源、2 个冲突值、2 个 prompt-injection 页面；Planner 只接受收窄 scope，外部内容标记为不可信，完成结果只能引用安全来源 URL。未使用真实公开站点。 |
| A2 500 条收藏夹分类 | **通过（夹具 + 原生工具测试）** | 固定 500 条数据集、预览绑定 snapshot/plan、应用前 revision 检查、grouped undo；后续书签编辑会使旧撤销收据失效。没有读取或修改用户真实收藏夹。 |
| A3 失效链接检查 | **通过** | HEAD → 有界 GET fallback、403/429/410/timeout 分类；并发、超时与退避有界；loopback、私网、link-local、带凭据 URL 和 DNS 后私网请求被阻止，不把 403/429/timeout 当作可删除。 |
| A4 官方软件下载 | **通过（本地 arm64/x64 夹具）** | arm64/x64 内容及 SHA-256 不同；下载必须由 `DownloadItem` 持有，停止任务取消仍活跃的 Agent 下载；无预期强哈希时只能标记未验证，不能自动打开。未下载互联网软件。 |
| A5 跨站购物比较 | **通过（本地三商店夹具）** | 三个总价为 11300/11700/11400 minor units；结账价格变化使旧证据失效；金额采用结构化精确比较；提交/付款控件被阻止并进入用户接管。未登录商店、未下单、未付款。 |
| A6 中断与重启 | **通过** | TaskStore 只保存脱敏元数据；只读任务可恢复；旧批准、owned tab 和副作用不重放；monitor catch-up 合并为一次且稳定身份不重复持久化。 |
| A7 用户接管 | **通过** | pause/resume/takeover 状态机、最新 DocumentToken/origin/node 复核、旧观察失效、停止后取消 owned Actor task 和活动下载；浏览器验证结果，模型不能宣告成功。 |
| A8 Profile 隔离 | **通过** | 两个 Regular Profile 使用独立服务和数据库；OTR、Guest、System 无侧栏 entry、无服务、无任务；browser test 2/2 覆盖。 |
| A9 模型异常 | **通过** | OpenAI/Anthropic/Gemini 正常与流式格式；畸形、重复/未知工具、越界数组、过量事件、重定向、timeout、wrong-tool、流中断均 fail closed；无效配置不回退到默认云端点。 |
| A10 出站审计 | **通过（Agent 增量口径）** | 隔离 netlog 只见 loopback fixture 和 Chromium 基线的 `clients2.google.com/time`、`accounts.google.com/ListAccounts`；未见 Agent 模型、Glic、Agent telemetry 或下载云主机。结论是“Agent 没有新增隐式出站”，不是“整个 Chromium 零出站”。 |

## 4. 真实桌面 UI 验收

61 补丁候选在不传 feature flag 时隐藏 Agent，这正是用户无法发现入口的根因。0062 已将
通过 RC 验收的 Agent、PageActions、BrowserTools 和 Workflows 入口层改为默认开启；
Profile 的 `aegis.agent_enabled` 仍默认关闭，因此显示入口不会启动模型、工具或监控。
WebMCP 与 Transaction Pilot 继续默认关闭。

当前 65 补丁源码已通过不带 Agent feature flag 的浏览器测试，验证普通 Profile 中：

- Agent SidePanel entry 已注册；
- Browser action 可见且默认固定到工具栏；
- 升级前已有 Profile 会一次性固定入口；用户之后取消固定不会再次被强制恢复；
- Profile 尚未开启时 Agent 服务不会创建；
- 开启后快捷键、设置入口、侧栏和控件交互继续 2/2 通过。
- 工具栏 Action 在不调用 `SetNoDelaysForTesting(true)` 的生产等待路径中可以完成加载并显示。

0064 修复了此前真实点击无响应的直接根因：Agent WebUI 首次快照渲染后没有调用
`TopChromeWebUIController::Embedder::ShowUI()`，`SidePanelEntryWaiter` 因而一直等待内容就绪。
现已通过 Mojo `ShowUI` 方法在首帧可用后发送通知，保留正常的侧栏就绪门，而不是关闭等待。

0065 移除了“必须先打开网页”的当前页助手限制：研究、下载和购物任务从空白页或内部页启动
时，目标内有明确 HTTP(S) URL 就直接打开，否则使用用户当前默认搜索引擎生成并打开任务页；
收藏夹整理等纯浏览器管家任务直接读取浏览器原生数据，不额外打开无意义网页。自动生成的目标 URL
仍先由浏览器验证，并绑定到精确 origin 和任务 tab，未改成通配来源。最终修正同时让内部页的活动
tab id 可供 composer 使用，避免后端已支持自动开页、前端按钮却仍被禁用；browser test 明确断言
`about:blank` 上的生成计划按钮可点击。

此前显式开发 flags 下的真实桌面验收仍证明完整界面可操作：

- 设置页显示“浏览器智能体”、启用状态、逐项批准和付款接管提示。
- 完整 Agent WebUI 显示询问/执行/自动化、目标、精确 origin、四个工作流、批准参数与
  指纹、暂停/继续/接管/撤销/停止、时间线和监控区。
- Computer Use 实际把模式从“询问”切换到“执行”，控件状态同步。
- 65 补丁最终 App 重启后，Computer Use 实际点击固定的 Agent 图标，侧栏出现
  `chrome-untrusted://aegis-agent/`，并显示完整控件；关闭侧栏后再次点击也成功。
- 最终重构建 App 从 `chrome://newtab` 打开侧栏时，“自动找网页并生成计划”按钮可用；来源留空并
  提交 `Open https://example.com and report the page title` 后，浏览器自动创建前台任务标签页并
  显示 `Example Domain`。该 smoke 只验证浏览器级自动导航，随后主动停止了计划任务，没有执行工具
  或外部写操作。

截图：

- `.artifacts/aegis-agent-v1/native-agent-settings.jpeg`
- `.artifacts/aegis-agent-v1/native-agent-ui.jpeg`
- `.artifacts/aegis-agent-v1/native-agent-auto-open.png`

临时 Profile 已移入 macOS 废纸篓，未清空；未复用或清理用户日常 Profile。

## 5. 发布结论与剩余风险

本轮完成的是 **macOS 本地 RC**：源码、补丁、核心安全合同、确定性工作流夹具、原生测试、
构建和桌面可视 UI 已形成同一实现链。以下门禁仍保持 No-Go：

1. 没有 Developer ID、正式产品身份、公证、安装 App 与分发渠道验收。
2. 没有真实站点兼容性、账号登录、支付或真实交易证据；v1 也不授权 Agent 提交付款。
3. iOS 已跳过；Android、Windows、Linux 运行与设备证据未完成。
4. A10 只证明 Agent 增量出站；Chromium 自身仍存在基线 Google 请求，需要独立产品级
   egress 治理才能声明完整无遥测。
5. WebMCP 仍是实验能力；Transaction Pilot 永久默认关闭，不能随 RC 自动开启。

因此：**Aegis Browser Agent v1 的 macOS 本地开发目标完成；公开发行、真实交易和跨平台
目标未获授权且未完成。**
