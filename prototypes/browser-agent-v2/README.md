# Aegis Browser Agent v2 原型工作区

该目录用于 P0–P4 隔离比较和 M5 自主闭环重设计，不是正式浏览器运行时。所有任务必须从空白页或 Harness 指定
入口开始，使用本次 run 的独立 Profile，并只访问本地 fixture 或显式公开只读 allowlist。

## 当前范围

- M0：版本、许可证、默认外联和禁止能力已锁定。
- M1：统一场景、事件、断言、脱敏、隔离 Profile 和 HTTPS fixture。
- P0：Playwright MCP 确定性基线；不接模型。
- P1：Browser Use 自主候选；只在隔离 Profile 和 fixture 上运行。
- P2：Stagehand 受控语义动作候选；`plannerAutonomy=false`，不能作为自主内核结论。
- P3：Skyvern 因默认云依赖、遥测、代码执行面和 AGPL 服务边界被停止。
- P4：独立 Chromium Native Hybrid Spike，只复用 v1 安全与原生工具资产。
- M5：Goal Router + 严格 tool-call Planner + accessibility 观察 + Native Broker + Result Verifier。

## Provider / model 配置

产品和原型都不写死 provider 或模型，也不设置隐藏默认值。用户在每次运行时选择：

- `AEGIS_V2_PROVIDER`：当前支持的 API 格式为 `openai`、`anthropic`、`gemini`；
- `AEGIS_V2_MODEL`：用户填写的模型标识；
- `AEGIS_V2_BASE_URL`：可选的兼容 API 地址，远端必须使用 HTTPS。

密钥变量由 provider 映射为 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY` 或 `GOOGLE_API_KEY`，启动器
只向 adapter 传递所选 provider 对应的一个密钥。单次 P0–P4 对比组会锁定当次选择作为控制变量；
这不是产品默认值，下一组和最终用户都可以重新选择。

数值 loopback 的 OpenAI-compatible 地址可不提供云密钥。本次固定对照模型为
`mlx-community/Qwen3-1.7B-4bit` revision
`3b1b1768f8f8cf8351c712464f906e86c2b8269e`；模型目录和 MLX 虚拟环境均被忽略，不进入仓库。

## 本地验证

```bash
cd prototypes/browser-agent-v2
npm test
```

### Chrome DevTools MCP 诊断

研发用 MCP 入口是 `src/devtools-mcp.mjs`，调用锁定版本的 Chrome DevTools MCP，通过
CDP 操作单独启动的浏览器。安装依赖后，把下面的命令和参数填入支持 stdio 的 MCP 客户端。
将示例路径、端口和产物目录换成实际值，先启动待调试的开发站点。

```json
{
  "command": "/绝对路径/node",
  "args": [
    "/绝对路径/GCSA-aegis/prototypes/browser-agent-v2/src/devtools-mcp.mjs",
    "--executable-path=/绝对路径/GCSA Aegis.app/Contents/MacOS/GCSA Aegis",
    "--headless",
    "--lighthouse-skip-about-blank",
    "--chrome-arg=http://127.0.0.1:3000/",
    "--allowed-url-pattern=http://127.0.0.1:3000/*",
    "--filesystem-root=/绝对路径/研发诊断产物"
  ]
}
```

启动器使用独立的临时 Profile，开启 JS 堆诊断，关闭 MCP 遥测、更新检查和 CrUX，
并脱敏网络头。开发站点通过浏览器启动参数预打开。日常浏览器的标签页和登录状态无需接入。

macOS 验证脚本默认使用 `/Applications/Google Chrome for Testing.app`。用
`AEGIS_DEVTOOLS_CHROME` 指定其他浏览器可执行文件的绝对路径即可跑同一套验证。

```bash
npm ci --ignore-scripts
npm run devtools:smoke
```

脚本对本机合成页面执行新建、切换与关闭标签、刷新、导航、返回、快照、表单输入、点击和深色仿真，
读取命中的 CSS 规则、503 响应正文和控制台详情，采集截图、性能 trace、堆快照和 Lighthouse 的
快照与导航报告，并验证跨源重定向未抵达第二个测试服务。断言摘要保存在命令打印的目录下，诊断产物在
`work/`。测试无需模型、登录或凭据。

在 Aegis 上运行 Lighthouse 导航审计时，启动器的 `--lighthouse-skip-about-blank` 参数
跳过准备阶段的空白页，仍会实际导航到目标网址。Chrome for Testing 可以省略该参数，
沿用上游的准备流程。

运行 `npm run devtools:smoke -- --advanced` 可验证日志点、录屏和解包扩展的安装、改版重载与卸载。
录屏检查使用 PATH 中的 `ffprobe` 解码视频。研发客户端可用 `--category-extensions` 启用扩展工具。

从 Aegis macOS 候选 Ver 7.2 (337) 起，调试管道可以打开并检查同一连接在同一 Profile 安装的
解包开发扩展。预装扩展和使用固定密钥的扩展页仍受保护，卸载会撤销页面访问。下面的脚本同时
连接管道和 WebSocket，验证其他连接在页面切换后也无法读取扩展内容。

```bash
AEGIS_DEVTOOLS_CHROME="/绝对路径/GCSA Aegis.app/Contents/MacOS/GCSA Aegis" \
  node src/chrome-devtools-extension-smoke.mjs
