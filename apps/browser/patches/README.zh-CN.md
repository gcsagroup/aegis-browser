[English](./README.md) | [**简体中文**](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# 补丁

本目录中的补丁应用于本地 checkout 内固定的 Chromium 提交（`../CHROMIUM_COMMIT`）之上。

## 约定

1. 文件命名为 `0001-short-title.patch`、`0002-...`
2. 按应用顺序列入 `series`
3. 优先采用小型、易审查的差异，通过 `aegis/` 集成层接入，避免大范围改写 Blink
4. 不要把完整 Chromium 源码树放进本 Git 仓库

## 当前候选补丁序列（2026-10-07）

当前Ver 2.1 (125)为桌面270项Chromium+3项V8，Android270+3项独立补丁。0270仅递增产品版本；构建清单补入image_diff，以执行网页安全测试。124实际通过记录保留，125尚待重新构建和验收。

### 124准备记录

当前Ver 2.1 (124)为桌面269项Chromium+3项V8，Android269+3项独立补丁。0269补齐两个上游预取测试准备方法的HTTP网络类型与文档提交；保留原有安全断言。123已完成编译，但六项递归预取测试失败，未完成验收；124仍需实际构建和回归。

### 123准备记录

当前Ver 2.1 (123)为桌面268项Chromium+3项V8，Android268+3项独立补丁。0268保留Aegis服务回归的测试界面注入接口，并加入生命周期检查及3项回归。122因上游移除接口导致原生测试编译失败，未完成验收；123仍需实际构建和回归。

### 122准备记录

当前Ver 2.1 (122)为桌面267项Chromium+3项V8，Android266+3项独立补丁。0267补齐155递归预取工厂的当前文档上下文参数，保持上游请求拒绝和隔离检查。121因缺失参数编译失败，未完成验收；122仍需实际构建和回归。

### 121准备记录

当前Ver 2.1 (121)为桌面266项Chromium+3项V8，Android265+3项独立补丁。0266将155侧栏获取迁移到SidePanelUI::From，覆盖产品入口和原生测试。120原生构建因旧侧栏接口调用失败，未完成验收；121仍需实际构建和回归。

### 120准备记录

当前Ver 2.1 (120)为桌面265项Chromium+3项V8，Android264+3项独立补丁。0264移除155已删除的旧测试依赖，0265修正安全中心生命周期方法顺序并递增版本。119原生构建因界面排序检查失败，未完成验收；120仍需实际构建和回归。

### 119准备记录

桌面固定 Chromium 155.0.8059.40；263项Chromium补丁和3项V8补丁已完成独立、无需三方合并的重放验证。17项原有补丁按155接口逐项适配，0263将产品递增至Ver 2.1 (119)。Android正式Stable仍为154.0.8037.126，使用`../ci-pins/android.json`及`../patches-android`中的独立263+3项补丁，不能以桌面155补丁替代。当前仅通过源码补丁验证，119完整构建、原生测试、三平台实机、签名及发布仍待完成。

## 118历史候选补丁序列（2026-10-06）

当前 Chromium 154 候选包含 **262 个 Chromium 补丁与 3 个 V8 补丁**。0252 增加 Android 关于页发行检查、APK下载校验和系统安装确认；0253适配工具栏窗口接口；0254保留导航提交的策略拒绝断言；0255适配3个浏览器测试文件的窗口接口，保留全部测试断言。0256/0257补齐关闭标签枚举引用并适配远程调试和交互测试接口。0258适配策略通知测试的上游构造接口并保留生命周期断言。0259按新版ByteSize类型保留预取长度断言。0260修复任务意图范围和真实界面夹具。0261统一产品标签并保留范围收窄证据断言。0262按真实侧栏生命周期重开测试任务视图。产品版本为 Ver 2.1 (118)。完整源码核对、Android回放和构建状态以118版独立证据为准；三平台实机验收和正式发布尚未完成。

## 历史本地补丁序列（120 项快照）

状态“series 中”只表示补丁文件列在当前本地 `series`；不表示已经进入上游 Chromium、通过发行门禁或可以发布。49、67 和 95 补丁记录只保留为历史快照。当前整合源码包含 **120 个 Chromium 补丁 + 2 个嵌套 V8 补丁**：0057–0065 是原 Browser Agent 集成，0066–0067 是设置/更新和视觉品牌，0068–0108 用 Browser Agent v2 Runtime 替换并强化 v1 执行路径，同时加入跨平台入口、定时自动化、指定站点路由、Profile 隔离、有界恢复、浏览器绑定的标签页/文档能力、正确产品身份、脱离 UI 序列的持久化、确定性销毁和启用断言时安全的限流处理。补丁 0109–0113 增加并强化 GitHub 浏览器更新及产品状态/文案；补丁 0114–0116 增加访问路由规划、可信策略匹配及 Profile 规则库原子持久化/恢复合同。补丁 0117 增加首个 fail-closed `net::ProxyInfo` 路由适配器，仅接受已登记的 numeric-loopback HTTP 代理入口且不提供 DIRECT fallback；补丁 0118 通过 Chromium 原生 custom-proxy delegate 将精确 host 选择绑定到 Profile/StoragePartition NetworkContext，未选中的 host 保留 Chromium 原生代理结果；补丁 0119 增加真实 NetworkService/URLLoader 的 localhost HTTP/HTTPS 代理验收用例，并覆盖代理不可用时禁止 DIRECT 回退；补丁 0120 使用 Chromium 自带 GoogleTest 扩充代理 identity tuple、partition/selection 边界、未选中站点原生路由及 HTTPS dead-proxy fail-closed 回归。补丁 0079–0095 重放到 Chromium 源码提交 `c930fa41ef7e9522f145848f3080ee0cc1edc4d8`；补丁 0096–0101 生成 `1c63ce994b2815fe1f3dc07608ff121d987e0441`（tree `451b3148d12fc2cff2df293cb0f1bb0d6242a908`）；补丁 0102 生成已提交源码 `13807aaf086948bdff0370e356718d0c2ac54d27`（tree `4546f1afcabf38013ba9bef7e9e5d078ffd3ca77`）。产物资格仍按平台分别判定，并且必须绑定这份精确源码的验收证据。

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
| 0093 | 支持显式本地 fixture URL 有效性检查 | series 中 |
| 0094 | 规范化原生任务完成证据 | series 中 |
| 0095 | 保留已验证完成状态和收藏夹撤销能力 | series 中 |
| 0096 | 将模型浏览器能力绑定到实时任务上下文 | series 中 |
| 0097 | 等待范围内导航提交，并在 Profile 初始化前注册 Aegis 服务 | series 中 |
| 0098 | 在浏览器身份界面使用 GCSA Aegis 品牌 | series 中 |
| 0099 | 将 Agent 任务存储移出 UI 序列 | series 中 |
| 0100 | 在测试夹具销毁前清空 Profile 指针 | series 中 |
| 0101 | 同源 URL 遇到限流后有界完成剩余收藏夹检查 | series 中 |
| 0102 | 在有界 URL 检查中安全读取不可合并的 Retry-After | series 中 |
| 0103 | 等待原生下载完成并验证真实下载结果 | series 中 |
| 0104 | 修复 Android 无痕隔离守卫编译 | series 中 |
| 0105 | 注册 Android Agent 通道，修复定时任务安全回退及状态提示 | series 中 |
| 0106 | 使用缓存语言设置，避免 Windows 界面线程阻塞；补充原生浏览器回归测试 | series 中 |
| 0107 | 在资料启动时恢复已启用的 Agent 监控 | series 中 |
| 0108 | 补齐已核验的执行、安全文本、监控与摘要修复 | series 中 |
| 0109 | 增加 GitHub 浏览器更新检测和安装包下载 | series 中 |
| 0110 | 保留本机验收构建使用的链接资源限制 | series 中 |
| 0111 | 页面关闭后继续完成更新包安全检查 | series 中 |
| 0112 | 修正 GitHub 更新器 Chromium 风格并递增至 Ver 1.1 (003) | series 中 |
| 0113 | 修正设置文案与产品状态并扩充翻译 | series 中 |
| 0114 | 增加原生访问路由规划与网站组合同 | series 中 |
| 0115 | 增加可信请求归属规范化与策略匹配 | series 中 |
| 0116 | 增加 Profile 访问规则原子持久化与恢复 | series 中 |
| 0117 | 将已登记的 loopback HTTP 代理以 fail-closed 方式应用到 Chromium `ProxyInfo`，不提供 DIRECT fallback | series 中 |
| 0118 | 将精确站点的 localhost HTTP 代理选择绑定到 Profile/StoragePartition NetworkContext | series 中 |
| 0119 | 增加真实 NetworkService/URLLoader localhost 代理验收与代理失效 fail-closed 回归 | series 中 |
| 0120 | 扩充 Access C++ GoogleTest 的 ownership、partition、selection 与 fail-closed 回归覆盖 | series 中 |

0103–0105 已从 0102 基线精确重放到 `1e1341b51e3254d4638bc1917b140f30d4c1e9d7` 的源码树 `babd10e2e757d7b57f1b7ef18eac26ee5becc9cb`，平台实际验收仍是独立门槛。

0106 已从该候选精确重放到 `383d157c6f3601101038aef6ff964e61b6af7b4f`（tree `2c509e07ec25fa8811adae17f9826e967c9bcee1`）。这是历史源码节点，不代表当前完整补丁序列。

2026-09-10 从固定基线完整重放 108 个补丁，得到源码树 `319366182c31108e29e62d2f2199aff29a0b86e8`；2 个 V8 补丁也单独核验。详见[合并记录](../../../docs/audit/main-consolidation-2026-09-10.md)。本次提交没有重新编译 App。

在干净、固定版本的 checkout 上运行 `pnpm --filter @gcsa-aegis/browser apply-patches` 进行应用。任何 series 变化都必须重新完成离线重放、冷构建、增量构建和受影响测试。
