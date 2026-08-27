# JavaScript 防护评估与反指纹加固（2026-08-26）

> 2026-08-27 后续执行已补齐本地源码—产物身份链、隔离打包与实际
> `chrome://aegis` 验收；本文以下“尚无清单/桌面验收阻塞”保留为
> 2026-08-26 当时的历史结论。当前状态以
> [JS 构建身份与签名执行报告](./js-build-identity-and-signing-2026-08-27.md)
> 为准，正式发布仍是 No-Go。

## 结论

- **P0 反指纹加固的本地行为验收通过**：Release Chromium 完成 347/347 条运行时断言，Canvas、OffscreenCanvas、Audio、WebGL、WebGPU、Dedicated/Shared/Service Worker 的本轮覆盖门均通过。
- **“JavaScript 恶意代码检测”仍是 No-Go**：项目没有 AST、V8 bytecode、运行时行为图、信息流模型、联邦检测或本地 LLM 脚本分类器。现有能力应准确表述为反跟踪、反指纹、钓鱼缓解和浏览器内部边界保护。
- **发布仍是 No-Go**：本轮没有构建时源码—产物身份清单，`codesign --verify --deep --strict` 也未通过。本次只完成本地源码、补丁、构建、测试和运行时验收，没有部署、签名、打包或发布。

## 本轮实际完成

### 1. 统一有效开关

FingerprintGuard 现在只有一套有效状态：Aegis 总开关、FingerprintGuard 子开关、用户 Pref 和站点暂停必须同时允许才生效。浏览器服务、renderer 参数下发和 Blink 读取使用同一语义，并增加 8 种组合单测。

这修复了旧实现中 `--disable-features=AegisEnabled` 或关闭子功能后，WebUI 显示关闭而 renderer 仍可能扰动的状态分裂。

### 2. 稳定且分区的私有种子

- 普通 Profile 持久保存 32 字节随机私钥；Guest/Incognito 只在各自 Profile 生命周期内使用随机私钥。
- renderer 不再自行生成公开可关联的进程 salt，而是用 HMAC-SHA256 按 `aegis-farbling-v1 / schemeful site / surface / 7 天 UTC epoch` 派生。
- 站点键使用注册域边界，子域稳定；不同顶层站点、不同 Profile 和隐身会话分离。
- 删除 WebGL/WebGPU 中的 `Aegis` 明文和 token 片段，避免形成产品专属指纹。

### 3. 指纹表面收口

- **Canvas**：覆盖 8-bit、`rgba-float16`、`rgba-float32`；浮点扰动保持格式、有限值和 alpha 语义。
- **OffscreenCanvas**：覆盖 `convertToBlob()` 和 `transferToImageBitmap()`；后者先生成受保护快照，再执行破坏性 transfer，失败时不提前清空源画布。
- **Audio**：首次读取才扰动；关闭状态下读取不会永久跳过后续保护。`copyToChannel()` 精确保留脚本自己写入的数据，避免自别名和重复噪声。
- **WebGL**：保护模式隐藏 `WEBGL_debug_renderer_info`，包括先获取 extension、后切换状态的旧引用。
- **WebGPU**：adapter 字符串置空；`maxBufferSize`、`maxComputeWorkgroupStorageSize`、`maxTextureDimension3D` 向下收敛到有限人口桶；超出公开桶的 `requiredLimits` 被明确拒绝；隐藏高熵 subgroup 特性并固定合规的 4/128 范围。
- **Worker**：Dedicated、Nested、Shared 和 Service Worker 获得顶层站点范围；本轮实际矩阵覆盖 Dedicated/Shared/Service Worker 的 OffscreenCanvas 路径。

### 4. 可重复的工程闭环

