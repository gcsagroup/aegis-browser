# 四端功能对照清单

[简体中文](platform-features.zh-CN.md) · [繁體中文](platform-features.zh-TW.md) · [English](platform-features.en.md) · [JSON](platform-features.json)

本清单记录当前工作区的实现范围，不代表正式发行资格。各功能的本轮验证范围分别记录，具体测试与未验收项见对应报告。源码存在、模拟器通过和真机验收分别记录。

源码接入：有源码或产品合同依据；部分：与对应能力存在明确差异；未移植：尚未接入本端；系统：由平台负责。详细的四端原因、源码及验证状态保存在 JSON 中。

| 功能 | macOS | Windows | Android | iOS |
| --- | --- | --- | --- | --- |
| 总开关与设置持久化 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 跟踪器拦截 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 钓鱼警告页 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 指纹防护 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 挖矿防护 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 字节码检查 | 源码接入 | 源码接入 | 源码接入 | 未移植 |
| 过滤列表更新 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 链接清理 | 源码接入 | 源码接入 | 源码接入 | 源码接入 |
| Cookie清理 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| CNAME识别 | 源码接入 | 源码接入 | 源码接入 | 未移植 |
| 跳转跟踪防护 | 源码接入 | 源码接入 | 源码接入 | 系统 |
| 策略执行 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 隐私AI | 源码接入 | 源码接入 | 源码接入 | 部分 |
| AI权限控制 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 浏览器Agent及隐私资料隔离 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| Agent页面操作 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| Agent浏览器工具 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| WebMCP实验开关保持关闭 | 源码接入 | 源码接入 | 源码接入 | 未移植 |
| Agent工作流 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 交易实验开关保持关闭 | 源码接入 | 源码接入 | 源码接入 | 未移植 |
| 网络访问规则和权限 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 旧资料、隐私模式和重启兼容 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 已有更新入口、摘要校验和失败恢复 | 源码接入 | 源码接入 | 源码接入 | 系统 |
| 桌面右键手势、配置持久化、练习区与PDF动作 | 源码接入 | 源码接入 | 未移植 | 未移植 |
| 搜索、主页与启动 | 源码接入 | 源码接入 | 源码接入 | 源码接入 |
| 网页显示与网站权限 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 网站存储管理 | 源码接入 | 源码接入 | 源码接入 | 源码接入 |
| 收藏与历史 | 源码接入 | 源码接入 | 源码接入 | 源码接入 |
| 标签、窗口与工作区 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| HTTP 下载与完整性校验 | 源码接入 | 源码接入 | 源码接入 | 源码接入 |
| Metalink 与镜像 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 下载网络与容量设置 | 部分 | 部分 | 部分 | 源码接入 |
| BT 与磁力下载 | 源码接入 | 源码接入 | 源码接入 | 未移植 |
| 阅读资料与批注库 | 部分 | 部分 | 部分 | 源码接入 |
| 阅读翻译与对照 | 部分 | 部分 | 部分 | 部分 |
| PDF 文字层批注 | 部分 | 部分 | 部分 | 部分 |
| 前台网页变化检查 | 源码接入 | 源码接入 | 源码接入 | 部分 |
| 第三方扩展安装 | 源码接入 | 源码接入 | 源码接入 | 未移植 |
| 跨设备同步 | 未移植 | 未移植 | 未移植 | 未移植 |
| 默认浏览器与语言 | 源码接入 | 源码接入 | 源码接入 | 系统 |
| WebKit 系统加固 | 未移植 | 未移植 | 未移植 | 部分 |
| 按站点网站增强 | 部分 | 源码接入 | 未移植 | 部分 |
| 用户脚本与 AI 草稿 | 部分 | 源码接入 | 未移植 | 部分 |
| 内置 Markdown 阅读 | 部分 | 源码接入 | 未移植 | 部分 |

## iOS 范围与依据

### 总开关与设置持久化

`kAegisEnabled` — 提供独立保护选项，未增加与 Chromium 同构的总开关。

源码：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 跟踪器拦截

`kAegisTrackerBlocking` — WebKit 内容规则支持广告与跟踪过滤，规则语法覆盖有差异。

