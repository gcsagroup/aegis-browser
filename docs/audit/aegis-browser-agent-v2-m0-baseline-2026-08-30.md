# Aegis Browser Agent v2 M0 基线与第三方审计

- 日期：2026-08-30
- 分支：`codex/aegis-browser-agent-v2-prototypes`
- 原型起点：`41244fa21fbfb42c514dfc0192ded6edd24f3b8c`
- 根仓库基线：`main@cb35227fcc66f4a451fc93d4b755f3beb0f3a13b`
- 状态：**M0 Go；只允许隔离原型，不代表正式 v2、产品构建或发布 Go**

## 结论

P0–P4 可以在独立工作区继续比较，但所有第三方候选都必须通过 Aegis 启动器限制 Profile、
网络、遥测、代码执行和证据输出。Browser Use、Stagehand 和 Skyvern 不能直接取得用户日常
Profile，也不能成为正式产品的通用 CDP 权限根。

当前进程未发现 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`GOOGLE_API_KEY`、
`BROWSER_USE_API_KEY` 或 `BROWSERBASE_API_KEY`。M1 和 P0 不受影响；P1/P2 的真实模型
实验在用户从进程环境提供开发密钥前保持未运行，且不会自动改用其他云服务。

## 基线与隔离

- Chromium 固定版本：`151.0.7922.77`。
- 浏览器补丁：67 个顶层 Chromium patch，2 个 V8 patch。
- 主工作区：`/Users/lazy/Projects/GCSA-aegis`，保持 `main`，不承载原型依赖和产物。
- 原型工作区：`/Users/lazy/Projects/GCSA-aegis-agent-v2-prototypes`。
- 原型分支：`codex/aegis-browser-agent-v2-prototypes`。
- Node.js：`25.2.1`；pnpm：`9.15.0`。
- Python：P1 使用独立环境；Skyvern 因版本上限固定使用系统现有 Python `3.13.9`，不使用
  Python `3.14.6`。
- Docker：`29.5.3` 可用，但 M0/M1 不启动常驻容器或服务。
- 证据、临时 Profile、模型响应和截图只写入被 Git 忽略的 `.artifacts/`。

## 锁定候选与审计结论

| 候选 | 锁定版本 | 许可证 | M0 结论 |
|---|---:|---|---|
| Playwright MCP | `0.0.79` | Apache-2.0 | P0 可用；origin 参数不是安全边界，仍需 Harness 拦截导航和重定向 |
| MCP TypeScript SDK | `1.30.0` | MIT | 只作为 P0 stdio 客户端；不开放额外 server/tool |
| Browser Use | `0.13.8` | MIT | P1 可用；必须关闭匿名遥测和 cloud sync，并隔离配置目录与工作目录 |
| Stagehand | `4.0.2` | MIT | P2 可用；只允许 LOCAL，本地浏览器和显式模型，不允许 Browserbase 默认出口 |
| Skyvern | `1.0.48` | AGPL-3.0 | P3 仅私有原型/体验参考；不得复制或链接其代码进入正式 Aegis Runtime |
| BrowserGym | `0.14.3` | Apache-2.0 | 只作评估组织参考，不进入浏览器产品运行时 |

## 默认外联与强制覆盖

### Browser Use

- 默认匿名遥测使用 PostHog，可能包含任务指令、URL、动作轨迹、错误和结果。
- 默认 cloud sync 与遥测开关相关联。
- 启动器必须强制 `ANONYMIZED_TELEMETRY=false`、
  `BROWSER_USE_CLOUD_SYNC=false`，并使用本次 run 的独立配置目录。
- 必须传入非空 host allowlist；空列表不能被视为“禁止全部”。
- 从无 `.env` 文件的隔离工作目录启动，防止框架自动加载项目环境文件。

### Stagehand

- 必须显式使用 LOCAL 环境、独立 Profile 和确定的模型 provider。
- 不允许 Browserbase API、云 Profile 或默认远端浏览器 URL。
- OpenTelemetry exporter 必须关闭或指向 Harness 拒绝外联的本地 sink；在完成出站断言前不运行
  真实任务。

### Skyvern

- 默认遥测和默认云 API 目的地不得保留。
- 启动器必须强制 `SKYVERN_TELEMETRY=false`、`ENABLE_CODE_BLOCK=false`、
  `DISABLE_CODE_BLOCK_EXECUTION=true`，并显式使用本地 URL。
- 从无 `.env` 文件的隔离工作目录启动。
- AGPL 代码只在独立原型环境运行，不进入正式产品依赖树；对外分发前另做许可证审查。

### Playwright MCP

- 禁止 `--no-sandbox`、忽略 HTTPS 错误、任意 CDP endpoint、任意 init script/page、secret
  dotenv 路径和不受限文件访问。
- MCP 的 allowed/blocked origins 不能阻止全部重定向，因此 Harness 必须在动作前后独立验证
  URL、origin、私网地址和当前文档。

## 原型禁止能力

1. 用户日常 Profile、Cookie、密码库、剪贴板、私人文件和真实账号。
2. Shell、Python、任意 JavaScript、`Runtime.evaluate`、通用文件系统和任意 CDP。
3. 真实登录、发消息、上传、下单、付款、退款或运行下载文件。
4. 框架默认遥测、云 Profile 同步、云凭据仓库和未声明的网络目的地。
5. 密钥写入参数、配置文件、仓库、报告、stdout/stderr、截图或构建产物。
6. 为通过测试关闭 TLS、浏览器 sandbox、Aegis policy 或最终交易接管。

## 清理与停止

- 每个 run 使用 `.artifacts/aegis-agent-v2-prototypes/<run-id>/profile/`，停止后先检查浏览器和
  adapter 子进程全部退出，再保留脱敏证据。
- 原型依赖只安装在 `prototypes/browser-agent-v2/` 的独立 lockfile/虚拟环境范围。
- 不创建 launch agent、系统服务、登录项或常驻 Docker 容器。
- 需要删除本地证据或依赖时另列精确路径与大小，经确认后采用可恢复方式处理。

## M0 退出判定

版本、许可证、安装脚本、已知遥测、默认云出口、Profile 方式和禁止能力已经识别并锁定。
M0 判定 **Go**，下一步进入统一 Harness 与本地 fixture；P1/P2 真实模型运行仍受开发密钥和
出站测试门限制。