```

用 `--category-pwa` 启用 PWA 的安装、启动、系统状态与卸载。上游要求这组工具在未指定
`--allowed-url-pattern` 或 `--blocked-url-pattern` 的会话里运行。macOS 装卸会创建和删除
应用快捷方式，自动化验收可用独立的临时 macOS 家目录。

Aegis macOS 候选 Ver 7.2 (335) 支持 DevTools 网络 Mock。给启动器传入
`--category-network-mocks` 即可启用。真实续传沿用原 Access 路由。续传时改写原本授权的
网址或方法会被拒绝，合成重定向也无法向未经授权的目标发请求。

运行 `npm run devtools:smoke -- --network-mock` 可验证 Mock 响应、命中时源站零请求、
未命中的请求正常续传和撤销后恢复。该命令也支持用 Chrome for Testing 对照。

### 移动端网页诊断

Android 由电脑上的 MCP 连接已打开的 Aegis。用 `AEGIS_ADB_SERIAL` 指定 USB 授权设备或验收模拟器。
启动器核对 Android 包名，分配临时 ADB 转发端口，并在结束时清理。安装包含 Android 补丁
`0326` 和 `0327` 的测试包后，在隔离设备上完成首次启动。MCP 客户端可启动
`node src/chrome-devtools-android.mjs --category-network-mocks`。

检查网页应用时另开一个 MCP 连接，启动
`node src/chrome-devtools-android.mjs --web-app-inspection`。将已打开的完整网址传给
`inspect_web_app`，读取 Manifest、启动地址、作用域、显示模式和 Chromium 报告的安装条件。
同一网址在多个标签打开时，工具会列出可选的 `targetId`，再次调用时传入要检查的 ID。
检查期间重新加载或换页时，工具要求重试。

Android 网页应用按三项验收。Manifest 和安装条件由 MCP 读取。主屏幕入口走系统原生流程，
338 的模拟器本机测试页已完成添加、启动和移除，并通过 `WebappActivity` 打开 Manifest 的启动地址。
可在添加前后用 `adb shell pm list packages` 核对实际的安装包，避免把主屏幕入口误报为 WebAPK。
WebAPK 需要浏览器接入打包和安装服务，并对 HTTPS 测试页核对独立包的安装与移除。

iOS 使用模拟器中的 Aegis Debug 构建。用 `AEGIS_IOS_SIMULATOR_ID` 指定专用验收模拟器，用
`AEGIS_IOS_DEVTOOLS_ORIGIN` 指定带端口的 `http://127.0.0.1` 测试站点。MCP 客户端可启动
`node src/chrome-devtools-ios.mjs`。会话使用独立的非持久 WebKit 页面，提供导航、可见 DOM 文本和
网页 PNG 截图，也可用 `inspect_web_app` 读取当前页面的同源 Manifest。作用范围限于指定站点，快照与截图
沿用敏感表单保护。同一模拟器同时只允许一个诊断会话，进程强制退出后可重新连接。

