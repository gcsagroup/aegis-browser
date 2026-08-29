# 路线图

[English](roadmap.md) | **简体中文** | [繁體中文](roadmap.zh-TW.md)

## 状态词汇

- **历史原型：** 只能证明方向，不能代表当前可交付物。
- **已进入源码：** 代码或补丁存在；构建和运行状态另算。
- **源码已同步：** 补丁血统、overlay 和外部 checkout 一致。
- **Simulator-qualified：** 具名 iOS 源码与测试范围在指定 iPhone/iPad Simulator 上共同运行；真机、签名、分发和商店状态另算。
- **门禁已通过：** 具名源码、产物、平台和代表性测试范围共同通过。
- **具备发布资格：** 同一可分发产物通过身份、信任、签名、安装、隐私、平台和投放门禁。

## 当前结论 — 2026-08-29

当前整合 Chromium 源码包含 67 个顶层补丁和 2 个嵌套 V8 补丁。此前的 57 补丁诊断清单和 65 补丁 Agent 验收保留为历史快照，均不绑定当前 67 补丁 HEAD，也不能给它授予资格；当前仍需重新完成精确重放、身份绑定构建和受影响运行验收。

原生 iOS 产品已具备 SwiftUI/WKWebView 浏览器、普通/私密隔离、内嵌 Safari/Share extensions、Agent Broker、四个离线确定性工作流、共享 Agent Contract v1 向量，以及 iPhone/iPad Simulator 链路。当前证据上限为 **SIMULATOR_QUALIFIED**。真机验证为 `NOT_RUN`；默认浏览器 entitlement 为 `PENDING`；正式签名、Archive、TestFlight 和 App Store 交付均为 `NOT_RUN`。

项目整体为 **release No-Go**。两条产品线都没有同时具备可信当前源码分发包和完整发布门禁证据。

## 历史阶段

### 阶段 0 — 脚手架

Monorepo、三语产品页和核心策略原型建立了产品方向。

### 阶段 1 — 扩展原型

MV3 扩展验证了部分追踪器、钓鱼和隐私摘要思路。它不再是独立产品或发布目标。

### 阶段 2 — 核心原型

链接清理、Cookie 分类、PII 脱敏、钓鱼启发式和生成策略资产进入可复用、可测试代码。仅研究评估器仍与浏览器决策分离。

## 阶段 3 — Chromium 产品线

### M0：基线与恢复 — 完成

- Chromium 固定为版本 `151.0.7922.77` 和基础提交 `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`。
- 已有本地恢复点和证据保留边界。

### M1：Chromium 收敛与快速门禁 — 完成

- 历史 browser-only 收敛退役了独立扩展产品，并把 Chromium 能力集中到 `apps/browser`。
- 该边界禁止独立 `apps/extension`，不禁止之后建立带内嵌扩展的原生平台浏览器。
- Workspace 已冻结 JavaScript 依赖，并有可重复快速质量门禁。

### M2：Chromium 集成与本地构建身份 — 部分完成

- 有序源码现包含 67 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁。
- 57 补丁诊断清单和 65 补丁 Agent 候选保留各自已记录的本地证据，但只覆盖对应历史 HEAD。
- 65 补丁候选通过了具名原生、浏览器、fixture、生命周期和本地 UI 范围；它不是已签名、公证和安装验收的分发包。
- 当前 67 补丁 HEAD 仍需重新完成干净重放、精确身份清单、受影响测试和运行验收。

### M3–M4：安全边界与稳定性 — 部分完成

- Chromium 原生追踪器、链接、Cookie、钓鱼、指纹、下载、摘要和本地自动化控制已进入源码。
- 具名早期补丁头通过过部分历史原生、浏览器和运行门禁。
- MinerGuard 和 V8 字节码影子仍是 observe-only；研究评估器不授权拦截或生产安全声明。
- 当前诊断产物上的 bytecode-shadow v5 按固定研究协议在两个公开站点完成 4/4 运行；其报告仍为 `research-only`，且 `releaseEligible=false`。
- 完整的产品级出站归因、遥测/更新/崩溃报告复核、代表性功能行为矩阵、启动压力、误报评估和更广泛的当前头重跑仍未完成。

### M5：Android — 后置

- 当前证据集中没有合格的 x86-64 Linux 构建环境。
- 当前源码没有绑定身份的 APK/AAB，也没有真机验收。
- Android 页面摘要和平台特定行为需要当前源码验证。

### M6：Chromium 内部候选版本 — 待完成

Chromium 内部 RC 需要干净、绑定身份的当前源码构建、受影响测试和运行门禁、产品身份、签名与公证准备、打包、已安装 App 验收、隐私/出站复核和回滚证据。不得从源码同步推导这些结论。

