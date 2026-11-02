# iOS App Store 审核准备

本轮范围是审核资料和工程身份准备，**只提 PR，不合并、不提交审核**；合并后的站点同步由同事执行。本地代码、模拟器、线上页面、Developer Portal、签名、TestFlight 与商店审核分别验收。

## 官网与审核字段

| 字段 | 拟填写值 |
| --- | --- |
| 应用名称 | GCSA Aegis |
| Marketing URL | https://browser.erjinyi.com/ |
| Support URL | https://browser.erjinyi.com/support/ |
| Privacy Policy URL | https://browser.erjinyi.com/privacy/ |
| 支持与隐私联系 | contact@gcsa.com |

应用内「设置 → 关于」提供官网、技术支持与隐私政策链接，入口支持简体中文、繁体中文和英文。网站支持/隐私文档为英文与简体中文静态页面，官网页脚提供入口。

2026-11-02 在线检查显示 HTTPS 证书已于 2026-11-01 13:48:15（北京时间）过期，正常证书校验失败。本轮页面尚未部署；只有有效证书下公开 URL 实际返回正确内容后，才能标记网页条件完成。不要使用忽略证书错误的诊断结果作为审核可用证明。

## 工程身份

| Target | Bundle ID |
| --- | --- |
| Aegis | `com.gcsa.aegis` |
| SafariWebExtension | `com.gcsa.aegis.safari` |
| ShareExtension | `com.gcsa.aegis.share` |
| BrowserKit | `com.gcsa.aegis.browserkit` |
| AegisPolicyKit | `com.gcsa.aegis.policykit` |
| AgentKit | `com.gcsa.aegis.agentkit` |
| AegisTests | `com.gcsa.aegis.tests` |
| AegisUITests | `com.gcsa.aegis.uitests` |

`apps/ios/project.yml` 与已提交 Xcode 工程的 Debug/Release 配置同步；Safari 文档身份测试及 handler 的后备标识同步。各目标需要唯一 ID，不能全部填写主应用 ID。

已有 App Group `group.com.gcsa.aegis.ios.share-inbox` 保持不变：主应用与分享扩展 entitlement、URL 和 Markdown 消费端继续使用同一值；它是共享容器标识，不是 Bundle ID。Keychain service 名称亦保持稳定。生产签名前需在 Developer Portal 核实该组已注册、关联两个应用标识，并使用对应 profile；本轮没有修改门户或 profile。

新主应用身份与旧开发版 `com.gcsa.aegis.ios.app` 是不同的应用沙盒，不提供自动迁移旧版历史、收藏或密钥的承诺。

## 隐私申报准备

隐私政策基于当前原生实现描述以下边界：

- 普通历史、收藏、工作区、下载、阅读资料与模型配置保存在设备；API 密钥位于 Keychain。
- 用户配置模型服务时，连接检测与模型列表查询访问所选端点；确认请求后，正文、提示词、网址等直接发送给该提供方，提供方可能关联账号并在其他地区处理或保留数据。
- 私密模式不是自动保存、导出、下载或发送后的删除保证；恢复副本、Keychain、共享容器、外部导出和系统备份需分别考虑。
- 搜索、规则更新、链接检查、下载和用户脚本可能访问相应第三方，不作“完全离线”承诺。
- 官网首页的 Clarity 与原生应用区分；支持/隐私文档无统计脚本。邮件、网站日志与第三方留存设置需按运营实际核实。

现有主应用 `PrivacyInfo.xcprivacy` 将 `OtherUserContent` 和 `BrowsingHistory` 声明为应用功能用途、可能关联用户、不用于 tracking。**本轮未更改该申报，也未填写 App Store Connect 隐私表。** 最终申报应以实际发行包、启用的第三方服务和 Apple 的收集定义为准，不能从“本地优先”推导为“不收集数据”。

## 后续提审条件

1. 部署页面、续期证书，在外网及 iPhone/iPad 验证三个 URL；确认联系邮箱可接收并处理请求。
2. 核实 App Store Connect 的实际应用记录及 Bundle ID；注册/核对扩展和 App Group 关联，准备生产签名。不要仅凭本地构建认定门户配置正确。
3. 确定正式营销版本与构建号。当前工程为 `7.0 (127)`；本轮没有更改版本，也未核实它与商店待提交版本的对应关系。
4. 核对 Privacy Manifest、隐私标签、权限用途、年龄分级、出口合规、分发地区及审核联系资料；截图来自最终提审版本的真实界面。
5. 对最终候选完成真机功能/权限与扩展、默认浏览器资格、安装升级、正式 Archive、签名及 TestFlight 验证。模拟器结果不替代这些证据。
6. 获得明确提交指令后再提交 App Review；保持独立审核与发布操作。

参考：[Apple 审核指南](https://developer.apple.com/app-store/review/guidelines/)、[版本信息字段](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)。

## 本轮本地验证

- Xcode 27.0 / iOS Simulator 26.5：最终工程 `build-for-testing` 通过；产物中主应用、Safari/Share 扩展标识分别为 `com.gcsa.aegis`、`.safari`、`.share`。
- iPhone 17：19 项 Safari 身份/授权和 Share Inbox 回归、1 项最大辅助字号的审核链接 UI 测试通过。
- iPad Air 11-inch (M4)：相同最大辅助字号入口 UI 测试 1 项通过。两台使用本轮独立模拟器，截图为本地验证资料，不是 App Store 截图。
- Safari JavaScript 文档身份 harness 通过。
- 未执行正式签名、Archive、真机、TestFlight、托管 CI 或 App Store 提交。独立内置审查结果在本地证据包中另行记录，不能从本段测试状态推导。
