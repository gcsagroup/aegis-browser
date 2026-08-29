# 变更日志

[English](CHANGELOG.md) | **简体中文** | [繁體中文](CHANGELOG.zh-TW.md)

本文件记录项目的重要变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，项目计划采用[语义化版本](https://semver.org/lang/zh-CN/)。

软件包版本仍为 `0.1.0`，但尚未发布 `0.1.0` Release、Git tag 或二进制分发物。以下内容全部仍属**未发布**。

## [未发布]

### 发行状态

- 当前整合源码已同步到 67 个顶层 Chromium 补丁，另含 2 个嵌套 V8 补丁。
- 此前的 57 补丁诊断清单和 65 补丁 Agent 验收仅为历史证据，均不绑定当前 67 补丁 HEAD，也不能给它授予资格。
- 项目整体仍为发行 No-Go。源码同步不授权 tag、GitHub Release、二进制、签名、公证、Play 上传或生产部署。

### 新增

- 浏览器级 Agent 任务启动：从空白页或内部页面输入目标时，明确 URL 会直接打开，普通目标会使用用户默认搜索引擎自动查找；纯收藏夹管家任务不再要求先打开网页。
- Chromium 原生隐私安全控制、站点保护界面、钓鱼解释和有界会话活动记录。
- 本地威胁情报索引、有界钓鱼页面信号和凭据意图检查。
- HTTP(S) 并行下载控制、Metalink 支持，以及带有界默认值的 BT/Magnet 集成。
- Canvas、OffscreenCanvas、Audio、WebGL 和部分 WebGPU 表面的反指纹措施。
- 仅观察 MinerGuard 信号，以及研究性质的 AST、来源流、联邦模拟和 V8 bytecode shadow 原型。
- 用户配置的 OpenAI、Claude（Anthropic）和 Gemini 兼容模型 API，以及绑定精确文档会话的页内摘要入口。
- 浏览器掌控的 Agent：包含 Observe/Ask/Act 模式、书签与 URL 维护、有界浏览/下载/工作流/监控工具、审批回执、取消、审计历史，以及最终购买前的用户接管。
- 英文、简体中文和繁体中文公开文档。

### 变更

- 产品收敛为 Chromium fork；历史 Extension 和 Electron 方向不再属于交付物。
- 公开状态文案明确分开源码集成、自动化测试、build-tree 产物、运行证据和发行资格。
- 可选远程摘要服务采用兼容格式，不把行为绑定到具体产品名称。

### 修复

- Chromium 后台抓取日志与 vpython wheel/proxy 缓存现在跟随 `CHROMIUM_ROOT` 或 `.chromium-root` 选中的 checkout，不再静默写入已停用的旧 checkout 路径。
- 修复正常启动看不到 Browser Agent 工具栏/侧栏入口的问题，并为已有 Profile 增加一次性固定迁移。
- 修复 Agent WebUI 未发送侧栏就绪通知、导致工具栏和设置入口点击后一直等待且界面不出现的问题；新增不绕过生产等待路径的回归测试。
- Profile 执行仍需显式开启，实验性 WebMCP 与交易能力继续默认关闭。

- 加固 Profile 退出、跨序列报告投递、补丁重放、构建身份、打包保护和本地签名检查。
- 将摘要、WebUI 和工具栏访问严格绑定到所属普通 Profile；其他 Profile 与无痕 Profile 现在会 fail closed。
- 把本地 ad-hoc 签名移到构建身份 finalize 之前，启动已验证 App 时不再修改已绑定字节。
- Android 打包现在拒绝符号链接和路径逃逸，并以不覆盖既有产物的原子方式发布输出。
- 降低部分过滤列表与 Canvas 热路径开销，并修复若干浏览器生命周期和 WebUI 问题。

### 安全

- 对所选本地 CDP 路径应用精确文档授权和远程来源传播。
- 增加 fail-closed 摘要脱敏、敏感页面回退、远程目标显式确认，以及不回显、由系统加密的 API 凭据。
- Release 验证现在检查密封 schema、当前源码与依赖状态、构建图和完整产物树；只显式排除本地 `.DS_Store` 元数据。
- MinerGuard 和 V8 bytecode shadow 保持仅观察；两者都不能授权脚本阻断或“通用恶意 JavaScript 防护”声明。
- 在模型层以下强制执行 Browser Agent scope、文档绑定、Profile 隔离、秘密脱敏、SSRF 控制、精确审批、浏览器侧结果验证和 fail-closed 恢复。

### 已知限制

- 没有受信任构建证明、正式产品 Developer ID 签名、hardened runtime 公证、stapling 或安装 App 验收。
- 没有当前源码 Android APK/AAB，也没有合格的 Linux Android 构建环境。
- Chromium 出站、遥测、更新、崩溃报告和代表性功能行为审计仍未完成。
- Phase 2 研究使用 synthetic formal fixture。Phase 3 是独立的 13 样本 operator-blinded public pilot，召回率为 `1/3`；两者都不能泛化为生产准确率、误报率或安全证明。
