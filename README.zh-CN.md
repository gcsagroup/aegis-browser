# GCSA-aegis

[English](README.md) | **简体中文** | [繁體中文](README.zh-TW.md)

GCSA-aegis 是一个本地优先的隐私安全浏览器，产品形态为 Chromium fork。隐私、反钓鱼、反跟踪、下载和可选 AI 能力直接集成在浏览器内，不以 Electron 套壳或独立扩展作为产品。

> **状态 — 2026-08-28：**当前源码已同步到 56 个顶层 Chromium 补丁，另含 2 个嵌套 V8 补丁。最新带身份清单的本地 build-tree 产物只绑定 54 个顶层补丁及这 2 个 V8 补丁；0055、0056 尚未被该产物证据覆盖。项目整体仍为**发行 No-Go**：没有受信任构建证明、正式产品签名和公证的 macOS 安装包、安装 App 验收，也没有当前源码的 Android 包。

## 产品形态

- **唯一产品：**[`apps/browser`](apps/browser/README.zh-CN.md) 下的 Chromium fork。
- **策略来源：**[`packages/core`](packages/core) 提供可测试的策略、检测器和浏览器生成资产。
- **浏览器集成：**网络、存储、指纹、钓鱼、下载、WebUI 和本地自动化控制均接入 Chromium。
- **隐私 AI：**桌面端支持本机启发式，以及用户配置的 OpenAI、Claude（Anthropic）或 Gemini 兼容 API。远程使用必须明确目标并确认；这不等于已经完成“无遥测”证明。

## 证据边界

源码同步和干净的 Chromium checkout 证明补丁栈可重放，但不证明当前源码已经通过全部构建、运行、签名、安装、Android、隐私和发行门禁。

最新带身份绑定的 build-tree 证据仅限本机，资格为 `diagnostic-only`。历史测试数量和产物哈希保留在带日期的审计记录中；不同补丁 HEAD 的结果不能相加，也不能写成当前发行证据。

## 快速开始

JavaScript 工具链固定为 Node.js `24.14.0` 和 pnpm `9.15.0`。

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

准备和构建 Chromium 需要大型外部 checkout。运行网络、构建、打包或运行时命令前，请先阅读 [Browser 指南](apps/browser/README.zh-CN.md)。

## 仓库结构

```text
apps/browser       Chromium 钉扎、overlay、补丁、构建与验证脚本
packages/core      策略、检测器、生成器与研究性质评测代码
docs/              架构、路线图、研究映射、产品页与审计记录
```

## 文档

- [文档索引](docs/README.zh-CN.md)
- [架构](docs/architecture.zh-CN.md)
- [路线图与发行门禁](docs/roadmap.zh-CN.md)
- [研究与实现映射](docs/research-map.zh-CN.md)
- [三语产品页](docs/product.html)
- [变更日志](CHANGELOG.zh-CN.md)

## GitHub 同步边界

2026-08-28 已授权通过 SSH 将源码仓库同步到 `git@github.com:gcsagroup/aegis-browser.git`。该授权只覆盖源码分支同步，**不**授权创建或发布 Git tag、GitHub Release、二进制、安装包、签名凭据、公证提交、Play 上传或生产部署。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。

## 测试

```bash
pnpm run quality:fast
```

该命令覆盖仓库的快速 JavaScript 和脚本门禁。Chromium 原生构建、浏览器测试、运行矩阵、签名、安装 App 检查和 Android 实机验收是独立门禁。
