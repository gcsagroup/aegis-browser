# Aegis Browser Agent v2 P1/P2 前置报告

- 日期：2026-08-30
- P1：Browser Use `0.13.8`
- P2：Stagehand `4.0.2`
- 状态：**本地无模型前置通过；自主 Agent 对比尚未运行**

## 结论

Browser Use 和 Stagehand 都能在独立 Profile、无云浏览器、无模型调用的条件下启动本机 Chrome、
读取本地 HTTPS fixture 并完整停止。两者都可以继续进入真实模型 smoke，但当前进程没有开发
模型密钥，也没有为本次评测运行注入 provider/model 配置，所以自主阶段保持未运行，不能把
本报告解释为 P1/P2 Agent 成功。产品本身不固定 provider/model，由用户在运行时选择。

## P1 Browser Use

- 独立 Python `3.13.9` venv，直接候选固定为 `browser-use==0.13.8`。
- 安装后共有 103 个 Python 包，venv 约 330 MiB；包含多个模型 SDK、PostHog、Google API、
  文档/PDF 和 macOS UI 依赖，明显不适合进入正式浏览器运行时。
- 强制关闭 `ANONYMIZED_TELEMETRY`、`BROWSER_USE_CLOUD_SYNC` 和默认扩展下载。
- 显式设置 `use_cloud=false`、`disable_security=false`、非空 `allowed_domains`、无权限、无下载、
  无 CAPTCHA solver、无跨域 iframe 和独立配置/Profile/工作目录。
- E1 前置实际读取两个只读研究事实，约 2.85 秒；只观察到 fixture 页面和 favicon 请求，结束
  后无残留 Profile 进程。

发现：Browser Use 默认会启用可自动下载的浏览器扩展、接受下载、自动下载 PDF、CAPTCHA
watchdog 和跨域 iframe。原型必须逐项显式关闭，不能只关闭遥测。

## P2 Stagehand

- npm 直接候选固定为 `@browserbasehq/stagehand@4.0.2`；当前完整原型 `node_modules` 约
  52 MiB，npm audit 为 0 个已知漏洞。
- 只调用 `localBrowser.launch`，不使用 Browserbase；Chrome 使用独立 Profile 和开启的 sandbox。
- `Stagehand.create` 仍是取得 browser context 的必需生命周期步骤；未提供模型，cache 和
  self-heal 关闭。
- `OTEL_SDK_DISABLED=true`，telemetry fallback endpoint 固定为不可达的回环地址，不保留默认
  远端 exporter。
- E2 前置完成 Stagehand snapshot、确定性 locator 点击和第二次 snapshot，约 0.94 秒；只观察
  到 fixture 页面和 favicon 请求，结束后无残留进程。

## 未完成门

以下证据仍为空，M2 不能完成：

1. 同一开发模型下 Browser Use 的自主 E0–E8 smoke。
2. Stagehand DOM/CUA/Hybrid 的模型调用、截图、token、失败恢复和秘密变量对比。
3. 三次 smoke 和通过前置后的 10 次矩阵。
4. 模型出站只包含批准字段、且日志/错误/截图无密钥的动态证据。

真实模型阶段由当前进程环境提供用户当次选择的 provider/model 和对应开发密钥。为了公平，
同一个对比组锁定这一次选择；它不是产品默认值，下一组可以更换。启动器只向对应 adapter
子进程传递该一个密钥变量，不继承 Browserbase key 或其他环境秘密。
