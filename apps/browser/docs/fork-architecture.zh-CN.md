[English](./fork-architecture.md) | [**简体中文**](./fork-architecture.zh-CN.md) | [繁體中文](./fork-architecture.zh-TW.md)

# Chromium fork 架构

GCSA-aegis 是 Chromium fork。浏览器、网络、存储、Blink 和部分 V8 接入点共同构成产品；没有独立 Extension 或 Electron 发行物。

## 状态边界

- 当前源码：**56 个顶层 Chromium 补丁 + 2 个嵌套 V8 补丁**。
- 现有 Release 身份：**54 个 Chromium 补丁 + 2 个 V8 补丁**。
- Chromium `0055`、`0056` 尚未被当前已提交的 Release 清单覆盖。
- 现有 non-component Release build-tree 只是本地证据，不是已签名、公证、安装或发布的发行版。
- Android 尚未从当前源码构建。

## 产品形态

```text
┌──────────────────────────────────────────────┐
│ GCSA-aegis Chromium fork                     │
│                                              │
│ Browser UI / chrome://aegis / 原生页面       │
│                    │                         │
│                    ▼                         │
│ Aegis browser service 与策略桥接             │
│   ├─ 导航与网络控制                          │
│   ├─ Cookie、bounce 与钓鱼防护               │
│   ├─ 下载与摘要编排                          │
│   └─ 本地事件与偏好设置                      │
│                    │                         │
│                    ▼                         │
│ Blink 防护 + 可选 V8 研究路径                │
└──────────────────────────────────────────────┘
```

## 架构原则

1. 策略模型和生成输入以 `packages/core` 为来源。
2. 必须由浏览器或引擎持有的执行能力放在 Chromium C++ 和 Blink。
3. 生成快照与内嵌 policy worker 把 TypeScript 策略接入 fork。
4. 用户设置位于 `chrome://aegis`、`chrome://downloads`、`chrome://settings/downloads` 等原生 Chromium 页面。
5. 本地证据、构建成功和可分发发行版是三种不同状态。

## 集成映射

| 能力 | 主要接入点 | 当前边界 |
|---|---|---|
| 网络与导航 | URL loader 与导航 throttle | 需要新鲜重放和代表性浏览器回归 |
| 存储保护 | Cookie 与 bounce hook | 必须保留预期的第一方登录行为 |
| 钓鱼防护 | URL/页面信号和原生 interstitial | 本地检测不能证明通用覆盖 |
| 指纹保护 | Blink Canvas、Audio、WebGL、WebGPU hook | 降低部分稳定表面，不阻止全部指纹识别 |
| 下载 | Chromium 下载 UI 与隔离 torrent service | HTTPS tracker 与发布资格仍受门禁约束 |
| 页面摘要 | 启发式路径和用户配置的兼容 API | 远程使用需脱敏与确认；Android 页面采集不可用 |
| MinerGuard | Browser/renderer 信号与报告 | 仅观察，不阻断执行或流量 |
| Bytecode shadow | 默认关闭的嵌套 V8 插桩 | 仅研究；现有身份覆盖 2 个 V8 补丁，但不覆盖最新 Chromium 0055/0056 |
| 本地自动化 | Loopback CDP 控制和文档授权 | 部分桌面路径有本地证据；签名安装与 Android 证据独立 |

## 补丁交付模型

`apps/browser/patches/series` 排列 56 个 Chromium 补丁，`apps/browser/patches/v8/series` 排列应用在嵌套 V8 checkout 中的 2 个补丁。重放脚本会先验证两套基线。

`overlay/` 保存供开发和审查使用的期望集成源码。它不会独立应用，也不能替代补丁序列。源码改动必须导出为有序补丁，在固定基线上重放、构建并测试。

最新源码与最新合格 Release 身份必须分开描述：

- Chromium 0001–0054 和 V8 0001–0002 已有绑定身份的 Release 证据。
- Chromium 0055 增加兼容模型 API 和凭据隔离。
- Chromium 0056 增加精确文档绑定的站点摘要流程。
- 0055/0056 仍需新的已提交仓库身份和完整 Release 证据链。

“列入 series”只证明顺序和文件存在，不证明干净重放、构建新鲜度、签名、打包、安装验收、Android 支持或发布批准。

## 摘要与凭据边界

桌面用户可选择 OpenAI、Claude（Anthropic）或 Gemini 兼容格式并填写明确服务地址。允许 HTTPS；明文 HTTP 仅限数值 loopback 地址。API Key 可选，通过操作系统加密保存在当前 Profile 中。

远程摘要前，浏览器会生成脱敏载荷、做第二次校验，并在确认界面显示目标格式、模型和目的地址。敏感页面和含密码字段的页面只能使用本地启发式路径。Android 当前无法为此流程取得普通页面 tab。

## 下载边界

HTTP(S) 下载仍由 Chromium `DownloadItem` 执行。Metalink、Torrent 和 Magnet 任务接入原生下载页面，torrent 工作由隔离 service 承担。全局连接设置和新任务默认值位于 `chrome://settings/downloads`。

视频提取、媒体转换、FFmpeg 和预装下载扩展不属于该架构。

## 平台与发布边界

non-component macOS Release build-tree 是发布资格的输入，不是发布结果。正式发布还需同一当前 commit 和两套补丁序列的清单、受影响的原生与运行测试、产品身份、签名、公证、打包和安装验收。

Android 接线存在于源码中，但当前没有由当前源码产生的 APK 或 AAB。受支持的 x86-64 Linux 构建、真机验收、Android 页面摘要行为和 Play 合规仍是开放门禁。

## 开发内部参考

以下文档刻意不翻译：

- [Overlay 同步规则](./overlay.md)
- [Chromium 目录布局](./tree-layout.md)
- [补丁维护说明](../patches/README.md)

公开配套文档：

- [Browser README](../README.zh-CN.md)
- [Android 状态](./android.zh-CN.md)
- [Play Store 准备情况](./play-store.zh-CN.md)

## 为什么不是 Electron

Electron 无法持有该设计所使用的全部 Chromium 网络、CookieMonster、Blink 和 V8 表面。因此项目在 Chromium 浏览器层和引擎层集成，并把所有发布声明置于明确证据门禁之后。
