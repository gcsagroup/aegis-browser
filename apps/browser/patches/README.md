# Patches

Patches in this directory are applied on top of the pinned Chromium commit
(`../CHROMIUM_COMMIT`) inside the local checkout.

## Conventions

1. Name files `0001-short-title.patch`, `0002-...`
2. List them in `series` in apply order
3. Prefer small, reviewable diffs that call into `aegis/` glue rather than rewriting Blink wholesale
4. Never vendor the full Chromium tree in this git repo

## Current local patch series

状态“series 中”只表示补丁文件列在当前本地 `series`；不表示已经进入上游 Chromium、通过 Release/Android 门或可发布。2026-08-25 历史验收快照：当时 49 个补丁与 checkout 原始 commit 身份、稳定 patch-id 和全部 117 个 overlay 文件一致；HEAD 为 `cf0f5f3bfbb289520dcc6e9a39f648d5da115f46`，tree 为 `154474478108dbfd4fe5c810d1e2077e4249326b`，`series` SHA-256 为 `43db8760d13a9dc2d7ee24fd13167bcc6e7d446f317899103083d22b70c456b3`。桌面产物是否匹配必须以同次 `browser:status` 的新鲜度门为准；每次 series 变化后都要重新验证。

| ID | Intent | Status |
|----|--------|--------|
| 0001 | Add `chrome/browser/aegis/` stub + feature flag | series 中 |
| 0002 | Wire network throttle / request cancel for tracker hosts | series 中 |
| 0003 | Embed `chrome://aegis` WebUI settings surface | series 中 |
| 0004 | Phish interstitial via navigation throttle | series 中 |
| 0005 | FingerprintGuard farbling hooks (canvas/audio/WebGL) | series 中 |
| 0006 | Bundle `packages/core` policy snapshot → C++ `.inc` + JSON | series 中 |
| 0007 | EasyList compiler + runtime filter-list updater | series 中 |
| 0008 | Strip tracking query params + cookie janitor | series 中 |
| 0009 | CNAME uncloak + bounce-tracker cookie clearing | series 中 |
| 0010 | Phish URL heuristics + explainable interstitial | series 中 |
| 0011 | Phish page-sense (password forms + urgency copy) | series 中 |
| 0012 | JS policy worker (gin) + Privacy AI / Ollama sidecar | series 中 |
| 0013 | WebGPU adapter.info farbling | series 中 |
| 0014 | 启动 DCHECK 修复；策略 worker 改在 chrome://aegis 运行 | series 中 |
| 0015 | 设置 / 菜单增加 chrome://aegis 入口 | series 中 |
| 0016 | 模块说明文案 + Ollama 模型设置 | series 中 |
| 0017 | 启动后推迟过滤列表/Cookie 清扫 | series 中 |
| 0018 | EasyList 启动走本地 compiled.json 缓存 | series 中 |
| 0019 | EasyList 缓存更新：24h 检查 / 304 / 失败退避 | series 中 |
| 0020 | 拦截页人话、摘要与会话清理清单 | series 中 |
| 0021 | Cookie 精确名单 + 第一方收集路径拦截 | series 中 |
| 0022 | 会话清单实时刷新、Canvas 自检、GA4 收集假象 | series 中 |
| 0023 | 拦截可见、Referer 去参、Cookie 标注、本机 CDP/AI 控制 | series 中 |
| 0024 | 远程 CDP 目标列表隐藏内部页，会话清单显示 agent 连接 | series 中 |
| 0025 | 本机 CDP 连接显示浏览器横幅，按钮打开 chrome://aegis | series 中 |
| 0026 | chrome://aegis 一次检测 Canvas / WebGL / Audio / WebGPU | series 中 |
| 0027 | Audio 指纹按站点只扰动一次；copyFromChannel 同样生效 | series 中 |
| 0028 | WebGPU limits / subgroup 数值按站点稳定化 | series 中 |
| 0029 | Android：chrome://aegis 可进包，显示名/包名预留 Play | series 中 |
| 0030 | Android 设置打开 chrome://aegis；手机上关掉 CDP/Ollama | series 中 |
| 0031 | 强化摘要/Ollama、钓鱼与 CDP 本地安全边界及回归测试 | series 中 |
| 0032 | 保存远程 CDP 生产接线与安全测试检查点 | series 中 |
| 0033 | 统一远程 CDP 来源传播、目标授权与敏感协议拦截 | series 中 |
| 0034 | 跨 hash 导航保持初始空白文档所有权语义 | series 中 |
| 0035 | 修复 Aegis WebUI TypeScript lint | series 中 |
| 0036 | 修复 CDP 浏览器测试通知 matcher 类型 | series 中 |
| 0037 | 稳定 Aegis 浏览器单测构建与阈值断言 | series 中 |
| 0038 | 远程创建目标时保留并单次授权初始文档 | series 中 |
| 0039 | 捕获 Ollama 最终 HTTP 请求体并验证原始 PII 不外发 | series 中 |
| 0040 | Profile 销毁前释放 Aegis 组件、回调与原始指针 | series 中 |
| 0041 | 生产路径禁用 Google AIM eligibility 服务端请求，测试 factory 保留正向门 | series 中 |
| 0042 | 普通未注册 Profile 不创建 policy FM/GCM listener，企业注册后单次启动 | series 中 |
| 0043 | 将 Aegis 阻拦、CNAME、Referer 与参数事件切回 Remote 所属序列并保护退出生命周期 | series 中 |
| 0044 | 按域名索引 path rule、缩短列表替换临界区，并去掉 Canvas farbling 整图双拷贝 | series 中 |
| 0045 | 结构化页面保护事件、站点聚合、隐私裁剪与临时站点暂停 | series 中 |
| 0046 | 浏览器原生盾牌入口、当前站点气泡与一次性感知引导 | series 中 |
| 0047 | 保护概览、摘要前确认、钓鱼线索优先解释与事件驱动状态 | series 中 |
| 0048 | 摘要来源限制在设置页同一窗口，并拒绝跨窗口/Profile 标签 | series 中 |
| 0049 | 有界钓鱼页面采集、品牌仿冒/路径/短链信号与本地多源 SHA-256 威胁索引 | series 中 |
| 0050 | 集成多连接加速下载与 BT 下载 | series 中 |
| 0051 | 增加原生下载设置及安全默认值 | series 中 |
| 0052 | 强化 Canvas、OffscreenCanvas、Audio、WebGL 与 WebGPU 反指纹 | series 中 |
| 0053 | 增加仅观察、不阻断的 MinerGuard | series 中 |
| 0054 | 增加默认关闭的 V8 bytecode shadow 观察能力 | series 中 |
| 0055 | 支持可编辑地址的 OpenAI／Claude（Anthropic）／Gemini 兼容 API、模型列表与按地址隔离凭据 | series 中 |
| 0056 | 当前站点保护弹窗原位完成 AI 摘要确认与结果展示，并以精确文档会话完善兼容 API 请求生命周期 | series 中 |

Apply with `pnpm --filter @gcsa-aegis/browser apply-patches` on a clean pinned checkout. 任何 series 变化都必须重新做离线重放、冷/增量构建和受影响测试。
