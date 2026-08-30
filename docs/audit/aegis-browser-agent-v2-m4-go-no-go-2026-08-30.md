# Aegis Browser Agent v2 M4 Go/No-Go 报告

- 日期：2026-08-30
- 范围：M0–M4 隔离原型；P0–P4
- 运行边界：本地 fixture、公开只读页面、独立 Profile/工作区
- 结论：**原型比较流程完成；正式 v2 产品 No-Go，必须重新设计自主 Planner/模型适配层**

## 1. 决策摘要

本轮完成了候选审计、统一 Harness、确定性基线、真实模型 smoke/矩阵和 Chromium 原生
Runtime Spike。所有候选都至少触发一项正式开发硬门，因此不计算会掩盖硬失败的加权总分，
也不选择一个“相对最高分”候选直接进入产品。

- P4 证明浏览器进程可以掌握 Profile、任务标签、当前文档、origin、动作预算、视觉回退资格
  和 Stop 撤销，是正式架构应采用的权限根。
- P2 证明 schema 驱动的 DOM 观察和单步语义动作稳定，可作为 Planner 下方的动作语义参考。
- 本轮没有外部自主候选证明 E0–E7：P1 的 E0 为 0/3，P2 没有自主 Planner。
- 因此 M0–M4 的工程流程已闭环，但正式 v2 开发门保持 **No-Go / Re-design**。这不等于放弃
  Browser Agent，也不等于继续修补 v1 执行层。

## 2. 固定评测环境

产品继续允许用户在运行时自定义 provider、model 和 base URL。本表仅是本轮对比控制变量，
不是产品默认值或强制依赖。

| 项目 | 本轮固定值 |
|---|---|
| API | OpenAI-compatible，数值 loopback |
| 推理服务 | `mlx-lm==0.31.3` |
| 模型 | `mlx-community/Qwen3-1.7B-4bit` |
| revision | `3b1b1768f8f8cf8351c712464f906e86c2b8269e` |
| 权重 | `968080210` bytes |
| 权重 SHA-256 | `0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f` |
| tokenizer SHA-256 | `aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4` |
| 浏览器状态 | 每个 run 独立 Profile；不连接用户日常 Profile |
| 密钥 | 未使用云密钥；仓库、日志、报告和构建产物均不保存密钥 |

MLX-LM 的 server 仅用于本地开发评测，不按生产服务使用。模型权重目录未启用 remote code，
也没有把模型、权重或运行日志加入仓库。

## 3. P0–P4 硬门结果

| 候选 | 实测结果 | M4 决策 |
|---|---|---|
| P0 Playwright MCP | E0–E11：10 通过、E9 安全失败、E7 不支持 | 借鉴 snapshot/ref/action；拒绝其通用工具和外部 CDP 控制面 |
| P1 Browser Use | smoke 6/12；E1/E2 各 3/3，E0/E8 各 0/3 | 拒绝作为正式自主内核；未进入 10 轮矩阵 |
| P2 Stagehand | smoke 9/9；E1/E2/E8 的 10 轮矩阵 30/30 | 借鉴 schema 驱动语义动作；没有 Planner，不能单独成为 Agent 内核 |
| P3 Skyvern | 只完成隔离 CLI/依赖/遥测和代码执行审计 | 拒绝进入产品；完整服务栈、云面、代码执行默认值和 AGPL 边界不合适 |
| P4 Aegis Native | 合同 12/12；核心 58/58；BrowserTests 5/5；入口交互 2/2 | 采用 Browser Process 权限合同；当前 Spike 不是完整 Planner/Hybrid 产品 |

P2 的 30 次矩阵总耗时 `178720 ms`，单次中位数 `6364 ms`；E1/E2/E8 中位数分别为
`4982/7079/6364 ms`。全部最终浏览器断言、目的地限制和残留进程检查通过。P1 在加强
结构化输出提示后仍无法完成 E0，不通过增加无界 step 或页面专用硬编码提高结果。

