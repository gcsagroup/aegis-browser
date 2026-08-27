# 研究与实现映射

[English](research-map.md) | **简体中文** | [繁體中文](research-map.zh-TW.md)

本文区分已实现工程、研究启发和缺失证据。引用论文不表示 GCSA-aegis 已复现其模型、数据集、准确率、隐私或安全结论。当前产品是集成式 Chromium Browser；扩展相关研究只保留为历史背景。

## 钓鱼、URL 与解释

- [客户端 URL 分析](https://arxiv.org/abs/2506.03656)：浏览器已有有界 URL 和页面启发式；普通导航热路径不运行 JavaScript 动态分析。
- [PhishLang](https://arxiv.org/abs/2408.05667)：实现包含 punycode，以及部分品牌、路径、凭据和跨站表单信号，但没有论文中的双输入语言模型。
- [Explain, Don’t Just Warn!](https://arxiv.org/abs/2505.06836)：钓鱼拦截页显示原因码和权重；用户理解测试与更完整的多语言证据仍未完成。
- [EXPLICATE](https://arxiv.org/abs/2503.20796)：确定性原因码提高可追溯性，但不是完整可解释 AI 系统的复现。

当前方向：高置信确定性检查留在浏览器内；未来模型只处理有界灰区；任何阻断行为变更前，必须使用独立标注数据验证误报。

## 跟踪、Cookie 与链接清洗

- [WebGraph](https://arxiv.org/abs/2107.11309)：Core 已有对调用方事件进行有界聚合的行为图函数。Chromium 尚未采集完整 DOM、存储、标识符、跳转和网络流，因此不是浏览器 WebGraph 系统。
- [PURL](https://arxiv.org/abs/2308.03417)：运行时代码使用固定跟踪参数集合；站点级规则应离线生成，并在兼容性回归后才能采用。
- [ASTrack](https://arxiv.org/abs/2301.10895)：仅 Node AST 结构签名原型可识别多站候选，但没有分支安全分析、语义切片、代码改写或选择性删除。
- [AdGraph](https://arxiv.org/abs/1805.09155)：尚未实现生产图分类器。
- [第一方与 SST 跟踪](https://arxiv.org/abs/2606.16720)和 [SST-Guard](https://arxiv.org/abs/2604.27497)：当前只覆盖部分收集路径与参数模式，不覆盖全部服务端埋点。
- [MV3 广告拦截研究](https://arxiv.org/abs/2503.01000)：适用于历史 Extension 阶段，不能证明当前 Browser-only 架构。
- [CookieBlock](https://www.usenix.org/conference/usenixsecurity22/presentation/bollinger)：当前 Cookie 处理基于规则和名称，仍需代表性登录与支付回归。
- [CookieGraph](https://arxiv.org/abs/2208.12370)：尚未实现完整 Cookie 信息流图。
- [The CNAME of the Game](https://petsymposium.org/popets/2021/popets-2021-0053.pdf)：浏览器将网络层提供的 DNS alias 与本地跟踪器规则比较；这不是通用 CNAME 跟踪器分类器。

## 隐私 AI、最小化与本地自动化

- [Big Help or Big Brother?](https://arxiv.org/abs/2503.16586)：桌面摘要支持本机启发式和用户配置的兼容 API。远程使用仅在确认目标后发送有界脱敏文本，但仍缺完整 Chromium 出站证明。
- [WebLLM](https://arxiv.org/abs/2412.15803)：研究性质本地 advisory contract 只接收去标识的特征类别，错误时必须弃权。当前没有 in-browser WebLLM 后端或捆绑模型。
- [Casper](https://arxiv.org/abs/2408.07004)：当前脱敏使用确定性模式和校验算法；更广泛的本机 NER 属于后续工作。
- [MINIM](https://arxiv.org/abs/2606.13949)：所选 CDP 路径通过来源和精确文档授权缩小暴露面；获授权的本地 agent 仍可读取已授权 HTTP(S) 页面的原始 DOM。

## 指纹与 JavaScript 研究

- [ByteDefender](https://arxiv.org/abs/2509.09950)：默认关闭的 V8 Ignition opcode shadow 原型输出有界、仅观察摘要；没有函数级模型或阻断，也不覆盖全部 cache、snapshot 或 Wasm 路径。
- [FP-Fed](https://arxiv.org/abs/2311.16940)：本地模拟研究裁剪更新、成对掩码和 Gaussian noise；固定不可部署，不是真实 secure aggregation 或 opt-in 生产系统。
- [WebGPU 隐私](https://arxiv.org/abs/2606.26412)：已降低部分 adapter 字符串、limit bucket 和高熵 subgroup 信号；主动输出、计时与 pipeline cache 通道仍待研究。

## 当前 JavaScript 与 MinerGuard 边界

- 仅 Node AST 分析器使用 TypeScript parser，限制大小和复杂度，只输出计数与原因码，不输出源码、字面量、URL 或 payload。它不在页面执行路径中。
- 有界行为与来源函数只处理调用方提供的分类事件，不是在线浏览器信息流系统。
- MinerGuard 组合部分浏览器侧 CPU 估算、Worker/Wasm/WebGPU/共享内存信号、WebSocket 观察和强端点 token；只记录观察结果，不停止脚本、Worker 或连接。
- 当前研究语料由合成 fixture 构成。内容摘要只校验完整性，不证明独立封存；`sealIsolationVerified=false`、`finalEvaluationEligible=false`，最终评测入口保持闭锁。

## 证据与发行门禁

1. 研究指标、产品运行证据和发行资格必须分开。
2. 检测器影响页面行为前，必须补齐独立良恶性标注、真实站点、混淆测试、误报测量、性能预算和破站测试。
3. 仅观察信号、合成 fixture 结果或声明完整性检查都不能写成安全授权。
4. 受影响门禁必须在同一已提交源码和带身份清单的产物上重跑。现场源码为 56 个顶层 Chromium 补丁加 2 个嵌套 V8 补丁，而最新身份绑定 build-tree 只覆盖 54 加 2。

研究项目对生产阻断和“通用恶意 JavaScript 防护”声明仍为 **No-Go**。