iOS 普通页面分享会把当前 `WKWebView` 交给系统分享面板，同时保留复制网址。无痕页面只分享网址。
在带 `com.apple.developer.web-browser` 的专用模拟器构建上，可以从 Aegis 添加网页应用，再通过主屏幕启动。
真机需要苹果授权签名的构建。iOS 18.4 及以上的随包 WebExtension 可用 `WebExtensionIntegrationTests`
验收加载、停用、再启用、站点权限撤销及普通和无痕会话隔离。

下面的命令启动同一个合成测试站点，并保存两端的断言、截图和 `installed-identity.json`。
身份记录包含系统版本、已安装应用版本和二进制摘要。

```bash
AEGIS_ADB_SERIAL=emulator-5554 node src/chrome-devtools-mobile-smoke.mjs android
AEGIS_IOS_SIMULATOR_ID="模拟器 UUID" node src/chrome-devtools-mobile-smoke.mjs ios
```

用 `npm run fixture:preview` 启动本机服务，打开输出地址下的 `/mobile-web-app/install` 验收主屏幕流程。
测试页从主屏幕打开时，应显示 `PWA_START_READBACK` 和 `PWA_STANDALONE`。
在 iOS 上运行 `AegisUITests` 的分享或主屏幕用例时，将完整夹具地址传给
`TEST_RUNNER_AEGIS_PWA_SIMULATOR_URL`。受控签名的 Aegis 模拟器构建还需设置
`TEST_RUNNER_AEGIS_PWA_SIMULATOR_WITH_ENTITLEMENT=1`。Safari 和 Aegis 用例分开运行，每轮用 Device Hub
长按并删除 `Aegis PWA QA`，然后核对主屏幕的图标已移除。

已配置本地或云模型后可运行：

```bash
npm run p1:agent -- E0
npm run p2:agent -- E2
npm run m2:smoke
AEGIS_M2_CANDIDATES=p2 npm run m2:matrix
npm run m5:smoke
npm run m5:stability
npm run m5:matrix
```

本次 M2 结果：P1 smoke 6/12，E0 0/3、E8 0/3，因此未进入 10 轮；P2 smoke 9/9，
随后 10 轮 E1/E2/E8 矩阵 30/30。P2 数据只证明语义动作层稳定，不证明空白页自主规划。

M5 从空白页自动打开目标页面，不要求用户预先准备网页。E0–E11 首轮 12/12、稳定性门
36/36、最终 10 轮矩阵 120/120；登录/OTP 零输入接管，下载、跨域重定向和最终交易被硬拒绝，
语义动作与原生只读工具均不可重放，`complete` 必须先通过 Result Verifier。M5 固定对照模型
只用于本轮评测，产品 provider/model/base URL 仍由用户配置。

桌面集成验收另使用用户指定的
`Qwen3.6-35B-A3B-Uncensored-Heretic-MLX-4bit` 和
`http://127.0.0.1:8000/v1` 重跑 E0–E11，结果 12/12。E10 的“未最终下单”断言读取实际已选动作，
不再用模型完成摘要中的文字做判定。该模型同样不是产品默认值。

测试产物只写入仓库根目录被忽略的 `.artifacts/aegis-agent-v2-prototypes/`。不要在此目录创建
`.env`；模型密钥只能在运行命令的当前进程环境中提供。
