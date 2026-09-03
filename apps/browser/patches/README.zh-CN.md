[English](./README.md) | [**简体中文**](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# 补丁

本目录中的补丁应用于本地 checkout 内固定的 Chromium 提交（`../CHROMIUM_COMMIT`）之上。

## 约定

1. 文件命名为 `0001-short-title.patch`、`0002-...`
2. 按应用顺序列入 `series`
3. 优先采用小型、易审查的差异，通过 `aegis/` 集成层接入，避免大范围改写 Blink
4. 不要把完整 Chromium 源码树放进本 Git 仓库

## 当前本地补丁序列

状态“series 中”只表示补丁文件列在当前本地 `series`；不表示已经进入上游 Chromium、通过发行门禁或可以发布。49 补丁和 67 补丁记录只保留为历史快照。当前整合源码包含 **92 个 Chromium 补丁 + 2 个嵌套 V8 补丁**：0057–0065 是原 Browser Agent 集成，0066–0067 是设置/更新和视觉品牌，0068–0092 用 Browser Agent v2 Runtime 替换并强化 v1 执行路径，同时加入跨平台入口、定时自动化、指定站点路由、Profile 隔离和有界恢复。2026-09-03 已确认补丁 0079–0092 可在先前验证的 78 补丁源码上通过隔离 Git 索引精确重放；结果是 Chromium 源码提交 `583cd38ab586ee30e948f0599bb79537dc1632e1`（tree `aecbebf54c228f181608f6647d401b9e3fb40212`）。产物资格仍按平台分别判定，并且必须绑定这份精确源码的验收证据。

| ID | 目的 | 状态 |
|----|------|------|
| 0001 | 增加 `chrome/browser/aegis/` 桩代码与 feature flag | series 中 |
| 0002 | 接入网络节流与 tracker host 请求取消 | series 中 |
| 0003 | 嵌入 `chrome://aegis` WebUI 设置界面 | series 中 |
| 0004 | 通过导航节流增加钓鱼拦截页 | series 中 |
| 0005 | 增加 Canvas、Audio 与 WebGL 的 FingerprintGuard 扰动接入点 | series 中 |
| 0006 | 将 `packages/core` 策略快照打包为 C++ `.inc` 与 JSON | series 中 |
| 0007 | 增加 EasyList 编译器与运行时过滤列表更新器 | series 中 |
| 0008 | 去除追踪查询参数并增加 Cookie 清理器 | series 中 |
| 0009 | 揭示 CNAME 并清除跳转追踪 Cookie | series 中 |
| 0010 | 增加钓鱼 URL 启发式与可解释拦截页 | series 中 |
| 0011 | 增加面向密码表单与紧迫文案的钓鱼页面感知 | series 中 |
| 0012 | 通过 gin 增加 JavaScript 策略 worker 与 Privacy AI/Ollama sidecar | series 中 |
| 0013 | 扰动 WebGPU `adapter.info` | series 中 |
| 0014 | 修复启动 DCHECK；策略 worker 改在 `chrome://aegis` 运行 | series 中 |
| 0015 | 在设置和菜单中增加 `chrome://aegis` 入口 | series 中 |
| 0016 | 增加模块说明文案与 Ollama 模型设置 | series 中 |
| 0017 | 启动后推迟过滤列表和 Cookie 清扫 | series 中 |
| 0018 | EasyList 启动时使用本地 `compiled.json` 缓存 | series 中 |
| 0019 | 更新 EasyList 缓存：24 小时检查、HTTP 304 处理与失败退避 | series 中 |
| 0020 | 增加易懂的拦截页文案、摘要与会话清理清单 | series 中 |
| 0021 | 增加 Cookie 精确名单与第一方收集路径拦截 | series 中 |
| 0022 | 增加会话清单实时刷新、Canvas 自检与 GA4 收集假象 | series 中 |
| 0023 | 让拦截可见、去除 Referer 参数、标注 Cookie，并增加本机 CDP/AI 控制 | series 中 |
| 0024 | 从远程 CDP 目标列表隐藏内部页，并在会话清单显示 Agent 连接 | series 中 |
| 0025 | 本机 CDP 连接时显示浏览器横幅，并增加打开 `chrome://aegis` 的按钮 | series 中 |
| 0026 | 在 `chrome://aegis` 一次检测 Canvas、WebGL、Audio 与 WebGPU | series 中 |
| 0027 | Audio 指纹按站点只扰动一次，并覆盖 `copyFromChannel` | series 中 |
| 0028 | 按站点稳定化 WebGPU limits 与 subgroup 数值 | series 中 |
| 0029 | Android 包含 `chrome://aegis`，并为 Play 预留显示名和包身份 | series 中 |
| 0030 | Android 设置打开 `chrome://aegis`，并在移动端禁用 CDP/Ollama | series 中 |
| 0031 | 强化摘要/Ollama、钓鱼与本机 CDP 安全边界及回归测试 | series 中 |
| 0032 | 保存远程 CDP 生产接线与安全测试检查点 | series 中 |
| 0033 | 统一远程 CDP 来源传播、目标授权与敏感协议拦截 | series 中 |
| 0034 | 跨 hash 导航保持初始空白文档所有权语义 | series 中 |
| 0035 | 修复 Aegis WebUI TypeScript lint | series 中 |
| 0036 | 修复 CDP 浏览器测试通知 matcher 类型 | series 中 |
| 0037 | 稳定 Aegis 浏览器单测构建与阈值断言 | series 中 |
| 0038 | 远程创建目标时保留并单次授权初始文档 | series 中 |
| 0039 | 捕获 Ollama 最终 HTTP 请求体，并验证原始 PII 不外发 | series 中 |
| 0040 | Profile 销毁前释放 Aegis 组件、回调与原始指针 | series 中 |
| 0041 | 在生产路径禁用 Google AIM eligibility 服务端请求，同时为测试 factory 保留正向门 | series 中 |
| 0042 | 普通未注册 Profile 不创建 policy FM/GCM listener，企业注册后单次启动 | series 中 |
| 0043 | 将 Aegis 阻拦、CNAME、Referer 与参数事件切回 Remote 所属序列，并保护退出生命周期 | series 中 |
| 0044 | 按域名索引 path rule、缩短列表替换临界区，并去掉 Canvas 扰动的整图双拷贝 | series 中 |
| 0045 | 增加结构化页面保护事件、站点聚合、隐私裁剪与临时站点暂停 | series 中 |
| 0046 | 增加浏览器原生盾牌入口、当前站点气泡与一次性感知引导 | series 中 |
| 0047 | 增加保护概览、摘要前确认、钓鱼线索优先解释与事件驱动状态 | series 中 |
| 0048 | 将摘要来源限制在设置页同一窗口，并拒绝跨窗口/Profile 标签 | series 中 |
| 0049 | 增加有界钓鱼页面采集、品牌仿冒/路径/短链信号与本地多源 SHA-256 威胁索引 | series 中 |
| 0050 | 集成多连接加速下载与 BT 下载 | series 中 |
| 0051 | 增加原生下载设置及安全默认值 | series 中 |
| 0052 | 强化 Canvas、OffscreenCanvas、Audio、WebGL 与 WebGPU 反指纹 | series 中 |
| 0053 | 增加仅观察、不阻断的 MinerGuard | series 中 |
| 0054 | 增加默认关闭的 V8 bytecode shadow 观察能力 | series 中 |
| 0055 | 支持可编辑地址的 OpenAI、Claude（Anthropic）与 Gemini 兼容 API、模型列表及按地址隔离凭据 | series 中 |
| 0056 | 在当前站点保护气泡中原位完成 AI 摘要确认与结果展示，并以精确文档会话完善 API 请求生命周期 | series 中 |
| 0057 | 固定 Agent 使用的 V8 bytecode shadow 观察提交 | series 中 |
| 0058 | 增加任务合同、状态机、策略代理、模型协议、任务存储与固定工具注册表 | series 中 |
| 0059 | 将 Aegis 精确范围、文档绑定与任务生命周期接入 Actor 执行层 | series 中 |
| 0060 | 增加原生侧栏、菜单、快捷键、设置入口和桌面 Browser/UI 测试 | series 中 |
| 0061 | 修复固定区间安全审计发现，并完成资源打包、真实快捷键和桌面集成加固 | series 中 |
| 0062 | 默认显示 Browser Agent 入口并补充回归测试 | series 中 |
| 0063 | 为既有 Profile 迁移 Agent 工具栏入口 | series 中 |
| 0064 | 明确侧栏就绪信号并修复入口状态 | series 中 |
| 0065 | 自动打开任务页面并支持空白标签任务 | series 中 |
| 0066 | GCSA 设置去除上游 AI/Google 入口、恢复搜索引擎管理，并重做关于页与更新状态 | series 中 |
| 0067 | 接入 GCSA Logo 与跨平台 App 图标，同时保留 Chromium 内部身份和用户数据目录 | series 中 |
| 0068 | 增加 Browser Agent v2 原生混合 Runtime 原型 | series 中 |
| 0069 | 强化 v2 自主 Runtime 与策略边界 | series 中 |
| 0070 | 简化 Browser Agent v2 新手引导和任务入口 | series 中 |
| 0071 | 强化模型规划与执行流程 | series 中 |
| 0072 | 浏览前先由模型理解用户目标 | series 中 |
| 0073 | 强制使用浏览器原生工具并确定性路由指定站点 | series 中 |
| 0074 | 将隐含的当前页面任务绑定到活动文档 | series 中 |
| 0075 | 增加常用任务按钮和定时自动化 | series 中 |
| 0076 | 修正跨平台构建接线与品牌资源 | series 中 |
| 0077 | 完成跨平台 Browser Agent v2 Runtime 与入口 | series 中 |
| 0078 | 模型格式有界失败后恢复安全的只读计划 | series 中 |
| 0079 | 隔离主无痕 Profile，并收紧 Guest、CDP、NetLog、Actor、CNAME、Advanced 与 Torrent 生命周期 | series 中 |
| 0080 | 强化本地 Qwen 的当前页计划 | series 中 |
| 0081 | 执行前验证模型计划顺序 | series 中 |
| 0082 | 拒绝浏览器打开目标后的重复入口导航 | series 中 |
| 0083 | 降低本地 Qwen 原生工具轮次延迟 | series 中 |
| 0084 | 要求定时自动化由浏览器持久保存 | series 中 |
| 0085 | 对证据绑定的执行轮次做一次不扩权修复 | series 中 |
| 0086 | 阻止模型路由到非公开 URL | series 中 |
| 0087 | Agent 工作区使用产品 Logo | series 中 |
| 0088 | 加入品牌化 Android Agent 入口和任务编辑器 | series 中 |
| 0089 | 从较弱模型路由中恢复指定站点搜索 | series 中 |
| 0090 | 收藏夹等浏览器数据任务保持使用原生工具 | series 中 |
| 0091 | 丢弃 browser-only 路由中无害的冗余目标而不误报失败 | series 中 |
| 0092 | 校验收藏夹目标语义、修复漏步计划，并确保仅预览任务保持只读 | series 中 |
| 0079 | 支持隔离的主无痕 Aegis/Agent/Actor/UI；Guest/System/辅助 OTR fail closed；锁止桌面/Android 远程 CDP；脱敏默认 NetLog API key 请求头和 Actor 私密诊断；按 Profile 隔离 CNAME 与 Advanced/Torrent 所有权并在关闭时取消 | series 中 |

在干净、固定版本的 checkout 上运行 `pnpm --filter @gcsa-aegis/browser apply-patches` 进行应用。任何 series 变化都必须重新完成离线重放、冷构建、增量构建和受影响测试。
