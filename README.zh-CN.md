# Aegis

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/final/svg/gcsa-aegis-logo-reversed.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/brand/final/svg/gcsa-aegis-logo-color.svg">
    <img src="assets/brand/final/svg/gcsa-aegis-logo-color.svg" alt="Aegis 标志" width="112">
  </picture>
</p>

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![C++ 单元测试](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/7b3008e649154ca0a7d5906c514488cc?branch=main)](https://app.codacy.com/gh/gcsagroup/aegis-browser/dashboard?branch=main) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![当前平台：macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**一个本地优先的隐私与安全浏览器，内置可控的 AI Agent。macOS 优先，随后推进 iPhone 与 iPad。**

[开始参与](#开始参与) · [平台进度](#平台进度) · [路线图](docs/roadmap.zh-CN.md) · [Browser 指南](apps/browser/README.zh-CN.md) · [iOS 指南](apps/ios/README.zh-CN.md) · [文档](docs/README.zh-CN.md)

---

Aegis 正在持续开发。**发行 No-Go：**macOS 浏览器和原生 iOS/iPadOS App 均尚无完成发行验收的可分发版本。

## 核心能力

| 能力 | 用途 | 平台与当前阶段 |
| --- | --- | --- |
| 隐私浏览 | 在 macOS 上通过链接、Cookie、钓鱼及部分指纹保护减少追踪与高风险导航；原生 App 隔离普通与私密配置。 | macOS：源码已包含，运行验收待完成。iOS/iPadOS：已有记录的 Simulator 基线，当前源码待重新验证。 |
| 可控 Agent | 展示计划，由浏览器策略约束操作，并在敏感操作前请求确认。 | macOS：源码已包含，运行验收待完成。iOS/iPadOS：四条离线工作流已有记录的 Simulator 基线。 |
| 原生下载 | 使用 Chromium 浏览器下载界面及受限的下载路径。 | macOS：源码已包含，运行验收待完成。 |
| 访问策略 | 通过原生代理组件路由选定流量；必要路径不可用时按 fail-closed 处理。 | macOS：源码已包含，集成与真实网络验收待完成。 |

## 开始参与

### 准备开发环境

仓库通过 [`.mise.toml`](.mise.toml) 固定 Node.js `22.23.1`、pnpm `9.15.0` 和 Python `3.11.9`。请安装 Git、[mise](https://mise.jdx.dev/)、ripgrep（`rg`）和支持 C++20 的编译器（默认使用 `clang++`）。在 macOS 上，可运行 `xcode-select --install` 安装 Xcode Command Line Tools；使用 Homebrew 时可运行 `brew install ripgrep`。

```bash
git clone https://github.com/gcsagroup/aegis-browser.git
cd aegis-browser
mise install
mise exec -- pnpm install --frozen-lockfile
mise exec -- pnpm run quality:fast
```

这组命令运行共享 workspace 检查；不会获取或构建 Chromium，也不验证原生 iOS App。

### 从源码构建 macOS 浏览器

按照 [Browser 工程指南](apps/browser/README.zh-CN.md)准备 `depot_tools`、获取独立的大型 Chromium 固定版本源码、重放补丁序列，以及构建并运行浏览器。Chromium 还需要额外的主机依赖；该指南提供构建和验证命令。

### 打开 iOS 工程

[iOS 工程指南](apps/ios/README.zh-CN.md)说明 Xcode 与 Simulator 前提、仓库中的 `apps/ios/Aegis.xcodeproj`，以及 iPhone/iPad Simulator 流程。仅在需要重新生成工程时才使用 XcodeGen。

## 平台进度

| 平台 | 优先级 | 当前状态 |
| --- | --- | --- |
| macOS | 当前 | Chromium 集成和 Access Service 持续推进；当前源码的运行与分发验收仍待完成。 |
| iOS / iPadOS | 下一阶段 | 原生 SwiftUI/WKWebView App 已有记录的 Simulator 基线；当前源码、真机与分发验收仍待完成。 |
| Windows / Android / Linux | 后续 | 已有源码和评估入口；当前不承诺近期发行。 |

macOS 可以独立达到发行条件，不需要等待 iOS。各里程碑的完成标准见[路线图](docs/roadmap.zh-CN.md)。完整浏览器构建、真实网络场景、真机验收、签名、公证、安装与升级分别属于发行门槛。

## 隐私与 AI

网页摘要使用有界页面快照，并由浏览器再次校验和脱敏；敏感页面会退回设备端启发式处理。远程摘要请求可能将经过裁剪和脱敏的页面内容发送给用户选择的兼容模型端点；使用非 loopback 目的地前，需要明确选择并确认。Browser Agent 的操作受浏览器策略约束，敏感操作还需要单独确认。iOS Agent 工作流目前离线运行，没有生产远程模型链路。这些控制不构成通用的数据防泄漏边界，详见[架构与隐私边界](docs/architecture.zh-CN.md)。

## 架构

| 目录 | 职责 |
| --- | --- |
| [`packages/core`](packages/core) | 共享 TypeScript 策略逻辑、生成资源和 Agent 契约。 |
| [`apps/browser`](apps/browser) | Chromium 集成、原生浏览器服务、构建脚本和桌面打包。 |
| [`apps/ios`](apps/ios) | 原生 SwiftUI/WKWebView App、策略与 Agent 模块、内嵌扩展。 |

桌面浏览器基于 Chromium fork；iOS 是独立的原生实现。具体实现见[架构文档](docs/architecture.zh-CN.md)和各平台工程指南。

## 贡献与文档

### 参与贡献

公开贡献请 Fork [`gcsagroup/aegis-browser`](https://github.com/gcsagroup/aegis-browser)，提交范围聚焦的改动，运行相关检查，并向上游 `main` 分支提交 Pull Request。请说明改动范围、验证证据和已知限制。

在 GCSA Aegis 开发 Fork 中工作的维护者，请遵循单独的 [`develop` 工作流程](docs/development/ci.zh-CN.md)。

### 文档导航

- **项目：** [文档索引](docs/README.zh-CN.md) · [路线图](docs/roadmap.zh-CN.md) · [架构](docs/architecture.zh-CN.md)
- **工程：** [Browser 工程指南](apps/browser/README.zh-CN.md) · [iOS 工程指南](apps/ios/README.zh-CN.md)
- **参考：** [研究与限制](docs/research-map.zh-CN.md) · [历史审计记录](docs/audit/README.zh-CN.md) · [变更记录](CHANGELOG.md)

### 许可证与鸣谢

GCSA 原创源码采用 [Apache-2.0](LICENSE)。Chromium、libtorrent 与其他第三方组件保留各自许可证。

另见[第三方开源鸣谢](THIRD_PARTY_NOTICES.md)。

<details>
<summary>徽章说明</summary>

- **CI**：显示公开 `main` 分支的质量工作流结果，不代表 Chromium 运行或分发验收。
- **C++ 单元测试**：覆盖 standalone C++20 Access 测试，以及 Chromium GoogleTest wiring 和补丁检查，不代表完整 Chromium GoogleTest 或浏览器运行覆盖。
- **Codacy Grade**：显示上游 `gcsagroup/aegis-browser` 的 `main` 分支静态分析结果，不代表测试覆盖率或运行时验收。
- **License**：标识仓库许可证。平台徽章表示产品优先级，不代表发行状态。

</details>