源码：[apps/ios/BrowserKit/ContentFilterCompiler.swift](../apps/ios/BrowserKit/ContentFilterCompiler.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 钓鱼警告页

`kAegisPhishInterstitial` — 签名本地主机快照、PSL 网址判断、有限结构观察与原生阻止页；检查在加载后发生，非实时威胁查询。

源码：[apps/ios/BrowserKit/NavigationPolicy.swift](../apps/ios/BrowserKit/NavigationPolicy.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift) · [apps/ios/AegisPolicyKit/RegisteredDomain.swift](../apps/ios/AegisPolicyKit/RegisteredDomain.swift)

iOS 模拟器证据：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 指纹防护

`kAegisFingerprintGuard` — 独立已知指纹资源规则及默认关闭的页面 API 限制；Worker 等可绕过，未移植引擎级扰动。

源码：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift) · [apps/ios/BrowserKit/SecurityRules.swift](../apps/ios/BrowserKit/SecurityRules.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift)

iOS 模拟器证据：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 挖矿防护

`kAegisMinerGuard` — 独立已知挖矿主机资源拦截；Worker/WASM 组合仅提示，不宣称未知挖矿识别。

源码：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift) · [apps/ios/BrowserKit/SecurityRules.swift](../apps/ios/BrowserKit/SecurityRules.swift) · [apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift)

iOS 模拟器证据：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 字节码检查

`kAegisBytecodeShadow` — 系统 WebKit 不使用项目的 V8 字节码检查补丁。

源码：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

本项未完成本轮运行验收。

### 过滤列表更新

`kAegisFilterListUpdater` — 手动更新及可关闭的前台检查；不承诺后台定时。

源码：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 链接清理

`kAegisLinkSanitize` — 可配置的导航追踪参数清理；凭据网址始终阻止。

