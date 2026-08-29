# GCSA-aegis

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

GCSA-aegis 是一个本地优先的隐私与安全浏览器项目，现有两条产品线：[`apps/browser`](apps/browser/README.zh-CN.md) 下的 Chromium 分支，以及 [`apps/ios`](apps/ios/README.zh-CN.md) 下的原生 iOS 浏览器。核心能力集成在各自的浏览器产品内；项目不会复活已退役的独立扩展产品。

> **状态 — 2026-08-29：** 整合后的源码包含 67 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁。此前的 57 补丁诊断清单和 65 补丁 Agent 验收仅为历史证据，不能给当前 67 补丁 HEAD 授予资格。原生 iOS 产品仍只在已记录的 Simulator 范围内为 **SIMULATOR_QUALIFIED**。项目整体仍是 **发行 No-Go**，还需补齐当前整合源码的构建/运行证据、受信任证明、正式签名、公证、已安装分发包验收、iOS 真机验证和当前源码的 Android 包。

普通桌面 Profile 正常启动后会直接显示 Agent 入口。模型调用、工具和监控仍需用户在 `chrome://aegis` 显式开启；WebMCP 与交易提交能力继续默认关闭。

## 产品形态

- **Chromium 产品线：** [`apps/browser`](apps/browser/README.zh-CN.md) 负责 Chromium 固定版本、补丁栈、浏览器集成、构建和平台打包边界。
- **原生 iOS 产品线：** [`apps/ios`](apps/ios/README.zh-CN.md) 已实现 SwiftUI/WKWebView 浏览器、普通与私密配置隔离、内嵌 Safari/Share extensions 和 Agent Broker。
- **共享策略与合同源：** [`packages/core`](packages/core) 提供可测试策略、生成资产，以及由 TypeScript 与 Swift 共用的 Agent Contract v1 Schema 和 Golden Vectors。
- **iOS Agent 范围：** 深度研究、浏览器管家、安全下载和购物助手四个受控工作流返回确定性结果，可离线验证；这不构成生产远程模型链路的证据。
- **扩展边界：** Safari 与 Share target 是 iOS App 的内嵌组件；独立 `apps/extension` 产品仍被禁止。

## 证据边界

源码同步、干净的外部 Chromium checkout 和 iOS Simulator 资格属于不同证据层级，均不能证明对应当前源码已经通过全部构建、运行、签名、安装、真机、隐私、商店和发布门禁。

历史 Chromium 测试数量、清单和产物哈希保留在带日期的审计记录中，不得跨补丁 HEAD 拼接或写成当前发行证据。研究证据也必须分开：Phase 2 是 synthetic formal fixture，Phase 3 是 13 样本 operator-blinded public pilot，召回率为 `1/3`；两者都不能泛化为广义恶意 JavaScript 检测结论。iOS 的 `SIMULATOR_QUALIFIED` 仅限具名 Simulator 链路，不是真机、分发或 App Store 证据。

## 快速开始

JavaScript 工具链固定为 Node.js `24.14.0` 和 pnpm `9.15.0`。

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

准备和构建 Chromium 需要大型外部 checkout。执行联网、构建、打包或运行命令前，请先阅读[浏览器指南](apps/browser/README.zh-CN.md)。原生 App 的构建与测试说明见 [iOS 工程指南](apps/ios/README.zh-CN.md)；其安全默认测试入口是：

```bash
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

## 仓库结构

```text
apps/browser       Chromium 固定版本、overlay、补丁、构建与验证脚本
apps/ios           原生 iOS App、内嵌扩展、AgentKit 与 Simulator 测试
packages/core      共享策略、检测器、生成资产与 Agent Contract v1
docs/              架构、路线图、研究映射、产品页与审计记录
```

## 文档

- [文档索引](docs/README.zh-CN.md)
- [架构](docs/architecture.zh-CN.md)
- [路线图与发布门禁](docs/roadmap.zh-CN.md)
- [iOS 工程指南](apps/ios/README.zh-CN.md)
- [研究到实现映射](docs/research-map.zh-CN.md)
- [三语产品页](docs/product.html)
- [更新日志](CHANGELOG.md)

## GitHub 同步边界

2026-08-28 已授权通过 SSH 将源码仓库同步到 `git@github.com:gcsagroup/aegis-browser.git`。该授权仅覆盖源码分支同步，不授权创建或发布 Git tag、GitHub Release、二进制、安装包、签名凭据、公证提交、Play 上传、TestFlight 构建、App Store 提交或生产部署。

## 许可证

Apache-2.0，见 [LICENSE](LICENSE)。

## 测试

```bash
pnpm run quality:fast
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

这些命令覆盖仓库快速 JavaScript/脚本门禁和不产生变更的 iOS Simulator 预检。Chromium 原生构建与当前头运行矩阵、iOS `--execute` 结果、真机、签名、打包、安装和商店验收仍是独立门禁。