- Chromium 固定基线：`ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`。
- P0 源码提交：`53bd1c0a39f8c6ffe58d346c140b98a295f98de1`。
- P0 源码树：`29b11ca5a693c7f5829f5c356c700f50e44f49a9`。
- 根仓库新增 `0052-feat-aegis-harden-fingerprint-protection.patch`，SHA-256 为 `3925d4643ec362c6ae4f8a175c3ff1705025b676982470c5276db9d368b853f3`。
- 从固定基线顺序重放全部 52 个补丁成功，重放后的树哈希与 P0 源码树完全一致。
- 新增严格运行时验证器，区分 `runtime_pass` 和 `release_eligible`，不会把行为通过误写成可发布。

并行出现的原生下载设置源码提交 `3fd71b41b53e1117573d45131b82022335e2e4f5` 被保留为独立提交和 `0051` 补丁，没有混入 P0 指纹提交。

## 验证结果

### 源码与构建

- `git diff --check`：通过。
- Chromium Release 增量构建：`chrome`、`aegis_unittests`、`aegis_browser_unittests` 成功，245 个实际步骤。
- 外部 Chromium checkout 在构建前后均为 clean。
- 52 个补丁的固定基线全量重放：通过；结果树精确匹配。

### 自动化测试

- Blink 指纹/Audio 定向测试：5/5。
- `aegis_unittests`：63/63。
- `aegis_browser_unittests`：43/43。
- Core Vitest：47/47。
- 运行时验证器自测：10/10。
- lint、typecheck、脚本夹具、仓库合同检查和构建：全部通过。

### Release 运行时矩阵

最终证据保留在本地工作区，未随公开源码发布：`.artifacts/fingerprint-runtime-release-2026-08-26-rerun1.json`

- `runtime_pass=true`，347/347 断言通过，`coverage_complete=true`。
- 总 feature、子 feature、Pref、站点暂停的开启/关闭行为正确。
- 同一 Profile 重启后稳定；另一个 Profile 输出分离；两个顶层站点的第三方上下文分区。
- Canvas float16、两个 OffscreenCanvas 导出路径、WebGL raw/保护对照和 WebGPU 均实际可用。
- WebGPU 公开桶、device limits、3 个超限拒绝、raw 硬件对照、subgroup 4/128 与高熵 feature 隐藏均通过。
- 所有浏览器进程正常关闭，没有临时 Profile 逃逸进程；3 秒观察窗内 Crash 记录 62→62，无新增或修改。
- App 可执行文件 SHA-256：`9cb3c1893c4861a13c4dca01c0be88654464ba628bc9475d4c594326d0b62e08`。
- Framework SHA-256：`4283a7cf5ecccb6f0be5574d3f9bf70755264d10b38740af09d8519a24d26386`。

本地首轮证据 `.artifacts/fingerprint-runtime-release-2026-08-26.json` 保留了 339/347 的失败结果，未随公开源码发布。8 个失败均来自验证器错误：WebGPU raw 对照复用了已消费 adapter，Audio 又错误要求扰动脚本自行写入的已知值。修正验证器并重新通过 10/10 自测后，完整矩阵复跑为 347/347；没有删除或覆盖失败证据。

### 证据边界

- `release_eligible=false`：缺少构建时源码—产物身份清单，运行前后哈希只能证明验收期间产物未变化。
- `codesign --verify --deep --strict` 失败：本地 build-tree App 不满足正式签名结构门。
- 因此结论只能是“本地 Release build-tree 行为通过”，不能写成“已签名”“已安装”或“可发布”。

### 可视验收

- 应用内 Browser 通过 loopback 实际渲染 `docs/product.html`；简体中文和英文的新反指纹状态文案均可见，切换正常，控制台无 warning/error。
- Computer Use 已尝试按完整路径启动 `out/AegisRelease/Chromium.app`，但 Mac 当时处于锁屏状态且自动解锁失败。本轮没有绕过系统锁，因此实际桌面 `chrome://aegis` 交互验收仍未完成；这不影响 headless 运行时 347/347 结论，但继续阻止发布口径。

## 与论文能力的差异

### ByteDefender

