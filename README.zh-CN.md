# GCSA-aegis

本机开发与验收请先看[唯一源码入口及工作区说明](WORKSPACES.zh-CN.md)。旧补丁身份不代表当前 App。

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

GCSA-aegis 是一个本地优先的隐私与安全浏览器项目，现有两条产品线：[`apps/browser`](apps/browser/README.zh-CN.md) 下的 Chromium 分支，以及 [`apps/ios`](apps/ios/README.zh-CN.md) 下的原生 iOS 浏览器。核心能力集成在各自的浏览器产品内；项目不会复活已退役的独立扩展产品。

> **2026-09-22 当前本地候选：** macOS Ver 2.0 (061)，Chromium 153.0.8010.53，202+3 补丁；已处理已知 P1、P2，539 项原生回归及本批定向实机验收完成。整体门槛未重测关闭，后续文案、性能及远端适配等待决定。[修复与后续范围](docs/audit/p1-p2-followup-2026-09-22.zh-CN.md)

> 历史 057 验收记录：**2026-09-22 当前本地候选：** macOS Ver 2.0 (057)，Chromium 153.0.8010.53，198+3 补丁；535 项原生回归通过，统一任务验收 75/90，整体门槛尚未通过。远端独有网络开发线、正式发行及跨平台验收另行处理。[最终收尾报告](docs/audit/integration-final-batch-2026-09-22.zh-CN.md)

> **历史记录：2026-09-14 源码更新：界面整改与浏览器更新：** 当前源码包含 113 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁。本地 macOS 验收为 Ver 1.1 (018)：32 项整改完成，18 项原生测试、116 项界面回归通过，170 条改动文案及翻译占位符检查通过。Windows/Android 实机及真实 Release 安装尚未验收；本次仅提交源码，不发布二进制或 tag。 [018 验收记录](docs/ui-copy-acceptance.zh-CN.md)

> **历史状态 — 2026-09-10：** Browser Agent v2 候选源码包含 108 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁，可精确重放到 Chromium 提交 源码树 `319366182c31108e29e62d2f2199aff29a0b86e8`。57、65、67、95 和 97 补丁记录只保留为历史证据。原生 iOS 产品仍只在已记录的 Simulator 范围内为 **SIMULATOR_QUALIFIED**。项目整体仍是 **发行 No-Go**，还需受信任证明、正式签名、公证、已安装分发包验收，以及本轮明确后置的 iOS 门禁。

[2026-09-10 main 合并与验证](docs/audit/main-consolidation-2026-09-10.md)

普通桌面 Profile 和 Android 都会显示 Agent 入口。第一次任务可直接配置并启用用户选择的模型，不要求用户先选工作流或预先打开网页。WebMCP 与交易提交能力继续默认关闭，最终结账/付款必须由用户接管。

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