源码：[apps/ios/BrowserKit/NavigationPolicy.swift](../apps/ios/BrowserKit/NavigationPolicy.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Cookie清理

`kAegisCookieJanitor` — 支持按网站和全部清除；未移植自动 Cookie 清理策略。

源码：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### CNAME识别

`kAegisCnameUncloak` — 未移植 Chromium 网络层的 CNAME 识别。

源码：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

本项未完成本轮运行验收。

### 跳转跟踪防护

`kAegisBounceTracking` — 由 WebKit 自身追踪保护处理；没有独立 Aegis 跳转跟踪模块。

源码：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

本项未完成本轮运行验收。

### 策略执行

`kAegisPolicyWorker` — Swift 策略、能力令牌和来源检查；与 Chromium 执行架构不同。

源码：[apps/ios/AgentKit/AgentBroker.swift](../apps/ios/AgentKit/AgentBroker.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 隐私AI

`kAegisPrivacyAi` — 发送前脱敏与预览；未内置设备端推理模型。

源码：[apps/ios/AegisPolicyKit/PIIScanner.swift](../apps/ios/AegisPolicyKit/PIIScanner.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### AI权限控制

`kAegisAiControl` — 读取、发送和操作分别确认，限制窗口、模式和来源。

源码：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 浏览器Agent及隐私资料隔离

`kAegisAgent` — 网页阅读、比较、任务保存和有限浏览器操作；不覆盖桌面全部工具。

源码：[apps/ios/AegisApp/PageAssistantView.swift](../apps/ios/AegisApp/PageAssistantView.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Agent页面操作

`kAegisAgentPageActions` — 固定向下滚动及导航操作；不自动填表、登录或付款。

源码：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

本项未完成本轮运行验收。

### Agent浏览器工具

`kAegisAgentBrowserTools` — 标签分组、工作区、用户输入网址、重载及关闭，执行前确认。

源码：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### WebMCP实验开关保持关闭

`kAegisAgentWebMcp` — 未接入 WebMCP，也没有可启用的空开关。

源码：[apps/ios/AegisApp/BrowserOperationsView.swift](../apps/ios/AegisApp/BrowserOperationsView.swift)

本项未完成本轮运行验收。

### Agent工作流

`kAegisAgentWorkflows` — 保留既有工作流，新增前台网页变化检查；后台调度未移植。

源码：[apps/ios/BrowserKit/ForegroundPageWatch.swift](../apps/ios/BrowserKit/ForegroundPageWatch.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 交易实验开关保持关闭

`kAegisAgentTransactionPilot` — 没有交易执行接口，购买流程由用户完成。

源码：[apps/ios/AgentKit/BrowserOperations.swift](../apps/ios/AgentKit/BrowserOperations.swift)

本项未完成本轮运行验收。

### 网络访问规则和权限

`aegis-access` — 按来源的网站显示、脚本、相机和麦克风设置；未移植 Aegis Access 代理路由。

源码：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

本项未完成本轮运行验收。

### 旧资料、隐私模式和重启兼容

`profile-compatibility` — 普通标签恢复、私密隔离、加密资料及旧下载记录兼容；格式独立。

源码：[apps/ios/AegisApp/AegisApp.swift](../apps/ios/AegisApp/AegisApp.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 已有更新入口、摘要校验和失败恢复

`release-update` — 安装和更新依赖 iOS 分发资格；无桌面式自更新器。

源码：[apps/ios/AegisApp/Info.plist](../apps/ios/AegisApp/Info.plist)

本项未完成本轮运行验收。

### 桌面右键手势、配置持久化、练习区与PDF动作

`MouseGestures` — 使用触控与系统导航；未移植桌面右键手势。

源码：[apps/ios/BrowserKit/BrowserWebView.swift](../apps/ios/BrowserKit/BrowserWebView.swift)

本项未完成本轮运行验收。

### 搜索、主页与启动

`search-home-startup` — 搜索引擎选择、删除与恢复；空列表只打开网址，自定义 HTTPS 模板、主页及普通标签恢复。

源码：[apps/ios/BrowserKit/BrowserPreferences.swift](../apps/ios/BrowserKit/BrowserPreferences.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md) · [docs/audit/ios-search-engines-2026-10-11.zh-CN.md](../docs/audit/ios-search-engines-2026-10-11.zh-CN.md)

### 网页显示与网站权限

`site-display-permissions` — 全局及按来源的缩放、桌面模式、JavaScript、相机/麦克风询问或阻止；无静默授权。

源码：[apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 网站存储管理

`site-storage` — 按网站清除普通 Cookie、缓存和存储，先关闭所有窗口的普通标签。

源码：[apps/ios/AegisApp/BrowserPreferenceViews.swift](../apps/ios/AegisApp/BrowserPreferenceViews.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 收藏与历史

`bookmarks-history` — 收藏管理和历史搜索；私密浏览不记历史，显式保存需确认。

源码：[apps/ios/BrowserKit/BrowserDataStore.swift](../apps/ios/BrowserKit/BrowserDataStore.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 标签、窗口与工作区

`tabs-windows-workspaces` — 标签分组、普通窗口恢复、iPad 多窗口；私密标签不跨启动恢复。

源码：[apps/ios/BrowserKit/BrowserWindowStore.swift](../apps/ios/BrowserKit/BrowserWindowStore.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### HTTP 下载与完整性校验

`http-downloads` — 系统后台 HTTP 下载、暂停续传、哈希校验、导出及回收站。

源码：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### Metalink 与镜像

`metalink-mirrors` — 导入 Metalink、逐个切换镜像及 SHA 校验；不合并镜像分片。

源码：[apps/ios/BrowserKit/DownloadPlan.swift](../apps/ios/BrowserKit/DownloadPlan.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 下载网络与容量设置

`download-network-limits` — 新任务保存网络策略和容量上限，续传沿用原策略。

源码：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### BT 与磁力下载

`torrent-magnet` — 需要 iOS 专用传输后端和后台调度方案，本轮未移植。

源码：[apps/ios/BrowserKit/DownloadManager.swift](../apps/ios/BrowserKit/DownloadManager.swift)

本项未完成本轮运行验收。

### 阅读资料与批注库

`reading-library` — 显式采集正文，AES-GCM 本机保存，引文高亮、批注、检索、归档与导出。

源码：[apps/ios/BrowserKit/ReadingLibrary.swift](../apps/ios/BrowserKit/ReadingLibrary.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 阅读翻译与对照

`reading-translation` — 网页正文脱敏预览后翻译；iPad 并排、iPhone 上下对照，保存后才持久化。

源码：[apps/ios/AegisApp/ReadingLibraryView.swift](../apps/ios/AegisApp/ReadingLibraryView.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### PDF 文字层批注

`pdf-text-notes` — 导入本地 PDF 指定页文字，不执行 OCR，不把 PDF 发给模型。

源码：[apps/ios/BrowserKit/ReadingLibrary.swift](../apps/ios/BrowserKit/ReadingLibrary.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 前台网页变化检查

`foreground-page-watch` — 面板前台按间隔重载并比较正文，停止或离开前台即取消。

源码：[apps/ios/BrowserKit/ForegroundPageWatch.swift](../apps/ios/BrowserKit/ForegroundPageWatch.swift)

iOS 模拟器证据：[docs/audit/ios-portable-features-2026-10-11.zh-CN.md](../docs/audit/ios-portable-features-2026-10-11.zh-CN.md)

### 第三方扩展安装

`third-party-extensions` — 有项目自带的 WebExtension 集成，尚无任意第三方扩展安装入口。

源码：[apps/ios/BrowserKit/WebExtensionRuntime.swift](../apps/ios/BrowserKit/WebExtensionRuntime.swift)

本项未完成本轮运行验收。

### 跨设备同步

`cross-device-sync` — 本轮仅本机存储，没有账号同步服务。

源码：[apps/ios/AegisApp/AegisApp.swift](../apps/ios/AegisApp/AegisApp.swift)

本项未完成本轮运行验收。

### 默认浏览器与语言

`default-browser-language` — 跳转系统设置；默认浏览器资格、App 语言和硬件权限由 iOS 决定。

源码：[apps/ios/AegisApp/BrowserSettings.swift](../apps/ios/AegisApp/BrowserSettings.swift)

本项未完成本轮运行验收。

### WebKit 系统加固

`webkit-system-hardening` — iOS 26.4 以上可选公开安全限制；旧版保留默认保护。保留系统欺诈警告、HTTPS 策略与 Lockdown；模拟器不能证明 MTE 效果。

源码：[apps/ios/BrowserKit/PageProtection.swift](../apps/ios/BrowserKit/PageProtection.swift) · [apps/ios/BrowserKit/BrowserSession.swift](../apps/ios/BrowserKit/BrowserSession.swift)

iOS 模拟器证据：[docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md](../docs/audit/ios-webkit-protection-2026-10-12.zh-CN.md)

### 按站点网站增强

`kAegisWebsiteEnhancements` — SwiftUI 与 WKWebView 已接入；按报告记录 iPhone/iPad 模拟器证据，不代表真机、最低系统运行或分发验收。

源码：[apps/ios/BrowserKit/UserScriptController.swift](../apps/ios/BrowserKit/UserScriptController.swift)

iOS 模拟器证据：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

### 用户脚本与 AI 草稿

`kAegisUserScripts` — SwiftUI 与 WKWebView 已接入；按报告记录 iPhone/iPad 模拟器证据，不代表真机、最低系统运行或分发验收。

源码：[apps/ios/BrowserKit/WebsiteEnhancements.swift](../apps/ios/BrowserKit/WebsiteEnhancements.swift)

iOS 模拟器证据：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

### 内置 Markdown 阅读

`kAegisMarkdownReader` — SwiftUI 与 WKWebView 已接入；按报告记录 iPhone/iPad 模拟器证据，不代表真机、最低系统运行或分发验收。

源码：[apps/ios/AegisApp/MarkdownReaderView.swift](../apps/ios/AegisApp/MarkdownReaderView.swift)

iOS 模拟器证据：[docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md](../docs/audit/site-enhancement-markdown-2026-10-13.zh-CN.md)

维护方式：修改 JSON 后运行 `node scripts/check-platform-features.mjs --write` 生成三语页面，再运行 `node scripts/check-platform-features.mjs` 检查。现有发布合同新增功能时，缺少任意一端的说明会使仓库检查失败。
