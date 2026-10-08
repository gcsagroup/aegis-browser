# 变更日志

[English](CHANGELOG.md) | **简体中文** | [繁體中文](CHANGELOG.zh-TW.md)

本文件记录项目的重要变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，项目计划采用[语义化版本](https://semver.org/lang/zh-CN/)。

软件包版本仍为 `0.1.0`；iOS 产品线独立使用 `2.2`。以下新增 iOS 源码预发布记录，未完成签名和商店发行验收。

## [ios-v2.2.0-preview.1](https://github.com/gcsagroup/aegis-browser/releases/tag/ios-v2.2.0-preview.1) — 2026-10-03

### 新增

- 原生 iPhone/iPad 网页助手：有界页面读取、脱敏预览、模型目的地确认、来源引用、加密任务恢复与结果保存；支持 OpenAI 兼容、Anthropic 和 Gemini 接口。
- HTTP(S) 后台下载、暂停与续传、镜像重试、Metalink、SHA-256/SHA-512 校验和系统文件导出。
- EasyList/EasyPrivacy 内置规则、手动更新、元素隐藏与站点例外；收藏链接检查和工作区导入导出。
- 标签分组与重启恢复、iPad 独立窗口和窗口恢复；移除 iPad 常驻侧栏，网页使用完整窗口。

### 修复与验证

- 验收脚本改用固定文件路径、本机 HTTP 自测和优化模式下仍执行的显式检查；重新生成的规则字节不变。

- 修复窗口初始化期间发布共享状态的 SwiftUI 警告；私密页面和分组不写入窗口记录。
- 合并远端 Swift 覆盖率导出，保留输入前后哈希检查；版本递增及工程生成后冻结输入，独立工作树可复用固定构建目录。
- 三语界面、隐私清单与模拟器验证记录见[发布说明](docs/releases/ios-2.2.0-preview.1.zh-CN.md)。GitHub 提供源码预发布，无可安装的签名 IPA；真机、VoiceOver 全流程、TestFlight 和 App Store 验收仍待完成。

## [未发布]

### 2026-10-09 源码整合：Quinn 功能与 Chromium 155 主线

- 在同一源码整合中保留桌面鼠标手势，纳入 Quinn develop 的双节点租约、双 relay、本地 SM-00 预检与工作流文档，并纳入其 PR #203 的 Agent 接管、监控订阅、研究来源绑定及 iOS 下载持久化/恢复修复。
- 适配新增研究测试到 Chromium 155；固定租约 SQL 查询并增加非法表名拒绝回归。Mac 候选提升为 Ver 2.2 (144)，276 个补丁和 506 项 overlay 完整重放通过；iOS 下载定向测试在 iPhone/iPad 模拟器各通过 43 项。
- 合入路径统一为 [#32](https://github.com/gcsagroup/aegis-browser/pull/32)；[#33](https://github.com/gcsagroup/aegis-browser/pull/33) 已并入该整合分支。下方 141 记录保留为历史证据；最新范围和验证见[整合记录](docs/audit/main-quinn-integration-2026-10-09.zh-CN.md)。本次不创建正式发行，原型与模拟器结果不代表生产接入或实机验收。

### 2026-10-09 源码更新：桌面鼠标手势与 Chromium 155 适配

- 新增原生右键手势、方向绑定、轨迹提示、识别距离、网站排除及不执行真实动作的练习区；普通网页、设置页和内置 PDF 使用一致的通用动作，PDF 另可绑定翻页、适合宽度和整页。
- 保留右键轻点菜单及左键点击、拖选；Esc、导航、失焦和离开内容区会取消手势。修复跨框架测试的输入时序，以及 Chromium 155 设置项改名后的旧测试取值。
- Mac ARM64 验收版 Ver 2.2 (141)：33 项测试及跨框架额外 5 次复测通过；273 个桌面补丁完整重放，506 项 overlay 核对通过，并完成实际 App 设置保存回读。具体版本和证据范围见[验收记录](docs/audit/mouse-gestures-acceptance-2026-10-09.zh-CN.md)。
- 上游同步改为分别跟踪源码 PR、主线兼容验收和正式发行；鼠标手势纳入持续功能回归。代码位于依赖 [#32](https://github.com/gcsagroup/aegis-browser/pull/32) 的 [#33](https://github.com/gcsagroup/aegis-browser/pull/33) 草稿 PR，记录时 main 尚未升级。Windows/Android 兼容验收、上游 PR 扫描问题及正式签名、公证仍待完成。
- [鼠标手势使用指南](apps/browser/docs/mouse-gestures.zh-CN.md)。本次补充文档不重新编译 App，验收收据仍绑定原构建提交。

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
