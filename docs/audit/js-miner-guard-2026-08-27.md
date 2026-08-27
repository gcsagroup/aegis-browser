# JavaScript 分析与 MinerGuard 实施报告（2026-08-27）

## 结论

本轮把原先“没有恶意 JS/挖矿脚本检测”的结论推进了两步：Core 已有真实 AST 离线分析和有界行为图聚合；Chromium 53/53 补丁 HEAD 已有浏览器可信侧、仅观察的 MinerGuard。两者都不执行来源脚本、不保存源码或 WebSocket payload，MinerGuard 也不终止脚本、Worker 或连接。

最终身份绑定运行矩阵 71/71 通过：1 个正例产生告警，3 个负例和 2 个关闭控制均为 0 告警，且没有新增 crash 或残留进程；运行层结论为 `runtime_pass=true`、`qualification=partial`，只证明当前受控场景下的检测与关闭语义。发布层仍缺严格代码签名、独立良性语料、阻断模式验证和正式安全批准；根仓库也为 dirty，身份只能标记为 `diagnostic-only` / `cooperative-local-workflow`，`trustedBuildAttestation=false`。因此 `release_eligible=false`，项目结论仍是 **No-Go**。

这仍不是通用恶意 JavaScript 防护。后续 Phase 2 已增加 AST 结构签名与多站分支候选、有界 provenance flow、默认关闭的 V8 Ignition opcode shadow、本地 LLM advisory contract 和联邦本地模拟，但都只是 research-only POC：没有 AST 切片、完整浏览器实时信息流、函数级模型或生产阻断，也没有部署本地模型或联邦服务。当前语料全部为合成 fixture，不能替代独立良恶性标注、真实站点、precision/recall/FPR、混淆绕过、性能和破站率评测。

## 已实施能力

### 1. Node-only 真实 AST 分析

- 使用 TypeScript parser 生成真实 AST，不以正则冒充语法分析。
- 默认最多分析 1 MB，硬上限 2 MB；深层嵌套或资源异常时 fail-open，返回 `parseStatus=failed`，不抛给调用方。
- 提取 Worker、Wasm、WebGPU、SharedArrayBuffer、WebSocket、挖矿协议字面量、hash-like loop、动态代码、编码载荷、远程加载和执行环境分支等来源无关信号。
- 输出只包含计数、节点数、深度和原因码，不包含源码、字面量、URL、payload 或 flow id。
- AST 入口只通过 Node 条件子路径导出；浏览器安全主入口和 policy worker 不打入 TypeScript parser。

后续 Phase 2 已增加去标识符/字面量的 AST 结构签名和至少两个独立站点组才能形成的分支候选；合成、单站或冲突标签会弃权。它仍没有 ASTrack 的分支安全分析、语义切片、代码改写或选择性删除，固定 `wouldSlice=false`，不直接阻断脚本。

### 2. 有界行为/信息流图 POC

- Core 纯函数在调用方提供的滚动窗口事件上聚合 CPU、Worker、Wasm、WebGPU、网络连接、敏感读取和发送关系。
- 每类事件、图节点、边和原因计数都有上限；普通事件不能逐出 CPU、挖矿协议或敏感流等高价值证据。
- 只有运行时持续计算、WebSocket 与挖矿协议均被观察到时，挖矿 finding 才能达到高置信；静态共现保持中等置信。
- flow id 只在内存中关联读与发，结果不输出 id、值或 payload；发送早于读取不会形成信息流边。

后续 Phase 2 已增加单 document scope 的有界 provenance flow，可关联 script/function 与 DOM、storage、network、worker、Wasm 的固定类别事件，且不输出调用方 ID、值、源码、URL 或 payload。浏览器目前仍没有采集完整 DOM、Cookie/storage、redirect、标识符值或网络行为；这是调用方供数的纯函数 POC，不是实时浏览器信息流系统。

### 3. Chromium MinerGuard（observe-only）

