# 审计记录

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

这里保存按日期形成的阶段性工程记录。每份文件只代表写作时的证据与发布边界，不是实时发布状态页；当前源码与构建关系应以[路线图](../roadmap.zh-CN.md)和新运行的 `pnpm run browser:status` 为准。

## 当前边界

- 当前源码包含 56 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁。
- 最新 macOS Release build-tree 清单只绑定较早的 54 + 2 状态；它只是本地诊断证据，不能证明 0055/0056，也不是已签名、公证或可分发产物。
- Android、受信任构建证明、产品身份、签名/公证、安装验收和完整出站审计仍是未关闭门禁。
- Script-risk、MinerGuard 与 bytecode shadow 仍属于研究或仅观察能力，不能授权阻断或发布声明。

## 记录

- [实施前基线](baseline-2026-08-24.md)
- [本地实施进度](implementation-progress-2026-08-24.md)
- [CPU 与研究优化](cpu-and-research-optimization-2026-08-25.md)
- [钓鱼检测差距与路线图](phishing-detection-gap-and-roadmap-2026-08-25.md)
- [JavaScript 反指纹强化](js-fingerprint-hardening-2026-08-26.md)
- [JavaScript 分析与 MinerGuard](js-miner-guard-2026-08-27.md)
- [构建身份与签名](js-build-identity-and-signing-2026-08-27.md)
- [脚本防护第二阶段研究](js-protection-research-phase2-2026-08-27.md)

日期化原始记录保留简体中文单一事实源，避免多份证据译本逐渐不一致。本三语索引只概括范围；复用哈希、数量或结论前，必须查看原记录并重新验证。
