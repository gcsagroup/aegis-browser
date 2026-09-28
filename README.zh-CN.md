# Aegis browser

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

[开始参与](#开始参与) · [平台进度](#平台进度) · [路线图](docs/roadmap.zh-CN.md) · [文档](docs/README.zh-CN.md)

Aegis 正在开发中，尚无通过发行验收的可分发版本。

## 核心能力

| 能力 | 范围 |
| --- | --- |
| 隐私浏览 | macOS 上的链接、Cookie、钓鱼及部分指纹保护；iOS 普通与私密配置隔离。 |
| 可控 Agent | 可见计划、浏览器策略约束和敏感操作确认；iOS 提供四条离线工作流。 |
| 原生下载 | macOS 上的 Chromium 下载界面与受限下载路径。 |
| 访问策略 | macOS 上的选定流量代理路由；必要路径不可用时按 fail-closed 处理。 |

## 开始参与

### 准备开发环境

安装 Git、[mise](https://mise.jdx.dev/)、ripgrep（`rg`）和 C++20 编译器（默认 `clang++`）。macOS 可用 `xcode-select --install` 安装 Command Line Tools，Homebrew 用户可用 `brew install ripgrep`。信任工具链配置前，请先查看 [`.mise.toml`](.mise.toml)。

```bash
git clone https://github.com/gcsagroup/aegis-browser.git
cd aegis-browser
mise trust .mise.toml
mise install
mise exec -- pnpm install --frozen-lockfile
mise exec -- pnpm run quality:fast
```

这组命令执行共享 workspace 检查，不获取 Chromium，也不构建两端原生 App。

### 从源码构建 macOS 浏览器

[Browser 指南](apps/browser/README.zh-CN.md)包含主机依赖、`depot_tools`、独立 Chromium 源码、补丁重放、构建与验证步骤。

### 打开 iOS 工程

打开 `apps/ios/Aegis.xcodeproj`；Xcode 和 iPhone/iPad Simulator 配置见 [iOS 指南](apps/ios/README.zh-CN.md)。仅重新生成工程时需要 XcodeGen。

## 平台进度

| 平台 | 优先级 | 状态 |
| --- | --- | --- |
| macOS | 当前 | Chromium 与 Access 集成推进中；当前源码的运行、真实网络和分发验收待完成。 |
| iOS / iPadOS | 下一阶段 | 已有记录的 Simulator 基线；当前源码、真机和分发验收待完成。 |
| Windows / Android / Linux | 后续 | 保留源码和评估工具，暂不承诺近期发行。 |

macOS 可独立于 iOS 达到发行条件。完成标准见[路线图](docs/roadmap.zh-CN.md)。

## 隐私与 AI

远程摘要会将经过浏览器校验、裁剪和脱敏的页面内容发往所选模型端点；非 loopback 目的地需要明确选择并确认。敏感页面使用设备端启发式处理。Agent 操作受浏览器策略约束，敏感操作需单独确认；iOS Agent 离线运行。这些控制不构成通用的数据防泄漏系统，详见[隐私边界](docs/architecture.zh-CN.md)。

## 架构

| 目录 | 职责 |
| --- | --- |
| [`packages/core`](packages/core) | 共享 TypeScript 策略、生成资源和 Agent 契约。 |
| [`apps/browser`](apps/browser) | Chromium fork、原生服务、构建和桌面打包。 |
| [`apps/ios`](apps/ios) | 原生 SwiftUI/WKWebView App 与内嵌扩展。 |

## 贡献与文档

### 参与贡献

Fork [`gcsagroup/aegis-browser`](https://github.com/gcsagroup/aegis-browser)，向上游 `main` 提交范围聚焦的 PR，附上验证结果和已知限制。

### 文档导航

[文档索引](docs/README.zh-CN.md) · [架构](docs/architecture.zh-CN.md) · [研究](docs/research-map.zh-CN.md) · [历史审计](docs/audit/README.zh-CN.md) · [变更记录](CHANGELOG.zh-CN.md)

### 许可证与鸣谢

GCSA 原创源码采用 [Apache-2.0](LICENSE)。第三方组件保留各自许可证，见[第三方声明](THIRD_PARTY_NOTICES.md)。

<details>
<summary>徽章说明</summary>

- **CI：**公开 `main` 分支的质量检查。
- **C++ 单元测试：**standalone Access 测试、Chromium GoogleTest 接线与补丁检查。
- **Codacy Grade：**上游 `main` 的静态分析，不是测试覆盖率。

这些徽章不代表浏览器运行或发行验收通过。

</details>