- PageLoadMetrics observer 读取 Worker/Wasm/WebGPU/共享内存/WebSocket UseCounter，并通过 Resource Attribution 获取估算页面 CPU；它不是函数级或精确 JS CPU 归因。
- 浏览器 WebSocket 创建路径只做验证后的通知，从 host/path 的精确 token 识别 `stratum`、`cryptonight`、`coinhive`、`xmrig`、`webmine` 等强端点标志；忽略 query、fragment、credentials 和 payload。
- 每个信号使用滚动 30 秒时间戳。判为 likely mining 必须同时具有已采样的高 CPU、连续高 CPU、强端点，以及 Worker/计算/通信组合；CPU、Worker、Wasm、WebGPU 或普通聊天 WebSocket 单独出现都不能触发。
- CPU 只在候选能力组合出现后采样；每轮最多 15 次、间隔 2 秒，随后退避 30 秒再开始有预算的新一轮，避免长页面在首轮后永久绕过。
- 文档身份使用 Reporting Source token，同站跨文档导航不会拼接旧页证据。总 feature、MinerGuard feature、Pref 和站点暂停在 hook、observer、service 三层复核。
- 命中只在当前会话记录 `miner / likely_mining` 原因码。UI 明确显示“历史提醒、仅观察、未阻断”，且不把它计入“已处理/已保护”数量。

### 4. Phase 2 研究扩展（未进入页面执行路径）

- 内容寻址语料清单按内容、站点、家族和时间组确定性划分 train/validation/public holdout；评测不联网、不执行 fixture。公开 corpus 可查看成员、标签和分组，`integrityDigest` 只做完整性校验，不是 seal；协议固定 `sealIsolationVerified=false`、`finalEvaluationEligible=false`，`--final` 闭锁。真正 sealed test 仍需未来独立持有方隔离。当前语料全部为项目自建合成样本。
- V8 源码 POC 在 Ignition bytecode finalization 后生成有界 opcode 摘要，默认关闭且固定 `would_block=0`；不保存 operand、constant、源码、URL 或函数名，不覆盖 cache/snapshot/Wasm，也没有函数级模型。
- 本地 LLM contract 只接收去源码类别特征，仅给灰区 advisory，异常时 fail-open 为 `abstain`，不能改变浏览器决定；当前没有捆绑或训练模型。
- 联邦组件只是无源码特征的本地模拟，不保留原始客户端更新或客户端标识，固定不可部署；没有真实跨设备 secure aggregation、opt-in 或投毒防护。
- 研究 gate 只是 unverified claims completeness evaluator，核对声明是否覆盖独立语料、真正 sealed test、准确率/FPR、混淆、性能、破站、V8 稳定性、回滚和隐私，不验证外部证据真实性。即使 claims 全过也固定 `eligibility=observe-only`、`authorizationEligible=false`，不能作为发布或阻断授权。

本报告前述 71/71 身份绑定矩阵只验证 53 补丁 MinerGuard，不验证这些 Phase 2 研究扩展。Phase 2 的补丁身份、构建、原生测试、真实 App 运行和精确观察计数待主执行任务完成后另行回填。

## 已修复的假保障风险

- 原“30 秒窗口”实际会被持续 CPU 回调无限续期，现已改为逐信号滚动过期。
- 原 LocalFrameToken 可在同站跨文档导航复用，现改为文档级 Reporting Source token，并增加导航回归。
- 原任意 UseCounter batch 都会上报、任意 WebSocket 都会触发 CPU 查询，现只上报首次相关变化并要求有用能力组合。
- 原 CPU 值即使没有 `cpu_sampled=true` 也会参与 verdict，现已硬性要求可信采样标志。
- 原历史 MinerGuard 告警会在模块关闭后继续驱动健康警告，并被工具栏算作已处理；现已分离历史观察与实际处理。

## 验证证据

