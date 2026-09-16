# Aegis

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=develop&event=push)](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml?query=branch%3Adevelop) [![C++ 单元测试](https://github.com/quinn521/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=develop&event=push)](https://github.com/quinn521/aegis-browser/actions/workflows/cpp-unit-tests.yml?query=branch%3Adevelop) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=develop)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![当前平台：macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**一个本地优先的隐私与安全浏览器，内置可控的 AI Agent。先做好 macOS，再推进 iPhone 与 iPad。**

Aegis 把隐私控制、安全检查、原生浏览器能力和 AI Agent 直接集成到浏览器中，而不是把扩展作为产品本体。项目仍在持续开发，当前尚未达到正式发行资格。

## 平台优先级

| 平台 | 优先级 | 当前方向 |
| --- | --- | --- |
| **macOS** | **当前主线** | 完成 Chromium 产品、Access Service、真实运行回归、稳定性，以及可签名/公证的发行候选。 |
| **iOS / iPadOS** | **下一主线** | 基于现有 SwiftUI/WKWebView 代码与已记录的 Simulator 基线继续开发，补齐真机与分发链路。 |
| Windows / Android / Linux | 后续 | 保留现有源码与手动验证入口，当前不承诺近期发行。 |

完整阶段定义见[路线图](docs/roadmap.zh-CN.md)。macOS 满足自己的发行条件后可以独立发布，不需要等待 iOS 达到分发状态。

## Aegis 当前包含什么

- **隐私与追踪控制：** 追踪规则、链接清理、Cookie 分类、钓鱼信号以及部分指纹表面的保护。
- **浏览器 Agent：** 模型配置、可见计划、浏览器控制的工具执行，以及敏感动作前的明确用户接管。
- **Access Service：** 原生策略与代理路由组件，包括 fail-closed 路由与 NetworkContext 接入工作。
- **原生下载与浏览器集成：** 能力落在 Chromium 原生下载、设置和浏览器模块，而不是独立扩展产品。
- **原生 iOS 产品：** 已存在 SwiftUI/WKWebView 代码、普通/私密配置隔离、内嵌 Safari/Share extensions 与 AgentKit。

详细边界见 [Browser](apps/browser/README.zh-CN.md)、[iOS](apps/ios/README.zh-CN.md) 和[架构](docs/architecture.zh-CN.md)。

## 当前工程证据

顶部徽章刻意代表不同范围：

- **CI**：当前开发分支的仓库级质量门。
- **C++ 单元测试**：执行 standalone C++20 Access 测试，以及 Chromium GoogleTest wiring / patch contract；它**不代表**完整 Chromium GoogleTest 可执行文件或全部真实浏览器网络场景已经通过。
- **Codacy Grade**：静态分析，不等于运行验收或发行验收。

完整 Chromium 构建、当前浏览器运行行为、真实网络场景、Developer ID 签名、公证、安装与升级验收仍属于 macOS 独立发行门禁。

## macOS 开发入口

工具链由 [.mise.toml](.mise.toml) 固定：

```bash
mise install
mise exec -- node --version
mise exec -- pnpm --version
mise exec -- python3 --version
mise exec -- pnpm --filter @gcsa-aegis/browser status
```

完整本地质量门与仓库流程见 [CI 与开发指南](docs/development/ci.zh-CN.md)。Chromium 需要独立的大型源码 checkout；构建与运行请阅读 [Browser 本地流程](apps/browser/README.zh-CN.md#本地流程)和[工作区说明](WORKSPACES.zh-CN.md)。

## 开发协作流程

当前 `develop` 是维护与集成主线，日常改动遵循：

```text
最新 develop → 功能分支 → 本地验证 → PR → Review / CI → 合并 → develop push CI
```

向默认 `main` 以及上游公开晋升属于独立的受审步骤。精确分支、Review、CI 与上游导出规则统一维护在 [docs/development/ci.zh-CN.md](docs/development/ci.zh-CN.md)。

## Roadmap

1. **MAC-1 — 核心浏览器与 Access Service：** 收敛当前 Chromium 集成、路由和必要回归缺口。
2. **MAC-2 — 稳定性与发行候选：** 当前源码可复现构建、代表性运行/隐私/性能检查和安装 App 验收。
3. **MAC-3 — macOS 分发：** Developer ID 签名、公证、打包、全新安装/升级/回滚与明确发行授权。
4. **IOS-1 — 真机基线：** 在现有原生 iOS 代码上重新绑定当前源码，完成 iPhone/iPad 真机和生命周期验证。
5. **IOS-2 — 产品完善：** 在真机上补齐内嵌扩展、策略、隐私与 Agent 集成。
6. **IOS-3 — 分发：** entitlement/provisioning、签名、Archive、TestFlight 与 App Store 准备。

Windows 与 Android 保持后续评估，不阻塞 macOS → iOS 的产品路线。

## 文档

- [路线图](docs/roadmap.zh-CN.md) · [文档索引](docs/README.zh-CN.md) · [架构](docs/architecture.zh-CN.md)
- [Browser 工程指南](apps/browser/README.zh-CN.md) · [iOS 工程指南](apps/ios/README.zh-CN.md)
- [研究与限制](docs/research-map.zh-CN.md) · [历史审计记录](docs/audit/README.zh-CN.md)
- [变更记录](CHANGELOG.md)

## 许可证

GCSA 原创源码采用 [Apache-2.0](LICENSE)。Chromium、libtorrent 与其他第三方组件保留各自许可证。

## 鸣谢

[第三方开源鸣谢](THIRD_PARTY_NOTICES.md)记录了浏览器基础、依赖组件与开发工具。
