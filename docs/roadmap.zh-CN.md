# 路线图

[English](roadmap.md) | **简体中文** | [繁體中文](roadmap.zh-TW.md)

当前 Access 开发计划见 [Roadmap TODO：20 个开放工单的依赖、优先级与验收条件](../TODO.md#access-roadmap-todo)。

## 平台口径

三条线同时推进，目标不同。一个平台的进度不会授予另一个平台发行资格。

| 轨道 | 当前目标 |
| --- | --- |
| iOS / iPadOS | 已上架。App Store 1.0.0 已公开。当前工作是这条已发布线的维护，加上 Access 验收。 |
| macOS | 争取发行资格。Chromium 集成已在源码中；运行与分发验收仍未完成。 |
| Windows | 同事负责 Windows 源码移植和原生验收。runner 准入及原生构建、测试、浏览器和安装器验收按既有决定保持暂停。Android 与 Linux 仍是后续评估，不承诺发布日期。 |

macOS 发行资格不等待下一次 iOS 商店提交。iOS 维护和 Access 验收也不等待 macOS 发行资格。Access 顺序见 [TODO.md](../TODO.md#access-roadmap-todo)：先收 [#157](https://github.com/gcsagroup/aegis-browser/issues/157)、[#158](https://github.com/gcsagroup/aegis-browser/issues/158)，再做 [#136](https://github.com/gcsagroup/aegis-browser/issues/136) 与 [#155](https://github.com/gcsagroup/aegis-browser/issues/155) 的网页取证，然后是 iPhone [#137](https://github.com/gcsagroup/aegis-browser/issues/137)、[#160](https://github.com/gcsagroup/aegis-browser/issues/160)、[#138](https://github.com/gcsagroup/aegis-browser/issues/138)。macOS 同步清理 [#165](https://github.com/gcsagroup/aegis-browser/issues/165) 与 [#179](https://github.com/gcsagroup/aegis-browser/issues/179)，再推进 [#140](https://github.com/gcsagroup/aegis-browser/issues/140) 与 [#141](https://github.com/gcsagroup/aegis-browser/issues/141)。

## 证据词汇

- **已进入源码：** 代码存在；构建与运行状态另算。
- **已验证：** 具名源码与声明的测试范围在同一身份下通过。
- **Simulator-qualified：** 具名 iOS 源码与测试范围在指定 Simulator 上通过；真机与分发状态仍需单独证明。
- **具备发布资格：** 同一个可分发产物完成该平台的身份、构建、运行、隐私、签名、安装和发布门禁。

徽章与历史审计记录只证明各自明确声明的范围，不会自动授予发行资格。

## 当前主线 — macOS 发行资格

macOS 是争取桌面发行资格的轨道。Chromium 源码、仓库质量门、独立 C++ 原生测试和部分集成验证已经存在，但项目仍然**不具备正式发行资格**。完整当前源码的 Chromium 运行证据，以及最终签名/公证/分发链仍需独立完成。

先清理 [#165](https://github.com/gcsagroup/aegis-browser/issues/165) 与 [#179](https://github.com/gcsagroup/aegis-browser/issues/179)，再做综合浏览器验收。随后推进 [#140](https://github.com/gcsagroup/aegis-browser/issues/140) 与 [#141](https://github.com/gcsagroup/aegis-browser/issues/141)。这两项缺陷与 iOS Access 顺序并行处理，不把 Windows 工作拉进本轨道。

### MAC-1 — 核心浏览器与 Access Service

**目标：** 在不削弱 fail-closed 边界的前提下，收敛当前浏览器集成与网络路由缺口。

完成标准：

- Access 路由、Profile/StoragePartition ownership 和 NetworkContext 接入具备对应单元/回归测试。
- 必要 Chromium 目标能针对当前固定源码真实编译，并在合格环境运行相应 GoogleTest / browser 场景。
- HTTP/HTTPS 代理、代理不可用以及原生直连场景能够证明预期行为，不出现静默 DIRECT fallback。
- Browser Agent、隐私控制与浏览器原生能力继续保持明确的安全和用户同意边界。

### MAC-2 — 稳定性与发行候选

**目标：** 把已集成源码收敛为可复现、身份绑定的 macOS 候选。

完成标准：

- 从固定 Chromium 源码与有序补丁序列开始的干净重放/构建可复现。
- 同一候选通过代表性浏览、配置隔离、下载、Agent、更新、崩溃/重启以及真实网络场景。
- 性能、隐私/出站与回归审查绑定当前候选，而不是历史补丁头。
- 安装 App 的身份能够精确映射到仓库、Chromium、V8、补丁序列和构建输入。

### MAC-3 — macOS 分发

**目标：** 让首个稳定 Aegis macOS 安装包具备正式分发资格。

完成标准：

- 同一候选完成 Developer ID 签名与公证。
- 在代表性受支持系统验证打包、全新安装、启动、升级和回滚。
- 针对该精确产物完成发布说明、第三方声明、隐私边界和分发授权复核。
- 最后由单独的明确发行决定授权发布；源码合并或 CI 成功本身不代表授权发布。

## 当前主线 — iOS 已上架维护与 Access 验收

iPhone 与 iPad 的 App Store 1.0.0 已公开，外部 Beta 走 [TestFlight](https://testflight.apple.com/join/EwUW1VDx)。原生应用是 SwiftUI/WKWebView，具备普通/私密配置隔离、内嵌 Safari/Share extensions、AgentKit 与 Simulator 基线。当前 iOS 工作维护这条已发布线，并在真机上验收 Access。这不是重写，也不是第一次上架。

Access 验收顺序：先收 [#157](https://github.com/gcsagroup/aegis-browser/issues/157) 与 [#158](https://github.com/gcsagroup/aegis-browser/issues/158)，再做 [#136](https://github.com/gcsagroup/aegis-browser/issues/136) 与 [#155](https://github.com/gcsagroup/aegis-browser/issues/155) 的网页取证，然后是 iPhone [#137](https://github.com/gcsagroup/aegis-browser/issues/137)、[#160](https://github.com/gcsagroup/aegis-browser/issues/160)、[#138](https://github.com/gcsagroup/aegis-browser/issues/138)。下面的 IOS-3 是后续商店候选的门槛。1.0.0 已上架并不关闭这些 Access 工单；源码就绪也不授权下一次提交。

### IOS-1 — 当前源码真机基线

**目标：** 将现有原生产品绑定到当前已提交源码，并突破 Simulator-only 证据上限。

完成标准：

- 当前源码的 Debug/Release 构建以及 Xcode 工程生成输入可复现并完成差异审查。
- iPhone 与 iPad 真机上的导航、私密模式、生命周期、无障碍和代表性站点行为通过。
- Safari extension、Share/App Group 与普通/私密隔离完成真机端到端验证。

### IOS-2 — 产品完善

**目标：** 补齐真正 iOS 产品所需的隐私、策略和 Agent 链路，而不是停留在 Simulator demo。

完成标准：

- PolicyKit 保护覆盖预期真实导航/出站路径，并有隐私回归测试。
- Agent 授权、同意、恢复与内嵌扩展边界在真机完成验证。
- 生产模型路由、真实站点以及任何新增网络/下载能力均经过明确的安全与隐私审查。

### IOS-3 — 分发

**目标：** 让 Aegis 具备 TestFlight 与 App Store 交付条件。

完成标准：

- 所需 entitlement、Development Team 与 provisioning 配置获批且可复现。
- 精确候选完成正式签名与 Archive。
- 完成 TestFlight 安装/升级、Privacy Manifest、App Store 隐私元数据和必要合规材料。
- App Store 提交仍是单独的发行决定，不由源码完成状态自动触发。

## Windows 与后续平台

同事负责 Windows 轨道：[#170](https://github.com/gcsagroup/aegis-browser/issues/170) 的源码对齐，以及 [#182](https://github.com/gcsagroup/aegis-browser/issues/182) 的原生构建、测试和 runner 验收。按 [2026-11-18 的决定](https://github.com/gcsagroup/aegis-browser/issues/182#issuecomment-6977894606)，Windows runner 准入、GN、编译、原生测试、浏览器和安装器验收继续暂停，待同事恢复授权执行。本路线图只记录这一归属。不把 Windows 工作排进 iOS 或 macOS 轨道，也不把 Windows 写成已具备发行资格。

Android 与 Linux 仍是后续评估。现有源码和手动入口保留。它们不阻塞 iOS 维护或 macOS 发行资格，当前也不承诺发布日期。

## 跨平台持续工作

以下工作贯穿整个 Roadmap：

- 共享策略与 Agent Contract 兼容性；
- CI、测试证据和源码身份完整性；
- 安全审查、依赖与许可证维护；
- 明确区分源码状态、测试证据与发行声明的文档。

历史补丁数量、旧测试总数和带日期的验收结果继续保留在[审计记录](audit/README.zh-CN.md)中，不再作为不断变化的 Roadmap 里程碑。

## 发布规则

每个平台独立获得发行资格。任意发行候选都必须让构建、运行、隐私、签名、安装和分发审查指向**同一份精确源码和产物**。一个平台通过永远不会自动授予另一个平台发行状态。