论文在 V8 Ignition 阶段提取函数级 bytecode，用模型识别并阻止指纹函数。Aegis 没有 V8 改动、bytecode 模型或函数级阻断，只在 API 输出面缓解指纹，并按 URL 阻断已知跟踪资源。

### ASTrack

论文用 AST 结构签名识别并剪除跟踪分支，目标是应对改域名、CDN、minify、obfuscation 和混合打包。Aegis 没有 AST 解析、跨站签名传播或分支级删除；URL 命中时仍是整资源阻断。

### WebGraph / AdGraph / CookieGraph

论文将 DOM、脚本动作、网络请求、重定向、Cookie/storage 读写和标识符流构造成图。Aegis 目前只有 host/path/list/CNAME、固定 query 参数和 Cookie 名称启发式，没有运行时行为图或脚本—存储—网络信息流。

### Client-side Zero-Shot LLM

论文组合 AST、动态 hook 和本地 WebLLM。Aegis 没有网页脚本 AST、动态沙箱或本地 LLM 恶意代码分类；现有 Ollama 只用于用户触发的页面摘要，不参与普通脚本执行路径。

### FP-Fed

论文采集 JavaScript API 调用特征并用差分隐私联邦学习识别指纹脚本。Aegis 只扰动部分 API 输出，没有调用行为检测、联邦训练、隐私预算或投毒防护。

### WebGPU privacy

本轮已完成 adapter 字符串隐藏、3 类有限人口桶和 subgroup 高熵特性收敛，但仍未处理论文强调的主动输出、精细计时、pipeline cache、跨 origin/tab/profile/private 的 GPU 状态通道。当前实现是部分缓解，不是论文复现。

## 仍然存在的缺口

1. **不是恶意 JS 检测器**：inline script、`eval`、`new Function`、blob/data URL、同源恶意接口、未收录 CDN、动态生成代码和 WebAssembly 不会被内容分析。
2. **指纹覆盖仍不完整**：WebGL `readPixels` 主动输出、WebGPU pipeline cache/计时/主动输出，以及字体、屏幕、时区、语言、UA Client Hints、设备内存、CPU、MediaDevices/WebRTC 等仍未收口。
3. **切换刷新边界**：已创建的 `GPUAdapter` 缓存创建时的保护状态，修改总开关、子开关或站点暂停后需要刷新页面才能取得新 adapter 语义。
4. **签名与产物绑定未完成**：缺构建 manifest 和正式签名/公证/安装验证，不能进入发布流程。

## P1 取舍与下一步

本轮没有把 AST、图、bytecode、LLM 或联邦学习塞进默认页面加载热路径。当前缺少独立数据集、冻结协议、误报/破站基线和性能预算，直接上线会把研究设想误当成产品能力。

建议下一阶段按以下顺序执行：

1. **先补发布证据**：构建时生成包含 Chromium HEAD/tree、52 个补丁清单、GN args、关键二进制哈希的不可变 manifest，再做签名、公证、安装包与真实安装 App 验收。
2. **离线候选生成**：用 ASTrack/WebGraph/CookieGraph/FPT 思路离线生成 host/path/query/allow 候选，运行时继续使用有界索引；不在普通请求路径执行无界 AST/图分析。
3. **冻结独立评测**：至少 1,000 个真实站点，并单列登录、支付、购物车和 SSO；同时记录 precision/recall、混淆与 CNAME/URL 规避、破站率、CPU、内存和隐私泄漏。协议冻结后不得用同一候选名反复调参。
4. **再评估灰区脚本审计**：只有离线门通过后，才考虑在独立 Utility/一次性 Profile 中对中高风险页做有预算的 AST 或函数 bytecode 审计；默认 fail-open，并设置 CPU、内存、超时和副作用边界。

最终判断：P0 反指纹从“源码存在但证据不足”提升到了“本地 Release build-tree 行为通过”；通用 JavaScript 恶意代码防护和正式发布仍分别是 No-Go。
