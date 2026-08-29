# 审计记录

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

这里保存按日期形成的阶段性工程记录。每份文件只代表写作时的证据与发布边界，不是实时发布状态页；当前源码与构建关系应以[路线图](../roadmap.zh-CN.md)、新运行的 `pnpm run browser:status`，以及最新的 [iOS 硬化记录](ios-simulator-hardening-2026-08-28.md)和重新执行的 Simulator 测试为准。

## 当前边界

- 当前整合源码包含 67 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁。
- 57 补丁诊断清单和 65 补丁 Agent 验收保留为历史快照，均不绑定当前 67 补丁 HEAD，也不能给它授予资格。
- Android、受信任构建证明、产品身份、签名/公证、安装验收和完整出站审计仍是未关闭门禁。
- Script-risk、MinerGuard 与 bytecode shadow 仍属于研究或仅观察能力，不能授权阻断或发布声明。
- 研究语料必须分开：Phase 2 是 synthetic formal fixture；Phase 3 是 13 样本 operator-blinded public pilot，召回率为 `1/3`。两者都不能泛化。
- iOS 证据仅覆盖 Simulator；真机 Safari/Share 权限、默认浏览器 entitlement、Archive、正式签名、TestFlight、App Store 和发布资格仍是 No-Go 门禁。

## 记录

- [实施前基线](baseline-2026-08-24.md)
- [本地实施进度](implementation-progress-2026-08-24.md)
- [CPU 与研究优化](cpu-and-research-optimization-2026-08-25.md)
- [钓鱼检测差距与路线图](phishing-detection-gap-and-roadmap-2026-08-25.md)
- [JavaScript 反指纹强化](js-fingerprint-hardening-2026-08-26.md)
- [JavaScript 分析与 MinerGuard](js-miner-guard-2026-08-27.md)
- [构建身份与签名](js-build-identity-and-signing-2026-08-27.md)
- [脚本防护第二阶段研究](js-protection-research-phase2-2026-08-27.md)
- [脚本防护第三阶段研究](js-protection-research-phase3-2026-08-28.md)
- [iOS Simulator 资格验收（历史基线）](ios-simulator-qualification-2026-08-28.md)
- [iOS Simulator 硬化验收（当前本地复验）](ios-simulator-hardening-2026-08-28.md)
- [Aegis Browser Agent v1 M0 基线](aegis-agent-m0-baseline-2026-08-28.md)
- [Aegis Browser Agent v1 本地验收](aegis-browser-agent-v1-acceptance-2026-08-29.md)
- [Aegis Browser Agent v1 安全修复验证](aegis-browser-agent-v1-security-fix-verification-2026-08-29.md)

日期化原始记录保留简体中文单一事实源，避免多份证据译本逐渐不一致。本三语索引只概括范围；复用哈希、数量或结论前，必须查看原记录并重新验证。
