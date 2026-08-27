# 架构

[English](architecture.md) | **简体中文** | [繁體中文](architecture.zh-TW.md)

## 产品形态

GCSA-aegis 是集成式 Chromium fork，不是 Electron 套壳，也不把核心能力作为独立扩展交付。

```text
packages/core
  策略、检测器、生成资源、研究性质评测器
        │
        ▼
Chromium 补丁栈与 overlay
        │
        ▼
AegisService / throttles / 存储钩子 / WebUI / 原生界面
        │
        ├── 浏览器本地决策与本机启发式摘要
        └── 可选的用户配置兼容模型 API
```

`packages/core` 是可测试 TypeScript 逻辑和生成资源的构建期来源。`apps/browser` 负责 Chromium 钉扎、补丁栈、overlay、构建脚本、验证工具和平台打包边界。

## 运行路径

1. **网络与导航：**Chromium throttle 应用跟踪器规则、部分第一方收集路径规则、链接清洗、钓鱼检查和本地威胁情报查询。
2. **存储：**Cookie 分类和 bounce tracking 清理在浏览器掌控的生命周期和 Profile 边界内运行。
3. **指纹表面：**Blink 及相关钩子降低部分 Canvas、OffscreenCanvas、Audio、WebGL 和 WebGPU 表面的稳定跨站信号。这是缓解措施，不等于匿名。
4. **下载：**用户界面仍使用 Chromium 下载页。集成层增加有界 HTTP(S) 并行、Metalink 和 BT/Magnet 路径，并设置明确的资源与安全限制。
5. **页面摘要：**renderer 提供有界候选快照，browser 再次验证和脱敏。敏感页面强制回退本机启发式。用户可配置 OpenAI、Claude（Anthropic）或 Gemini 兼容端点；非 loopback 使用必须明确目标并确认。
6. **本地自动化：**所选桌面 CDP 路径增加 loopback、来源和精确文档授权控制。获授权的本地 agent 仍可读取页面 DOM，因此这不是通用数据防泄漏边界。

## 研究路径

仅 Node AST 分析、有界行为/来源函数、本地联邦模拟和 V8 Ignition bytecode shadow 属于研究工具或仅观察仪表。它们不是已部署模型、完整浏览器信息流系统、脚本阻断器，也不能证明通用恶意 JavaScript 防护。

## 当前源码与产物身份

- 现场源码集成包含 56 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁；外部 checkout 与 overlay、补丁谱系一致。
- 最新带身份清单的本地 build-tree 只覆盖 54 个顶层补丁及这 2 个 V8 补丁；由于根仓库当时为 dirty，资格为 `diagnostic-only`。
- 0055、0056 已同步进源码，但没有被该产物身份覆盖。不能把它们的存在与旧运行计数合并后宣称当前版本发行合格。

## 隐私与信任边界

- API 凭据可选，使用操作系统加密保存，按 API 格式与规范化端点隔离，界面不回显。
- 远程摘要文本有长度限制并经过脱敏，但完整 Chromium 出站、遥测、更新、崩溃报告和错误路径审计仍未完成。
- 本地 build-tree 签名或结构验证不等于产品身份、Developer ID 签名、公证、stapling 或安装 App 验收。
- Android 仍阻塞于合格的 x86-64 Linux 构建、当前源码安装包和真实设备验收。

## 发行状态

该架构已进入源码并完成部分本地验证，但产品整体仍为**发行 No-Go**。剩余门禁见[路线图](roadmap.zh-CN.md)，开发操作见 [Browser 指南](../apps/browser/README.zh-CN.md)。
