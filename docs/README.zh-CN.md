# 文档

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

本目录保存 GCSA-aegis 的公开产品架构、路线图、研究边界、产品页，以及带日期的本地审计记录。

> **当前边界 — 2026-09-10：** Browser Agent v2 候选源码包含 108 个顶层 Chromium 补丁和 2 个嵌套 V8 补丁，可精确重放到 Chromium 提交 源码树 `319366182c31108e29e62d2f2199aff29a0b86e8`。平台构建和验收仍是独立门禁，这个源码身份不代表公开发行合格。Phase 2 仍是 synthetic formal fixture，Phase 3 是 13 样本 operator-blinded public pilot，召回率为 `1/3`；两者都不能泛化为广义恶意 JavaScript 检测结论。项目整体仍为发行 No-Go。

[2026-09-10 main 合并与验证](audit/main-consolidation-2026-09-10.md)

## 从这里开始

- [项目概览](../README.zh-CN.md)
- [架构](architecture.zh-CN.md)
- [路线图与发行门禁](roadmap.zh-CN.md)
- [研究与实现映射](research-map.zh-CN.md)
- [变更日志](../CHANGELOG.zh-CN.md)
- [三语产品页](product.html)
- [Browser 构建与验证指南](../apps/browser/README.zh-CN.md)
- [原生 iOS 工程指南](../apps/ios/README.zh-CN.md)
- [Browser Agent v2 用户指南](aegis-browser-agent-v2-user-guide.zh-CN.md)
- [Browser Agent v1 历史用户指南](aegis-browser-agent-v1-user-guide.zh-CN.md)
- [Browser Agent 架构](aegis-browser-agent-v1-architecture.zh-CN.md)
- [Browser Agent v2 架构与原型决策](aegis-browser-agent-v2-architecture.zh-CN.md)

## 状态用语

- **已进源码：**代码或补丁存在，不等于构建或运行证明。
- **源码已同步：**仓库 overlay、补丁栈与外部 Chromium checkout 一致。
- **本地已验证：**明确命名的源码、产物、测试和运行范围通过了记录中的本地门禁。
- **发行合格：**同一产物的身份、信任、签名、安装、平台、隐私和分发门禁全部通过。GCSA-aegis 尚未达到该状态。

不同补丁 HEAD 的结果不能相加。历史 App、APK、测试数量或哈希只证明记录中命名的快照。

## 带日期的计划与审计

文件名中带日期的文件属于证据快照、计划或实施记录。其“当前”只指记录日期，不一定指当前仓库 HEAD。公开现状以[路线图](roadmap.zh-CN.md)为准；带日期文件应作为历史证据保留，不应静默改写其中的测量结果。

## 语言约定

- 英文使用无后缀主文件，由 GitHub 默认展示。
- 简体中文使用 `.zh-CN.md`。
- 繁体中文使用 `.zh-TW.md`。
- 每份公开文档首部提供三个语言版本的互链。
- 三种翻译中的版本号、日期、标识符、哈希、命令和证据边界必须等价。

`product.html` 特意保留为一个文件，内置英文、简体中文和繁体中文切换。

## 源码同步不等于发行

2026-08-28 的授权允许通过 SSH 将源码同步到 `git@github.com:gcsagroup/aegis-browser.git`，但不授权 tag、GitHub Release、二进制、安装包、签名或公证操作、Play 上传或生产部署。
