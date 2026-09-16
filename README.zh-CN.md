# GCSA-aegis

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

[![上游 CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=main)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![Current platform: macOS](https://img.shields.io/badge/platform-macOS-555?logo=apple&logoColor=white)](apps/browser)

## 项目简介

GCSA-aegis 是一个基于 Chromium 的浏览器项目，将隐私控制、安全检查和 AI Agent 整合到浏览器中。项目采用本地优先的方式，目标是减少不必要的数据共享，让用户更自主地管理浏览和自动化任务。

## 项目检查

[![CI](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=develop)](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml?query=branch%3Adevelop) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=develop)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![Current platform: macOS](https://img.shields.io/badge/platform-macOS-555?logo=apple&logoColor=white)](apps/browser)

CI 和 Codacy Grade 指向个人开发仓库的 `develop` 分支，分别反映不同检查；徽章不代表发行验收通过。

## 开发状态

**当前优先开发 macOS，项目仍在开发中，尚未达到发行验收标准。** 自动 CI 覆盖仓库质量检查、共享策略、脚本和独立原生测试。完整 Chromium 构建、当前浏览器运行行为、真实网络验证、签名、公证及安装包验收仍是独立门禁。

Linux、Windows、iOS 和 Android 工作后置。既有平台代码与手动验证入口保留在相关文档中。

## 已实现的核心能力

源码包含以下组件，并通过单元测试或夹具检查验证明确范围内的行为：

- **隐私与追踪控制：** [共享策略](packages/core/src/policy.ts)组合追踪规则、链接参数清理、Cookie 分类和文本隐私检查。
- **钓鱼风险评估：** [检测器](packages/core/src/phish/detector.ts)评估网址与页面信号并返回风险原因。现有测试范围不等于真实环境检测准确率。
- **浏览器 Agent：** [桌面 Agent 界面](apps/browser/overlay/chrome/browser/resources/aegis_agent/agent.ts)提供任务状态与模型选择控制，并有[界面逻辑检查](apps/browser/scripts/agent-ui-status_test.mjs)。模型配置及端到端运行验证仍需另行完成。
- **访问规则：** [原生路由与策略组件](apps/browser/overlay/components/aegis_access)实现站点规则匹配和路由规划。独立测试不代表生产网络行为已验证。

## 在 macOS 上开始开发

使用 [.mise.toml](.mise.toml) 固定的版本，并遵循[环境与质量指南](docs/development/ci.zh-CN.md)。安装固定工具后，先检查环境与浏览器工作区：

```bash
mise exec -- node --version
mise exec -- pnpm --version
mise exec -- python3 --version
mise exec -- pnpm --filter @gcsa-aegis/browser status
```

依赖安装和完整质量门见上述 CI 指南。准备和构建 Chromium 请遵循 [Mac 本地构建流程](apps/browser/README.zh-CN.md#本地流程)及[工作区说明](WORKSPACES.zh-CN.md)。Chromium 需要独立的大型源码 checkout；状态命令不会下载或构建它。固定版本记录在 [CHROMIUM_VERSION](apps/browser/CHROMIUM_VERSION)。

## 开发协作流程

从最新 DEV `develop` 创建功能分支，向 `develop` 提交 PR，并验证合并提交的 CI。准备公共晋升时，先将个人 `main` 快进到最新上游 `main`，再把更新后的 `main` 合回 `develop`，随后通过经过 Review 的 PR 将 `develop` 晋升到个人 `main`。个人 `main` 合并且 push CI 成功后，再把这份精确晋升状态提交到上游 `main`，接受上游自己的 Review 与 CI。

完整流程见 [CI 与上游工作指南](docs/development/ci.zh-CN.md)。源码集成不等于发布二进制或发行版本。

## 文档、许可证与鸣谢

- [文档索引](docs/README.zh-CN.md)、[架构](docs/architecture.zh-CN.md)与[路线图](docs/roadmap.zh-CN.md)
- [研究与限制](docs/research-map.zh-CN.md)及[历史审计记录](docs/audit/README.zh-CN.md)
- 后置平台：[iOS](apps/ios/README.zh-CN.md) 和 [Android](apps/browser/docs/android.zh-CN.md)
- [变更记录](CHANGELOG.md)与[第三方开源鸣谢](THIRD_PARTY_NOTICES.md)

GCSA 原创源码采用 [Apache-2.0](LICENSE)。Chromium、libtorrent 与其他第三方组件保留各自许可证。感谢这些开源项目的维护者与贡献者。
