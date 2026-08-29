# Aegis Browser Agent v2 P0 Playwright MCP 基线报告

- 日期：2026-08-30
- 候选：`@playwright/mcp@0.0.79`
- Playwright Server：`1.63.0-alpha-2026-08-05`
- 浏览器：本机 Google Chrome，headless，逐 run 独立 Profile
- 模型调用：0
- 判定：**Partial；页面动作基线可用，但不能作为安全控制面**

## 结果

E0–E11 各运行一次确定性矩阵：

- 通过：10 个（E0–E6、E8、E10、E11）。
- 安全失败：1 个（E9 跨 origin 重定向）。
- 不支持：1 个（E7 浏览器原生收藏夹工具）。
- 每个 run 均使用独立 `.artifacts/.../profile/`，结束后未发现引用该 Profile 的残留进程。
- 动态页面 E2 完成 `navigate → snapshot → click by ref → snapshot → assertion`，约 1.0–1.5 秒。
- E4/E5 的 fixture 密码和 OTP 不写入事件；事件只记录敏感类型与 `[REDACTED]`。
- E6 下载的纯文本 fixture 被保存但未运行。
- 汇总证据：`.artifacts/aegis-agent-v2-prototypes/p0-matrix-summary.json`（本地保留，不提交）。

## 关键安全发现

MCP server 向客户端暴露 24 个工具，其中包含：

- `browser_evaluate`；
- `browser_run_code_unsafe`（RCE 等价）；
- `browser_file_upload`。

Harness 只允许 8 个导航、快照、语义点击/输入、标签和关闭工具，并实际验证上述三个危险工具
均在客户端调用前被拒绝。因此 P0 能作动作基线，但 server 自带工具清单不能直接交给正式 Agent。

E9 中，页面从允许的 fixture origin 返回 302 到未允许的 `https://127.0.0.1:1/blocked`。
Playwright MCP 的 `allowedOrigins` 没有阻止该重定向；浏览器尝试访问后进入
`chrome-error://chromewebdata/`。目标服务不可达不等于安全策略拦截，因此 E9 保持失败。这与
上游文档“origin 参数不影响 redirect”的声明一致。

## 能力边界

- E7 只能观察收藏夹 fixture 页面，无法调用 Chromium `BookmarkModel`，明确记为 unsupported。
- P0 没有自主规划、搜索选源、视觉回退或原生任务工作区，不能回答“Agent 是否像浏览器 Agent”。
- P0 证明 Accessibility ref 动作足以支撑统一 Harness，也证明正式 v2 必须在 Browser Process
  内做导航/重定向和原生能力授权，不能把 MCP allowlist 当作安全边界。

## 后续采用建议

采用它的快照、稳定 ref、动作结果和确定性验证协议；拒绝它的通用工具暴露和外部 CDP 权限面。
P1/P2 继续使用相同场景与证据格式，E9 失败不得通过放宽 allowlist 或忽略 TLS 修复。