## 4. P4 原生 Spike 实现与验证

P4 在独立 Chromium checkout 中加入最小 `V2RuntimeSpike`：

- 从空白页构造 discovery URL，不依赖用户预先打开相关网页；
- 只接管 Agent 自己创建的标签并纳入任务标签组；
- 每个动作绑定 `profile/task/tab/frame/document/origin/action`，导航后旧文档动作立即失效；
- 拒绝带凭据 URL、开放重定向、跨 Profile 标签和越权原生工具；
- 原生收藏夹接口在 Spike 中只读；
- 只有精确当前文档 DOM 观察失败后，才发放一次性视觉回退资格；
- Stop 撤销 owned state，返回应关闭的任务标签，后续动作继续 fail closed；
- 不提供通用 CDP、Shell、文件系统、秘密读取或任意 JavaScript。

验证结果：

- Chromium 增量构建：`aegis_agent_core_unittests`、`browser_tests`、
  `interactive_ui_tests` 构建成功；
- 核心单测：58/58，其中 v2 Runtime 8/8；
- Aegis BrowserTests：5/5，包括空白页启动、真实标签组、导航失效和 Profile 隔离；
- Agent 入口交互：2/2，命令入口和设置入口均能打开侧栏，控件保持可交互；
- standalone P4 合同：12/12；
- v2 原型 Node 测试：21/21，Python worker 编译检查通过；
- 根仓库：163/163 测试通过，lint、typecheck、build、补丁/脚本合同检查通过。

原生提交为 `bc0ce40b7e`，导出的顶层补丁为
`0068-feat-aegis-add-v2-native-hybrid-runtime-spike.patch`，SHA-256 为
`db5e456e11161e8424a878988fe79fde9b7b5657afa7ca07121c17802091bb0f`。

## 5. 采用、借鉴与拒绝

### 采用

1. P4 Browser Process 原生权限根和 document-bound Action Broker。
2. v1 的 Policy Broker、审批、验证、撤销、Profile 隔离和原生收藏夹/下载资产。
3. Workspace owned tabs、任务标签组、Stop 和逐步证据日志。

### 借鉴

1. P0 的 accessibility snapshot、稳定 ref 和动作结果协议。
2. P2 的 schema 驱动 DOM 观察与单步语义动作。
3. P1 的 observe/act/replan 任务循环形态，但不复用其高权限控制面。

### 拒绝

1. 把 Browser Use、Stagehand、Skyvern 或 Playwright MCP 直接嵌入为正式权限根。
2. 通用外部 CDP、任意 JavaScript、Shell/Python、文件系统、秘密或用户日常 Profile 访问。
3. 由网页文本、模型自述或 MCP origin 参数决定授权、风险和任务成功。

## 6. No-Go 原因与后续重设计范围

进入正式 v2 的计划硬门要求至少一个外部自主原型证明 E0–E7，并证明 Hybrid 相比单一 DOM
或视觉路径有可测量收益。本轮两项均未满足：P1 E0 为 0/3，P2 无 Planner；P4 只证明原生
权限与生命周期合同，没有完成模型驱动的自主发现和真实 screenshot fallback 对比。

下一版正式方案应先研究“用户所选模型 + 严格结构化 tool-call adapter + P2 语义动作 + P4
原生权限根”的最小自主闭环，并重新跑 E0–E11。只有新闭环通过 E0–E7、视觉收益、安全硬门
和真实 UI 后，才提交正式 v2 产品开发计划。provider/model/base URL 仍由用户配置，不写死
本轮模型。

## 7. 边界

本报告完成的是原型评估和架构决策，不授权连接用户日常 Profile、真实账号登录、购物/付款、
私人文件上传、推送、部署、签名、公证或发布。iOS 按用户要求跳过。主分支仍保持 67 个顶层
补丁；0068 仅存在于本地原型分支，等待后续正式方案确认后再决定是否整合。