- Core：77/77 单测通过；typecheck 和 build 通过。
- 代表 AST 输入：解析成功，输出 Worker/Wasm/WebSocket/挖矿协议原因码，序列化结果不含测试 URL 或源码。
- 代表行为图输入：输出 `high-confidence` suspected mining，但固定为 `mode=observe-only`、`wouldBlock=false`。
- 浏览器原生：`aegis_unittests` 76/76、`aegis_browser_unittests` 44/44 通过，覆盖 MinerGuard 模型、逐信号滚动窗口、开关矩阵、跨序列 reporter 和文档身份回归。
- MinerGuard 验证器 self-test：10/10 通过；fixture 只监听 `127.0.0.1`，不含钱包、share、真实矿池或可复用挖矿载荷。
- 最终身份绑定运行矩阵：71/71 通过。1 个 Dedicated Worker + Wasm + 持续 CPU + loopback `stratum` 路径正例产生 1 次告警；CPU-only、Worker/Wasm 高负载但无强端点、普通聊天 WebSocket 三个负例均为 0；Pref 关闭和 Aegis 总开关关闭两个控制也均为 0。全部场景为 0 新 crash、0 残留进程。
- UI：最终措辞修订前的同布局 `out/AegisRelease` build-tree App 已用 Computer Use 在 1280×900 窗口检查 `chrome://aegis`，页面无明显裁切或错位；MinerGuard 开关完成 1→0→1 往返。最终重建版因 macOS 锁屏未完成重复可视接管；其打包资源包含最终会话级提示，且真实 App 六场景运行矩阵已通过。
- 源码与产物身份：外部 Chromium 提交为 `fb283ec560ec507b5877da8ef61dc1a75073cd78`，对应本地补丁 53/53；schema v3 manifest SHA-256 为 `0e208d3f91e2cdde4a25ec8153d510ebc18edc1a7248169b395e77cfc0af13c8`，App tree SHA-256 为 `6281b10a6732de8a50452b40471cf53571ae535a3a84508231581e5f59da74b1`。最终运行报告为 `.artifacts/runtime/miner-guard-final-2026-08-27.json`，SHA-256 为 `f7d45268232a441dc1d672ad6801441a8020cbbefcd63c24a6cc468234a6f3e9`。
- 构建与发布边界：根仓库 dirty，因此这批证据只属于 `diagnostic-only` 的本地协作流程；`binding.trustLevel=cooperative-local-workflow`、`trustedBuildAttestation=false`，且 `localCandidate=false`、`releaseCandidate=false`。运行时门通过不覆盖仍为 false 的严格代码签名、独立良性语料、阻断模式验证和正式安全批准，不能据此生成或宣传 Release/RC。

## 剩余风险与下一步

1. 先用独立的良性高负载语料（游戏、视频编解码、本地 AI、科学计算、聊天）和由独立持有方合法审查的恶意样本建立阈值，不以本轮公开合成样例计算正式准确率。
2. 若扩展行为图，只对中高风险页启用严格时间/内存/事件预算的可信侧采集；不读取任意 payload，不把完整图放入每请求热路径。
3. V8 Ignition opcode shadow 源码 POC 必须先完成补丁身份、构建/运行、隔离采样、离线标注和 fail-open/rollback 评测；它不覆盖 cache/snapshot/Wasm。没有混淆、性能和破站门前不改变执行语义。
4. 本地 LLM 目前只有严格 advisory contract；联邦能力目前只有本地模拟。前者须在独立灰区语料验证后才可接模型，后者须在本地检测器稳定后再以明确 opt-in、真实 secure aggregation、差分隐私和投毒防护推进。
5. 当前强端点只识别有限精确 token；通用 URL、Shared/Service Worker 的无 frame 连接、WebTransport/fetch 通信和低占空比计算可能漏检。当前也不覆盖完整多 Profile 分发、Prerender 和函数级 CPU 归因，产品口径必须保留这些边界。
