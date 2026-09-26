# 变更日志

[English](CHANGELOG.md) | **简体中文** | [繁體中文](CHANGELOG.zh-TW.md)

本文件记录项目的重要变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，项目计划采用[语义化版本](https://semver.org/lang/zh-CN/)。

软件包版本仍为 `0.1.0`，但尚未发布 `0.1.0` Release、Git tag 或二进制分发物。以下内容全部仍属**未发布**。

## [未发布]

### 2026-09-14 源码更新：界面整改与浏览器更新

- 0109–0113 补齐 GitHub 正式版本检查、安装包下载及大小和 SHA-256 校验、产品更新共享状态、准确的模型配置状态，以及设置和内置页面三语整改。下载校验不代替发行签名、公证或安装验收。
- 2026-09-13 的历史本地 macOS 验收为 Ver 1.1 (018)：32 项整改完成，18 项原生测试、116 项界面回归通过，170 条改动文案及翻译占位符检查通过。Ver 1.1 (018) 是本地测试 App 标识，不是已发布版本或仓库包版本。结果仅适用于该测试 App 及记录中的验收范围，不覆盖后续源码。Windows/Android 实机及真实 Release 安装尚未验收；该次源码更新未发布二进制或 tag。
- 2026-09-14 源码提交记录确认：在历史 108 补丁树 `319366182c31108e29e62d2f2199aff29a0b86e8` 上重放 0109–0113 后，得到源码树 `6032269758860056c1371ed5d6f9ed6902c23596`。这是当次重放结果，不代表当前源码或发行资格验收。
- [018 验收记录](docs/ui-copy-acceptance.zh-CN.md) · [更新流程](docs/github-browser-updates.zh-CN.md)

### 发行状态

- 2026-09-10 将开发历史合入 `main`。0107–0108 补齐冷启动监控恢复及已核验的执行、摘要修复。见[验证记录](docs/audit/main-consolidation-2026-09-10.md)；本次没有编译 App 或发布二进制。

- 2026-09-10 历史基线：Browser Agent v2 包含 108 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁，精确重放到源码树 `319366182c31108e29e62d2f2199aff29a0b86e8`。后续重放结果见上方 2026-09-14 更新；这两个树标识均不能单独代表当前源码。
- 补丁 0106 修复 Windows 界面线程读取语言资源导致的崩溃，保留远程控制安全提示；新产物的跨平台回归验收尚待完成。
- 57、65、67、95 和 97 补丁记录只保留为历史证据，不能给当前 v2 产物授予资格。
- 项目整体仍为发行 No-Go。源码同步不授权 tag、GitHub Release、二进制、签名、公证、Play 上传或生产部署。

### 新增

- 开发版新增 ASCII 走私防护：反钓鱼检测及模型请求前清理隐藏 Unicode，拒绝带隐藏载体的操作参数，保留合法 emoji。macOS 原生、界面及本地 Qwen 验证通过；Windows/Android 新包尚待验收。
- Browser Agent v2 原生混合 Runtime：模型优先理解/规划，浏览器掌控执行/观察/验证，确定性点名站点目标，以及一次有界模型格式修复后的安全 R0 只读恢复。
- 桌面和 Android 新手入口、当前页面绑定、页面摘要/商品对比/收藏夹/URL 检查/官方下载/研究等常用任务，以及独立的定时自动化工作区。
- Chromium 原生隐私安全控制、站点保护界面、钓鱼解释和有界会话活动记录。
- 本地威胁情报索引、有界钓鱼页面信号和凭据意图检查。
- HTTP(S) 并行下载控制、Metalink 支持，以及带有界默认值的 BT/Magnet 集成。
- Canvas、OffscreenCanvas、Audio、WebGL 和部分 WebGPU 表面的反指纹措施。
- 仅观察 MinerGuard 信号，以及研究性质的 AST、来源流、联邦模拟和 V8 bytecode shadow 原型。
- 用户配置的 OpenAI、Claude（Anthropic）和 Gemini 兼容模型 API，以及绑定精确文档会话的页内摘要入口。
- 浏览器掌控的 Agent：包含有范围约束的书签/URL/页面/下载/监控工具、审批回执、取消、审计历史，以及最终购买前的用户接管。
- 英文、简体中文和繁体中文公开文档。

### 变更

- 通过 Chromium 枚举接口读取不可合并的 `Retry-After` 响应头，避免启用断言的 Windows 浏览器在有界同源收藏夹 URL 检查期间崩溃。
- 产品收敛为 Chromium fork；历史 Extension 和 Electron 方向不再属于交付物。
- 公开状态文案明确分开源码集成、自动化测试、build-tree 产物、运行证据和发行资格。
- 可选远程摘要服务采用兼容格式，不把行为绑定到具体产品名称。

### 修复

- Chromium 后台抓取日志与 vpython wheel/proxy 缓存现在跟随 `CHROMIUM_ROOT` 或 `.chromium-root` 选中的 checkout，不再静默写入已停用的旧 checkout 路径。
- 修复正常启动看不到 Browser Agent 工具栏/侧栏入口的问题，并为已有 Profile 增加一次性固定迁移。
- 修复 Agent WebUI 未发送侧栏就绪通知、导致工具栏和设置入口点击后一直等待且界面不出现的问题；新增不绕过生产等待路径的回归测试。
- 普通 Profile 可在第一次任务中启用用户选择的 provider/model；实验性 WebMCP 与交易能力继续默认关闭。
- 把技术性规划失败改为一次有界 schema 修复、白名单只读恢复和新手可读的重试提示。
- 把模型提出的标签页/文档能力绑定到浏览器实时批准的任务上下文：单标签页只读任务不会再因模型 ID 轻微漂移而失败，存在歧义或风险较高的动作仍保持 fail closed。
- 将 Agent 任务持久化迁移到允许阻塞的专用序列，消除 UI 序列上的 SQLite 崩溃，同时保留脱敏任务记录和有界关闭行为。
- 收藏夹 URL 检查遇到同源 HTTP 429 后会把服务端重试窗口记录到该源剩余 URL 并确定性结束，不再串行等待。

- 加固 Profile 退出、跨序列报告投递、补丁重放、构建身份、打包保护和本地签名检查。
- 为独立的主无痕 Profile 补齐 Aegis 核心、Agent、Actor、设置/菜单/工具栏/侧栏和下载界面；Guest、System 与辅助 OTR Profile 继续 fail closed。
- 把本地 ad-hoc 签名移到构建身份 finalize 之前，启动已验证 App 时不再修改已绑定字节。
- Android 打包现在拒绝符号链接和路径逃逸，并以不覆盖既有产物的原子方式发布输出。
- 降低部分过滤列表与 Canvas 热路径开销，并修复若干浏览器生命周期和 WebUI 问题。

### 安全

- 对所选本地 CDP 路径应用精确文档授权和远程来源传播。
- 增加 fail-closed 摘要脱敏、敏感页面回退、远程目标显式确认，以及不回显、由系统加密的 API 凭据。
- Release 验证现在检查密封 schema、当前源码与依赖状态、构建图和完整产物树；只显式排除本地 `.DS_Store` 元数据。
- MinerGuard 和 V8 bytecode shadow 保持仅观察；两者都不能授权脚本阻断或“通用恶意 JavaScript 防护”声明。
- 在模型层以下强制执行 Browser Agent scope、文档绑定、Profile 隔离、秘密脱敏、SSRF 控制、精确审批、浏览器侧结果验证和 fail-closed 恢复。
- 增加桌面与 Android 进程级远程 CDP latch：创建主无痕 Profile 会在延迟启动或目标所有权检查之前停止并阻断桌面 HTTP/pipe 与 Android HTTP/socket 传输。桌面只能由普通 Profile 显式重新启用，Android 在进程重启前保持锁止。
- 默认 NetLog 采集会脱敏模型 API key 请求头，Actor 私密 journal、诊断与 trace 也会抑制私密数据。显式使用 Chromium 敏感模式的 NetLog 仍沿用其敏感数据语义，必须按可能包含秘密处理。
- 使用不透明且精确按 Profile 隔离的网络/CNAME 分区，以及仅存在于内存的无痕 Advanced/Torrent 所有权。关闭无痕会取消活跃 Agent 下载与种子传输并撤销控制，同时保留已写入的种子字节，以及已完成下载和获批收藏夹写入的 Chromium 原生持久语义。

### 已知限制

- 正式发行资格仍未完成：缺少受信任构建证明、正式产品 Developer ID 签名、hardened runtime 公证、stapling，以及正式发行安装包的端到端安装与升级验收。上方本地 018 测试 App 的安装及 macOS 检查不构成正式发行资格。
- Android 与 Windows 当前源码构建/设备资格正在验证；完成精确身份和运行记录前不接受任何包。
- Chromium 出站、遥测、更新、崩溃报告和代表性功能行为审计仍未完成。
- Phase 2 研究使用 synthetic formal fixture。Phase 3 是独立的 13 样本 operator-blinded public pilot，召回率为 `1/3`；两者都不能泛化为生产准确率、误报率或安全证明。
