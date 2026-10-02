# iOS 2.2.0 源码预发布

日期：2026-10-03。标签：`ios-v2.2.0-preview.1`。

## 发布内容

本版本发布原生 iPhone/iPad 浏览器源码及验证摘要。仓库共享包版本保持 0.1.0，iOS 产品版本为 2.2；此标签不授予 macOS、Windows 或 Android 新的发行资格。

- 网页助手：读取用户选择的页面，预览脱敏内容并确认模型目的地，生成带来源的回答，保存加密任务与结果。
- 下载与资料：后台下载、暂停与续传、镜像重试、Metalink、哈希校验，收藏检查及工作区导入导出。
- 浏览保护：内置及手动更新 EasyList/EasyPrivacy，元素隐藏、站点例外和私密会话隔离。
- 标签与窗口：分组、重命名、恢复及独立 iPad 窗口；iPad 网页使用完整窗口，已移除常驻侧栏。

## 获取与使用

GitHub Release 提供该标签的源码归档。按 [iOS 工程指南](../../apps/ios/README.zh-CN.md) 使用 Xcode 构建、在 Simulator 运行。最低 iOS 18.4。

本版本没有签名 IPA，不可直接安装至真机或提交 App Store。签名、真机、VoiceOver 全流程、TestFlight 和商店提审另行完成。助手不具备任意网页操作、跨设备同步、自动全网检索或 BT/磁力下载。

## 验证记录

历史基线：030 全量 iPhone 148 项通过、2 项跳过；iPad 148 项通过、2 项旧侧栏定位失败。修正后的 031 复测为 iPhone 132 项通过、2 项跳过，iPad 134 项全部通过，两台运行时警告均为 0。032 arm64 未签名 Release 编译通过。

本次在远端 main `dcfd5ac` 上整合 iOS 改动，保留上游 Swift 覆盖率导出与源码稳定性检查，重新完成发布候选验证：

- **Ver 2.2 (033) 完整模拟器回归**：iPhone 148 项通过、2 项 iPad 专用测试跳过；iPad 150 项全部通过。两台失败及运行时警告均为 0。
- Swift 行覆盖率：iPhone 85.50%，iPad 87.38%；两台均测量 45 个产品 Swift 文件。测试前后 iOS 输入哈希一致。
- **Ver 2.2 (034) Release**：arm64 无签名编译通过，包内 6 份隐私清单、图标及多窗口声明通过。相较 033 仅递增构建号并生成工程；未把未签名 App 作为可安装包分发。
- `quality:fast` 全部通过，含核心 193 项测试、浏览器脚本与界面检查、访问计量 21 项测试；iOS JavaScript 定向 ESLint 和仓库合同检查通过。
- 三语资源 386 个词条、353 个提取键，缺失和翻译占位符错误均为 0。
- 两台系统“文件”导出的下载均读回 44,032 字节及正确 SHA-256，工作区 JSON 保留名称和网址；iPad 两个窗口的不同 ID 和各自页面读回一致。

公开证据：[验证摘要](ios-2.2.0-preview.1/validation-summary.json)、[033 测试输入哈希](ios-2.2.0-preview.1/simulator-source-sha256.txt)、[034 发布源码哈希](ios-2.2.0-preview.1/release-source-sha256.txt)。完整日志与 xcresult 保留在本地证据目录。

界面实测：[iPad 无侧栏页面](ios-2.2.0-preview.1/ipad-full-width.png)、[窗口管理](ios-2.2.0-preview.1/ipad-windows.png)、[关闭后恢复](ios-2.2.0-preview.1/ipad-window-restored.png)、[iPhone 标签分组](ios-2.2.0-preview.1/iphone-groups.png)。截图使用合成测试资料。

历史实现详情：[网页助手与下载](../audit/ios-feature-parity-2026-10-01.zh-CN.md)、[分组与窗口](../audit/ios-windows-and-tab-groups-2026-10-01.zh-CN.md)。
