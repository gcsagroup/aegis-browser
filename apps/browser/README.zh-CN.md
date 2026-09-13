[English](./README.md) | [**简体中文**](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser 是把隐私与安全能力直接集成到浏览器层和引擎层的 Chromium fork。它不是 Electron 壳，也不把扩展当成产品本体。

策略逻辑以 `packages/core` 为来源，通过生成的规则快照、内嵌 policy worker、Chromium browser service 以及 Blink/V8 接入点落地。

## 当前状态

- 当前源码已合并到 `main`。108个Chromium补丁从固定基线完整重放后得到源码树 `319366182c31108e29e62d2f2199aff29a0b86e8`；[9月10日合并记录](../../docs/audit/main-consolidation-2026-09-10.md)分别列出源码验证与尚未完成的平台验收。

- Browser Agent v2 候选源码列出 **108 个顶层 Chromium 补丁**和 **2 个嵌套 V8 补丁**。补丁 0079–0095 精确重放到 `c930fa41ef7e9522f145848f3080ee0cc1edc4d8`；补丁 0096 重放到 `f8dff6e3a5dd02527c093b57cde78fc4b0dcb34f`；补丁 0097 生成 `a3040bb0dea05e87c2a141b9a29a237a96953620`；补丁 0098 生成 `911f5c45acf3de10741008cf8f40948d57d31b7a`；补丁 0099 生成 `54f2d8dcf03ecf53b074b4919769ea652fdf5ab5`（tree `915676bbfbd340b8b8feb15aecacc70dfd53861b`）；补丁 0100 生成 `44b79c59cf594b83af5c181842a57c2604d209ed`（tree `b8285fda53d21dff5ee56c39be1455ad3e5c3c82`）；补丁 0101 生成 `1c63ce994b2815fe1f3dc07608ff121d987e0441`（tree `451b3148d12fc2cff2df293cb0f1bb0d6242a908`）；补丁 0102 生成已提交源码 `13807aaf086948bdff0370e356718d0c2ac54d27`（tree `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`）。
- 57、65、67、95 和 97 补丁记录保留为历史快照，不能给 108 补丁产物授予资格。
- macOS 原生与浏览器测试已在候选源码上通过；仍需精确平台清单和最终 UI 验收。当前没有正式产品签名、公证、安装或已发布的桌面发行版。
- Android 和 Windows 候选正在验证；完成真机/主机记录前，不接受任何 APK、AAB 或 Windows 安装包。

因此，仓库目前没有可发布的桌面或 Android 产物。

## Chromium 固定基线

| 文件 | 含义 |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | 固定的 Mac Stable 版本，当前为 `151.0.7922.77` |
| [CHROMIUM_COMMIT](./CHROMIUM_COMMIT) | 补丁所基于的精确 Chromium commit |

该版本是固定快照，不会自动跟随更新的 Stable 版本。

## 文档

- [Fork 架构](./docs/fork-architecture.zh-CN.md)
- [Android 构建与验收状态](./docs/android.zh-CN.md)
- [Play Store 准备草案](./docs/play-store.zh-CN.md)

- [Overlay 同步规则](./docs/overlay.zh-CN.md)
- [Chromium 目录布局](./docs/tree-layout.zh-CN.md)
- [补丁维护说明](./patches/README.zh-CN.md)

实际操作以 `patches/series`、`patches/v8/series` 和 `scripts/` 下的脚本为准。历史状态记录不能替代当前重放、构建或运行验证。

## 仓库布局

```text
apps/browser/
  args/                 GN 配置
  overlay/              期望的集成源码
  patches/series        有序 Chromium 补丁列表
  patches/v8/series     有序嵌套 V8 补丁列表
  scripts/              拉取、重放、构建、运行、验证和打包工具
  docs/                 公开与开发文档
```

Chromium 源码放在本仓库之外。典型本地配置为：

```bash
export REPO_ROOT="$HOME/Projects/GCSA-aegis"
export CHROMIUM_ROOT="$HOME/Projects/GCSA-aegis-chromium"
```

也可把 Chromium 根目录写入已被 Git 忽略的 `apps/browser/.chromium-root`。

## 本地流程

以下命令从仓库根目录执行。Bootstrap、fetch、sync 和依赖下载会访问网络。

```bash
# 准备 depot_tools。
pnpm --filter @gcsa-aegis/browser bootstrap

# 拉取固定 Chromium 源码，需要数十 GB 空间。
pnpm --filter @gcsa-aegis/browser fetch

# 按顺序重放 Chromium 和嵌套 V8 补丁。
pnpm --filter @gcsa-aegis/browser apply-patches

# 准备用于本地 BT 构建的固定 libtorrent 源码。
pnpm --filter @gcsa-aegis/browser bootstrap:libtorrent

# 构建并运行 component 开发版。
pnpm --filter @gcsa-aegis/browser build
pnpm --filter @gcsa-aegis/browser run

# 生成 non-component Release build-tree 输入。
pnpm --filter @gcsa-aegis/browser build:release
pnpm --filter @gcsa-aegis/browser run:release

# 检查 checkout、补丁、overlay 和输出状态。
pnpm --filter @gcsa-aegis/browser status

# 运行仓库和 Browser 脚本门禁。
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser test:scripts

# 可选：预检无密钥本地模型的 Agent 原生工具调用协议。
node apps/browser/scripts/verify-agent-local-model.mjs \
  --base-url http://127.0.0.1:8000/v1 --model MODEL --rounds 2
```

本地模型预检不会保存完整提示词或原始响应。它会重复检查模型发现、目标路由、计划和执行
调用，但不能替代在真实浏览器里的端到端运行。

Windows 界面验收使用共享的 [验收脚本](./scripts/windows-agent-ui-acceptance.ps1)，不要继续维护服务器上的独立副本。
运行前先执行 [脚本自测](./scripts/windows-agent-ui-acceptance_test.ps1)，传入 Windows Node 的 `-NodePath` 和全新的 `-EvidenceDir`；
该自测只验证启动参数与窗口辅助代码编译，不算界面通过。实际验收须在已解锁桌面运行，不能自动批准其他程序的防火墙弹窗。

常用输出目录：

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`：component 开发输出。
- `$CHROMIUM_ROOT/src/out/AegisRelease`：non-component Release build-tree 输入。
- `apps/browser/dist`：仅在身份和发布门通过后生成的打包输出。

构建成功不会自动把产物升级为 RC 或发行版。

## 补丁与 Overlay 模型

`overlay/` 保存期望的 Aegis 集成源码。它既不是独立产品，也不是已应用源码的唯一事实来源。改动必须导出到有序补丁序列，并在精确固定的 Chromium 基线上重新重放。

当前源码口径：

- 列入 Chromium 序列的 108 个顶层补丁。
- 2 个应用在嵌套 V8 checkout 中的补丁。
- 57、65、67、95 和 97 补丁身份属于历史记录，不覆盖当前 v2 候选。
- 补丁 0079–0095 已在先前验证的 78 补丁源码树上通过隔离索引精确重放；补丁 0096 独立生成精确的 96 补丁源码树；补丁 0097 生成精确的 97 补丁源码树；补丁 0098 生成精确的 98 补丁源码树 `7069e2b065466bbab3e3007e5866a3790e85ed47`；补丁 0099 生成精确的 99 补丁源码树 `915676bbfbd340b8b8feb15aecacc70dfd53861b`；补丁 0100 生成精确的 100 补丁源码树 `b8285fda53d21dff5ee56c39be1455ad3e5c3c82`；补丁 0101 生成精确的 101 补丁源码树 `451b3148d12fc2cff2df293cb0f1bb0d6242a908`；补丁 0102 生成精确的 102 补丁源码树 `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`。产物身份和运行资格仍按平台分别判定。

“已列入 series”只表示补丁文件存在，不证明重放、可复现构建、平台验收、签名、打包或发布已经完成。

## 产品边界

当前桌面源码包括：

- tracker、链接、Cookie、bounce 和钓鱼防护；
- 针对部分 Canvas、Audio、WebGL、WebGPU 表面的 Blink 指纹扰动；
- 原生 HTTP(S)、Metalink、Torrent 和 Magnet 下载；
- 本地启发式摘要，以及用户配置的 OpenAI、Claude（Anthropic）或 Gemini 兼容 API；
- Browser Agent v2：包含模型优先目标路由、可见计划、浏览器掌控的执行/观察/验证循环、常用任务按钮、定时自动化、有范围约束的书签/URL/页面/下载工具、精确审批，以及最终购买前的强制用户接管；
- 仅观察的 MinerGuard 信号；以及
- 默认关闭、需显式启用的 V8 bytecode-shadow 研究路径。

必须保留以下边界：

- MinerGuard 只观察和报告，不会停止脚本、Worker 或网络连接。
- 指纹扰动只降低部分稳定表面，不能让浏览器“不可识别”。
- 远程摘要需用户确认并先在 browser 侧脱敏。允许 HTTPS；明文 HTTP 仅允许数值 loopback 地址。
- API Key 可选，通过操作系统加密保存在当前浏览器配置中，不回显明文。
- v2 源码已实现 Android 页面采集和当前页面绑定；是否运行合格取决于当前 APK 的真机验收。

下载功能位于 Chromium 原生 `chrome://downloads` 和 `chrome://settings/downloads`。视频提取、媒体转换、FFmpeg 和预装下载扩展不属于产品范围。

## 发布边界

桌面发布前，同一候选必须完成：

1. 从固定基线干净重放；
2. 清单绑定根仓库 commit、Chromium commit、两套补丁序列、GN 参数和产物哈希；
3. 受影响的原生、脚本和运行测试通过；
4. 产品身份、签名、公证与打包；
5. 代表系统上的全新安装和升级验收；以及
6. 明确的发布决定。

108个Chromium补丁和2个V8补丁均通过从固定基线开始的完整隔离索引重放。最近的本地macOS候选已有527项原生测试结果；本次源码提交未重新构建或发布App、APK和Windows包。最终Qwen输出、安装产物验收、正式签名和公证仍是独立门槛。

## Android

Android 与桌面共享固定 Chromium 基线，并从干净的 x86-64 Linux checkout 构建。只有完成 APK 精确身份和真机运行记录后才可接受该构建；macOS 和 Windows 不能作为 Chromium Android 构建主机。

参见 [Android 构建与验收状态](./docs/android.zh-CN.md) 和 [Play Store 准备草案](./docs/play-store.zh-CN.md)。以下是构建入口，本身不构成验收证据：

```bash
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## 网络边界

本地检查、补丁重放和多数仓库测试不需要 GitHub。Bootstrap、fetch、sync、EasyList 更新和缺失的 Chromium 依赖可能访问外部服务；运行中的 Chromium 也可能产生与 Git 操作无关的网络流量。

使用网络、签名、打包或发布凭据前，必须再次确认精确命令和候选身份。

### 浏览器自身更新

“关于 GCSA Aegis”检查 GitHub 正式版本，自动下载匹配的安装包并校验，安装需手动完成。见[更新流程](../../docs/github-browser-updates.zh-CN.md)及[Ver 1.1 (018) 本地验收](../../docs/ui-copy-acceptance.zh-CN.md)。