## 阶段 4 — 原生 iOS 产品线

### I0：工程与产品拓扑 — Simulator-qualified 范围

- 原生 Xcode 工程定义 Aegis App、BrowserKit、AegisPolicyKit、AgentKit、内嵌 Safari/Share extensions 和 iPhone/iPad 单元/UI 测试 targets。
- iOS App 是产品线；其 extension targets 仍是内嵌组件，不是独立产品。

### I1：浏览器外壳与配置隔离 — Simulator-qualified 范围

- 已有 SwiftUI/WKWebView 标签页、导航、普通历史/收藏、iPhone 紧凑界面和 iPad 侧栏。
- 普通与私密配置隔离数据存储、用户内容控制器和扩展状态；私密模式不持久化，并禁用历史、收藏和 Agent。
- 最低系统、多 runtime、生命周期、真实站点和真机矩阵仍待完成。

### I2：内嵌扩展与策略路径 — 部分完成

- Safari 已有手势/租约约束的只读快照门，并以 document token 与 navigation epoch 绑定授权文档；Share 已有有界、会过期且只能消费一次的 HTTP(S) URL inbox。
- BrowserSession 主框架导航已接入 LinkSanitizer 与 PhishingScorer，并提供追踪参数清理和高风险 URL 拦截；PII 出站保护仍未接入真实数据链。
- 真实 Safari 权限、App Group 行为、Share 到 App 生命周期和真机端到端验收仍未完成。

### I3：Agent Contract v1 与四个工作流 — Simulator-qualified 离线范围

- AgentKit 已实现共享合同 codec/向量、授权、文档租约、资源登记、一次性能力、Broker、同意状态和恢复边界。R1/R2 批准使用随机 ID、最长 60 秒 TTL、完整动作摘要、精确恢复校验和签发前销毁。
- 深度研究、浏览器管家、安全下载和购物助手可离线确定性验证。
- 本地收藏应用/撤销事务、认证加密 journal、崩溃恢复判定和跨重启后的 Agent 双确认撤销入口已在 Simulator 范围实现；真实 DOM 抽取、实际下载、生产模型路由、支付和下单仍不属于已实现发布证据。
- 最终具名证据使用 Aegis-Debug、Xcode 26.6 与 iOS Simulator 26.5：iPhone 17 共 81 项，80 通过，按设计跳过仅适用于 iPad 的侧栏测试；iPad Air 11-inch (M4) 81/81 通过。39/39 安全定向单元测试和 2/2 关键 UI 测试是上述完整套件的子集，不能另行相加。

### I4：真机与分发 — 待完成

- 真机浏览器、私密模式、Safari、Share、生命周期、性能、无障碍和隐私验收为 `NOT_RUN`。
- 默认浏览器 entitlement 与批准为 `PENDING`。
- Development Team/provisioning、正式签名、Archive、TestFlight、App Store 元数据/隐私声明、安装、升级和回滚均为 `NOT_RUN`。

## 跨产品工作
### M6：macOS 本地发行候选 — 已完成；分发资格待完成

精确当前源码已有干净、带身份绑定的 macOS 本地构建、受影响测试、fixture 运行证据、A1–A10 验收、完整固定提交区间安全审计，以及 11 项发现的修复验证。产品身份、受信任构建证明、Developer ID 签名、公证、分发打包、安装 App 验收、完整 Chromium 出站审查、Android 和发行授权仍未完成，因此正式发行仍为 No-Go。

### M7：文档与发布边界 — 进行中

- 公共 README、架构和路线图用英文、简体中文和繁体中文描述两条产品线。
- 带日期的审计记录仍是历史快照，不能覆盖本路线图。
- 源码发布、安装包发布、TestFlight、App Store 和生产部署仍是不同决策。

## GitHub 源码同步

2026-08-28 授权覆盖通过 SSH 将源码分支同步到 `git@github.com:gcsagroup/aegis-browser.git`，不覆盖 Git tag、GitHub Release、二进制、签名凭据、公证、Play 上传、TestFlight、App Store 提交或生产部署。

## 发布退出标准

1. 从干净状态提交并复现两条产品线的精确当前源码及嵌套血统。
2. 在合格主机上产出绑定身份的当前源码 Chromium 与 iOS 分发候选。
3. 在这些精确候选上通过受影响单元、浏览器、运行、隐私、出站、性能、代表性站点、Simulator 和真机门禁。
4. 分别完成 Chromium 身份/签名/公证/打包门禁，以及 iOS entitlement/provisioning/签名/Archive/TestFlight/App Store 门禁。
5. 对精确候选完成安装、升级、回滚、隐私/出站、第三方声明、文档与分发授权复核。
