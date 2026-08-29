[English](./README.md) | [**简体中文**](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser 是把隐私与安全能力直接集成到浏览器层和引擎层的 Chromium fork。它不是 Electron 壳，也不把扩展当成产品本体。

策略逻辑以 `packages/core` 为来源，通过生成的规则快照、内嵌 policy worker、Chromium browser service 以及 Blink/V8 接入点落地。

## 当前状态

- 当前整合源码列出 **67 个顶层 Chromium 补丁**，另有 **2 个嵌套 V8 补丁**。
- 此前的 57 补丁诊断清单和 65 补丁 Agent 验收保留为历史快照，均不绑定当前 67 补丁 HEAD，也不能给它授予资格。
- 仍需重新完成当前整合源码的精确重放、身份绑定构建、受影响运行验收和发布门禁。当前没有正式产品签名、公证、打包、安装验收或已发布的桌面发行版。
- Android **尚未从当前源码构建**，当前没有可映射到源码的 APK 或 AAB。

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
```

常用输出目录：

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`：component 开发输出。
- `$CHROMIUM_ROOT/src/out/AegisRelease`：non-component Release build-tree 输入。
- `apps/browser/dist`：仅在身份和发布门通过后生成的打包输出。

构建成功不会自动把产物升级为 RC 或发行版。

## 补丁与 Overlay 模型

`overlay/` 保存期望的 Aegis 集成源码。它既不是独立产品，也不是已应用源码的唯一事实来源。改动必须导出到有序补丁序列，并在精确固定的 Chromium 基线上重新重放。

当前源码口径：

- 列入 Chromium 序列的 67 个顶层补丁。
- 2 个应用在嵌套 V8 checkout 中的补丁。
- 历史身份只覆盖此前的 57 补丁和 65 补丁快照，均不覆盖 0066–0067。
- 当前 67 补丁 HEAD 必须重新完成精确重放和构建身份绑定，才能形成当前资格结论。

“已列入 series”只表示补丁文件存在，不证明重放、可复现构建、平台验收、签名、打包或发布已经完成。

## 产品边界

当前桌面源码包括：

- tracker、链接、Cookie、bounce 和钓鱼防护；
- 针对部分 Canvas、Audio、WebGL、WebGPU 表面的 Blink 指纹扰动；
- 原生 HTTP(S)、Metalink、Torrent 和 Magnet 下载；
- 本地启发式摘要，以及用户配置的 OpenAI、Claude（Anthropic）或 Gemini 兼容 API；
- 浏览器掌控的 Agent：包含 Observe/Ask/Act 模式、有范围约束的书签/URL/页面/下载/工作流/监控工具、精确审批、审计历史、取消，以及最终购买前的强制用户接管；
- 仅观察的 MinerGuard 信号；以及
- 默认关闭、需显式启用的 V8 bytecode-shadow 研究路径。

必须保留以下边界：

- MinerGuard 只观察和报告，不会停止脚本、Worker 或网络连接。
- 指纹扰动只降低部分稳定表面，不能让浏览器“不可识别”。
- 远程摘要需用户确认并先在 browser 侧脱敏。允许 HTTPS；明文 HTTP 仅允许数值 loopback 地址。
- API Key 可选，通过操作系统加密保存在当前浏览器配置中，不回显明文。
- Android handler 目前无法取得普通网页 tab，因此 Android 页面摘要不可用。

下载功能位于 Chromium 原生 `chrome://downloads` 和 `chrome://settings/downloads`。视频提取、媒体转换、FFmpeg 和预装下载扩展不属于产品范围。

## 发布边界

桌面发布前，同一候选必须完成：

1. 从固定基线干净重放；
2. 清单绑定根仓库 commit、Chromium commit、两套补丁序列、GN 参数和产物哈希；
3. 受影响的原生、脚本和运行测试通过；
4. 产品身份、签名、公证与打包；
5. 代表系统上的全新安装和升级验收；以及
6. 明确的发布决定。

当前本地 diagnostic build-tree 已覆盖 0055/0056/0057，但不满足上述条件。完整补丁覆盖不会使其成为 RC 或发行版。
本地 RC 已满足其中的干净重放、身份和受影响测试要求，但尚未满足产品身份、受信任签名、公证、已安装分发包或发行授权门禁。

## Android

Android 与桌面共享固定 Chromium 基线，但当前源码尚未产出合格 Android 构建。Android client 需要受支持的 x86-64 Linux 环境；macOS 和 Windows 不能作为 Chromium Android 构建主机。

参见 [Android 构建与验收状态](./docs/android.zh-CN.md) 和 [Play Store 准备草案](./docs/play-store.zh-CN.md)。以下只是未来构建入口，不是 APK 已存在的证据：

```bash
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## 网络边界

本地检查、补丁重放和多数仓库测试不需要 GitHub。Bootstrap、fetch、sync、EasyList 更新和缺失的 Chromium 依赖可能访问外部服务；运行中的 Chromium 也可能产生与 Git 操作无关的网络流量。

使用网络、签名、打包或发布凭据前，必须再次确认精确命令和候选身份。
