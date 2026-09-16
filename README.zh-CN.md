# Aegis

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![C++ 单元测试](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![当前平台：macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**一个本地优先的隐私与安全浏览器，内置可控的 AI Agent。先做好 macOS，再推进 iPhone 与 iPad。**

Aegis 把隐私控制、安全检查、原生浏览器能力和 AI Agent 直接集成到浏览器中。项目仍在持续开发，当前尚未达到正式发行资格。

## 平台优先级

| 平台 | 优先级 | 当前方向 |
| --- | --- | --- |
| **macOS** | **当前** | 完成 Chromium 集成、Access Service、真实运行回归、稳定性，以及可签名/公证的发行候选。 |
| **iOS / iPadOS** | **下一阶段** | 基于现有 SwiftUI/WKWebView 代码与已记录的 Simulator 基线继续开发，补齐真机与分发链路。 |
| Windows / Android / Linux | 后续 | 保留现有源码与评估入口，当前不承诺近期发行。 |

详细完成标准见[路线图](docs/roadmap.zh-CN.md)。macOS 满足自己的发行条件后可以独立发布，不需要等待 iOS 达到分发状态。

## Aegis 当前包含什么

- **隐私与追踪控制：** 追踪规则、链接清理、Cookie 分类、钓鱼信号以及部分指纹表面的保护。
- **浏览器 Agent：** 模型配置、可见计划、浏览器控制的工具执行，以及敏感动作前的明确用户接管。
- **Access Service：** 原生策略与代理路由组件，包括 fail-closed 路由与 NetworkContext 接入。
- **原生浏览器集成：** 能力落在 Chromium 原生下载、设置和浏览器模块，而不是独立扩展产品。
- **原生 iOS 产品：** SwiftUI/WKWebView、普通/私密配置隔离、内嵌 Safari/Share extensions 与 AgentKit。

详细工程边界见 [Browser 指南](apps/browser/README.zh-CN.md)、[iOS 指南](apps/ios/README.zh-CN.md)和[架构](docs/architecture.zh-CN.md)。

## 工程证据

顶部徽章代表不同范围：

- **CI**：公共 `main` 的仓库级质量门。
- **C++ 单元测试**：执行 standalone C++20 Access 测试，以及 Chromium GoogleTest wiring / patch contract；它**不代表**完整 Chromium GoogleTest 可执行文件或全部真实浏览器运行场景已经通过。
- **License / 平台徽章**：描述仓库许可证与当前产品优先级，不代表发行资格。

完整 Chromium 构建、当前浏览器运行行为、真实网络场景、Developer ID 签名、公证、安装与升级验收仍属于 macOS 独立发行门禁。

## 快速开始

仓库固定 Node.js `22.23.1`、pnpm `9.15.0` 和 Python `3.11.9`。

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

Chromium 开发需要独立的大型源码 checkout，请从 [Browser 工程指南](apps/browser/README.zh-CN.md)开始。原生 Apple 平台开发请阅读 [iOS 工程指南](apps/ios/README.zh-CN.md)。

## Roadmap

1. **MAC-1 — 核心浏览器与 Access Service：** 收敛当前 Chromium 集成、路由和必要回归缺口。
2. **MAC-2 — 稳定性与发行候选：** 当前源码可复现构建、代表性运行/隐私/性能检查和安装 App 验收。
3. **MAC-3 — macOS 分发：** Developer ID 签名、公证、打包、全新安装/升级/回滚与明确发行授权。
4. **IOS-1 — 真机基线：** 在现有原生 iOS 代码上重新绑定当前源码，完成 iPhone/iPad 真机和生命周期验证。
5. **IOS-2 — 产品完善：** 在真机上补齐内嵌扩展、策略、隐私与 Agent 集成。
6. **IOS-3 — 分发：** entitlement/provisioning、签名、Archive、TestFlight 与 App Store 准备。

Windows、Android 与 Linux 保持后续评估，不阻塞 macOS → iOS 的产品路线。

## 参与贡献

欢迎提交贡献。每个 PR 应保持范围聚焦，并提供与改动相关的测试或验证证据。

1. Fork 本仓库。
2. 从当前 `main` 创建独立 topic branch。
3. 完成一个聚焦的改动，并补充或更新相关测试。
4. 按受影响模块的文档运行适用的本地检查。
5. 将分支推送到自己的 Fork，并向本仓库 `main` 提交 Pull Request。
6. 在 PR 描述中说明问题、改动范围、测试证据和仍存在的限制。
7. 在同一个 PR 中处理 Review 反馈，不改写无关历史。

Chromium 改动请先阅读 [Browser 指南](apps/browser/README.zh-CN.md)；iOS 改动请阅读 [iOS 指南](apps/ios/README.zh-CN.md)。

## 文档与许可证

| 文档 | 许可证与鸣谢 |
| --- | --- |
| [路线图](docs/roadmap.zh-CN.md) · [文档索引](docs/README.zh-CN.md) · [架构](docs/architecture.zh-CN.md)<br>[Browser 工程指南](apps/browser/README.zh-CN.md) · [iOS 工程指南](apps/ios/README.zh-CN.md)<br>[研究与限制](docs/research-map.zh-CN.md) · [历史审计记录](docs/audit/README.zh-CN.md)<br>[变更记录](CHANGELOG.md) | GCSA 原创源码采用 [Apache-2.0](LICENSE)。<br>Chromium、libtorrent 与其他第三方组件保留各自许可证。<br>[第三方开源鸣谢](THIRD_PARTY_NOTICES.md) |
