# 架构

[English](architecture.md) | **简体中文** | [繁體中文](architecture.zh-TW.md)

## 产品形态

GCSA-aegis 有两条集成式浏览器产品线：Chromium 分支面向桌面和 Android 路线，原生 iOS App 使用 SwiftUI 和 WKWebView。已退役的独立扩展产品仍不在范围内。

```text
                         packages/core
          策略、生成资产、Agent Contract v1 与 Golden Vectors
                               │
             ┌─────────────────┴─────────────────┐
             ▼                                   ▼
apps/browser：Chromium 分支             apps/ios：原生 iOS App
补丁栈 + 浏览器服务                     SwiftUI + WKWebView
             │                          BrowserKit / PolicyKit / AgentKit
             ▼                                   │
原生界面与平台打包                      内嵌 Safari + Share extensions
```

`packages/core` 是可测试 TypeScript 逻辑、生成资源和共享 Agent Contract v1 的构建期来源。`apps/browser` 负责 Chromium 固定版本、补丁栈、overlay、构建脚本和平台打包边界。`apps/ios` 负责原生 Xcode 工程及内嵌扩展；这些扩展不是新的独立产品。

## Chromium 运行路径

1. **网络与导航：**Chromium throttle 应用跟踪器规则、部分第一方收集路径规则、链接清洗、钓鱼检查和本地威胁情报查询。
2. **存储：**Cookie 分类和 bounce tracking 清理在浏览器掌控的生命周期和 Profile 边界内运行。
3. **指纹表面：**Blink 及相关钩子降低部分 Canvas、OffscreenCanvas、Audio、WebGL 和 WebGPU 表面的稳定跨站信号。这是缓解措施，不等于匿名。
4. **下载：**用户界面仍使用 Chromium 下载页。集成层增加有界 HTTP(S) 并行、Metalink 和 BT/Magnet 路径，并设置明确的资源与安全限制。
5. **页面摘要：**renderer 提供有界候选快照，browser 再次验证和脱敏。敏感页面强制回退本机启发式。用户可配置 OpenAI、Claude（Anthropic）或 Gemini 兼容端点；非 loopback 使用必须明确目标并确认。
6. **本地自动化：**所选桌面 CDP 路径增加 loopback、来源和精确文档授权控制。获授权的本地 agent 仍可读取页面 DOM，因此这不是通用数据防泄漏边界。
7. **浏览器 Agent：**由浏览器掌控的策略代理负责书签维护、URL 健康检查、有界页面操作、下载、工作流、监控和结账准备的规划与执行。Observe/Ask/Act 模式、逐动作策略、审批回执、文档绑定、秘密脱敏、取消和审计历史均在模型层以下强制执行；v1 不授权无人值守完成最终购买。

## 原生 iOS 运行路径

1. **浏览器外壳：** SwiftUI 为 iPhone 提供紧凑导航，为 iPad 提供侧栏，并承载 WKWebView 标签页、地址/搜索输入、导航控制、历史和收藏。
2. **配置隔离：** 普通与私密配置使用不同的 WKWebsiteDataStore、WKUserContentController 和扩展运行状态。私密浏览不持久化，并禁用历史、收藏和 Agent。
3. **内嵌扩展：** SafariWebExtension 提供由用户手势触发、短租约约束的只读页面快照路径，并以 isolated-world document token、navigation epoch、tab/frame/origin 和 worker instance 绑定授权与结果；ShareExtension 把有界 HTTP(S) URL 写入专用、会过期且只能消费一次的 App Group inbox。真实 Safari 权限和真机 App Group 行为尚未验证。
4. **策略模块：** BrowserSession 的主框架导航会在网络加载前调用 AegisPolicyKit 的 LinkSanitizer 与 PhishingScorer，分别重写追踪参数和阻止高风险 URL，并显示可见策略提示。PII 扫描与策略快照解析已有源码和测试，但尚未接入真实出站数据链。
5. **Agent Broker：** AgentKit 实现共享 Agent Contract v1、不可变任务授权、文档租约、资源登记和一次性动作能力。R1/R2 动作需要独立确认：随机批准 ID、最长 60 秒 TTL 与摘要共同绑定完整授权、工具、规范参数、序列、最终目标和风险；恢复校验 ID/摘要/TTL，签发入场先销毁批准，随后 capability 仍只能消费一次。用户同意前只允许本地确定性范围；私密配置拒绝 Agent 使用。
6. **离线工作流：** 四个工作流都可离线验证。浏览器管家在独立 R1 动作确认后执行真实的 Aegis 本地收藏事务；before/after 树哈希、认证加密 journal、崩溃过渡判定和状态漂移检查保护应用与撤销。App 重启后的撤销不会自动执行，必须重新取得任务授权和独立 R1 动作确认。深度研究、安全下载和购物助手仍不执行真实 DOM 抽取、实际下载、远程模型调用、支付或下单。
7. **Simulator 链路：** 仓库内 Xcode 工程和测试脚本面向专用 iPhone 与 iPad Simulator，只支持 `SIMULATOR_QUALIFIED` 证据。

## 仅研究路径

Node-only AST 分析、有界行为/来源函数、本地联邦模拟和 V8 Ignition 字节码影子属于研究工具或 observe-only 插桩。它们不是已部署模型、完整浏览器信息流系统、脚本拦截器，也不能证明通用恶意 JavaScript 防护。

## 当前源码与产物身份

- 当前整合 Chromium 源码包含 67 个顶层补丁和 2 个嵌套 V8 补丁。
- 57 补丁诊断清单和 65 补丁 Agent 验收属于历史快照，均不绑定当前 67 补丁 HEAD，也不能给它授予资格。
- 当前整合 HEAD 必须重新完成精确重放、身份绑定构建和受影响运行验收，才能成为当前本地候选。
- 原生 iOS 源码包含 App、BrowserKit、AegisPolicyKit、AgentKit、Safari/Share extension targets、共享合同向量和 iPhone/iPad Simulator 测试链路；当前证据上限为 `SIMULATOR_QUALIFIED`。
- 不得把 Simulator 资格与未运行的真机或分发门禁拼接成 iOS 发布资格。

## 隐私与信任边界

- Chromium API 凭据是可选项，通过操作系统加密存储，并按 API 格式和规范化端点隔离，界面不回显。
- 远程摘要文本有界且经过脱敏，但完整 Chromium 出站、遥测、更新、崩溃报告和错误路径审计仍待完成。
- 当前 iOS Agent 工作流离线运行，不构成生产远程模型路径。Safari 访问只读并受手势/租约约束；Share inbox 仅接收 URL，具有大小限制、过期和单次消费约束。
- 本地或 Simulator 签名与结构检查不等于产品身份、分发签名、公证、provisioning、Archive、TestFlight 或已安装真机验收。
- Chromium Android 仍受阻于合格 x86-64 Linux 构建、当前源码产物和真机验收。
- iOS 真机验证为 `NOT_RUN`；默认浏览器 entitlement 为 `PENDING`；正式签名、Archive、TestFlight 和 App Store 交付均为 `NOT_RUN`。

## 发布状态

两条产品线均已在源码中实现不同范围，且本地证据上限不同；项目整体仍是 **release No-Go**。剩余门禁见[路线图](roadmap.zh-CN.md)，开发操作见 [Chromium 浏览器指南](../apps/browser/README.zh-CN.md)和 [iOS 工程指南](../apps/ios/README.zh-CN.md)。
