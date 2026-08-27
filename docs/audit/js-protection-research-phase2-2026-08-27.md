# JavaScript 防护 Phase 2 研究实施边界（2026-08-27）

## 结论

Phase 2 已补齐一组可审计的 **research-only POC**：内容寻址合成语料与确定性公开 holdout 评测、AST 结构签名和多站标签分支候选、有界 provenance flow、默认关闭的 V8 bytecode shadow、本地 LLM 灰区 advisory contract、联邦本地模拟，以及研究声明完整性检查器。除 V8 的可选影子观察外，这些组件都没有进入浏览器页面执行路径；所有决策仍为 observe-only，不删除 AST 分支、不终止函数、脚本、Worker 或连接。

当前结论仍是 **No-Go**。现有语料全部为项目自建合成 fixture，缺少独立良恶性标注、真实站点与真实高负载良性样本、混淆绕过、正式误报率、性能和破站率验证。它只能证明研究工具链可以工作，不能宣传为通用恶意 JavaScript 防护、论文复现或生产检测能力。

## 已实现的研究 POC

### 1. 内容寻址语料与确定性公开 holdout 评测

- 每条样本记录 SHA-256、来源、许可证、标签证据、站点组、家族组、时间组和混淆层级。
- 内容、站点、家族或时间相关的样本先合并再分组，避免同源变体跨 train、validation 和 test 泄漏。
- 当前 corpus、成员、标签和 holdout 分组都在公开仓库中可查看；`integrityDigest` 只证明公开协议内容未被意外改写，不提供隐藏性或独立持有方隔离，不能称为 seal。
- 当前协议固定 `sealIsolationVerified=false`、`finalEvaluationEligible=false`，`--final` 闭锁，不允许把公开 holdout 当作最终评测。评测器不联网、不执行 fixture，只把本地文本交给 Node-only TypeScript AST 分析器。
- 当前仓库语料全部是 `synthetic-fixture`。尚无独立复核标签和真实世界样本，因此现有指标不得外推为生产 precision、recall 或 FPR。

### 2. AST 结构签名与分支候选

- Node-only 分析器生成去标识符、去字面量值的 SHA-256 AST 结构签名，并输出函数、分支的固定预算摘要和源码偏移范围。
- ASTrack 风格候选只接受精确结构哈希；正向标签至少需要两个独立站点组，合成标签、单站标签或良恶冲突都会弃权。
- 输出固定为 `mode=observe-only`、`wouldSlice=false`。当前没有执行 ASTrack 的分支安全分析、语义切片、代码改写或选择性删除，也没有接入页面加载热路径。

### 3. 有界 provenance flow

- 在单一 document scope 内关联 script/function 与 DOM、storage、network、worker、Wasm 的固定类别事件，并用有界 flow id 形成 source-to-sink 关系。
- 节点、边、事件、actor、flow id、窗口和每桶数量都有硬预算；输出不包含调用方原始 ID、值、源码、URL 或 payload。
- 这是调用方供数的浏览器安全纯函数 POC。Chromium 尚未采集完整 DOM、Cookie/storage、redirect 或网络信息流，不能称为 WebGraph、CookieGraph 或浏览器实时信息流系统。

### 4. V8 Ignition opcode shadow

- 在 renderer 进程内当前 Ignition bytecode finalization 线程生成版本化 opcode 序列摘要；调用既可能发生在 foreground，也可能发生在 LocalIsolate/worker 线程，不能简化为固定的 renderer 主线程。
- 功能和专用 Perfetto 分类均默认关闭。只有 feature/flag 与 `disabled-by-default-v8.aegis.bytecode_shadow` 分类同时开启后，才占用记录额度并遍历 bytecode；记录数和 byte 数均有硬上限。
- trace event 只包含固定数值 schema、状态、长度、opcode 数和 64-bit 签名分片，不保存 operand、constant、原始源码、URL 或函数名。确定性 opcode 签名仍是可跨运行关联、可被字典匹配的伪匿名指纹，不能称为匿名或不可识别。
- 输出固定为 `would_block=0`，只表示“不作 JS 阻断决定”，不表示 Perfetto 写入 wait-free；设计上不改变 BytecodeArray 或执行结果。
- 当前只覆盖本次走到 Ignition finalization 的 bytecode，不覆盖 code cache、snapshot 或 Wasm，也没有函数级模型、风险分类和阻断。
- 本轮已删除 finalization 路径上的显式同步 `PrintF(stderr)`，改为专用 Perfetto instant event，不再等待文件、pipe 或 socket I/O。启用后仍有原子额度竞争、最多 64 KiB opcode 遍历和 Perfetto 内部同步，因此不能声称形式化 non-blocking、wait-free 或“零执行影响”。
- 真实运行先用独立 pipe-holder 对 1,000×126 bytes 固定合成同步 stderr 写入校准反压，再在 STRESS 页面完成前保持 Chromium stderr 无 reader；页面在 holder 释放前完成。该证据只关闭原同步 stderr 的活性回归，不替代真实站点性能、长时间稳定性或生产热路径证明。
- 当前顶层 Chromium 与嵌套 V8 补丁已完成身份、编译、原生测试和身份绑定真实 App 运行验证；验证证明默认关闭、开启后只观察、有界记录和受控场景活性语义，但不扩大为函数级分类、页面阻断或生产资格。

### 5. 本地 LLM 灰区 contract

- 只允许 in-process 或经浏览器约束的 numeric-loopback 模型，输入是去源码、去 URL、去 payload 的类别计数。
- 只复核中等风险灰区，严格限制超时和输出 schema；模型不可用、超时或输出异常时 fail-open 为 `abstain`。
- 输出固定为 advisory、`wouldBlock=false`，不能改变浏览器决定。当前没有捆绑或训练本地模型，也没有进入页面执行路径；这不是 WebLLM backend。

### 6. 联邦本地模拟

- 使用无站点、URL、源码、payload 或 flow id 的固定特征向量，模拟 participant clipping、pairwise mask 聚合和带基础组合上界的 Gaussian 差分隐私。
- 报告不保留原始客户端更新或客户端标识符，固定 `deploymentEligible=false`。
- 当前没有跨设备服务、真实 secure aggregation、隐私预算运营、opt-in、投毒防护或联邦模型下发，也不用于页面判定。

### 7. 研究声明完整性检查器

- 检查器核对调用方声明是否覆盖语料溯源与许可证、独立标注、真正 sealed test、precision/recall/FPR、混淆召回、性能、真实站点破站率、V8 样本与崩溃率、fail-open/kill switch/rollback、隐私，以及本地模型和联邦组件状态。
- 它是 unverified claims completeness evaluator，不验证声明对应的外部事实或证据真实性；默认阈值只定义声明应覆盖的最低字段，缺项会失败。
- 即使全部 claims 通过，报告也固定 `eligibility=observe-only`、`authorizationEligible=false`，不能作为发布、进入页面执行路径或阻断授权。当前结论保持 observe-only / No-Go。

## 尚缺的证据与产品能力

1. 独立来源、合法持有、经独立复核的良性与恶性语料，以及由未来独立持有方隔离、在候选冻结后一次性开启的真正 sealed test。
2. 混淆、代码生成、低占空比、Worker/SharedWorker/ServiceWorker、WebTransport/fetch、code cache/snapshot/Wasm 等绕过覆盖。
3. 真实高负载良性页面的误报率，跨站 CPU/内存开销，长时间稳定性，以及登录、支付、视频、游戏、本地 AI 等破站率。
4. V8 影子功能仍缺大规模真实站点、混淆变体、code cache/snapshot/Wasm 覆盖、长期 crash rate、页面性能和破站率证据；本轮身份绑定运行只覆盖受控 loopback fixture。32 MiB 验证专用 trace 在该场景零丢失，不代表真实站点 metadata 规模或产品遥测预算已经合格。
5. 可冻结的检测器或模型、版本化阈值、误报申诉与站点例外、紧急 kill switch、回滚和正式安全审批。

上述证据闭环前，不得把 Phase 2 写成“已实现 V8 函数级阻断”“已实现 ASTrack 切片”“已实现完整浏览器信息流”“已部署本地 LLM/联邦检测”，也不得宣传为通用恶意 JS 防护。

## 当前验证证据

### 源码身份与重放

- Chromium base 为 `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`，顶层 54 补丁 HEAD 为 `573e044e75fc0529cd28ea2adcba55cfc04dd97b`。
- V8 base 为 `792d9716fea48312ad7ce4413c538e00628b1d50`，嵌套 2 补丁 HEAD 为 `9c0b1f276ba116e8b25a55466207e6586b44be16`；第二个补丁固定删除同步 stderr 并注册默认关闭的专用 trace 分类。
- `status` 对顶层和嵌套补丁的顺序、稳定 patch-id 与 overlay 一致性均精确通过；Chromium 顶层工作树在忽略已单独验证的 V8 gitlink 后无其他改动，V8 工作树本身干净。父仓库原生 `git status` 仍会按预期显示 `M v8`，因为嵌套 checkout 从钉扎 gitlink 前进了 2 个研究补丁提交。这证明当前源码可对应两套补丁序列，不等于发行签名或外部受信任构建证明。

### 构建与原生测试

- `pnpm quality:fast` 通过：Core 20 个测试文件、130/130，类型检查、脚本门、仓库合同和构建均通过；最终 bytecode runtime verifier self-test 为 22/22。
- V8 `v8_unittests` 重编译完成 1,385 steps；`AegisBytecodeShadowTest` 3/3、`//v8:v8_base_without_compiler` 与 `//v8/test/unittests:v8_unittests` 的 GN check 2/2 通过。3 个单测只覆盖签名确定性、顺序和长度分离，trace gate/schema/cap 由下述真实四模式验证覆盖。
- Chromium `chrome` 与 Aegis 原生目标构建成功；`aegis_unittests` 77/77、`aegis_browser_unittests` 44/44 通过。

### 身份绑定运行

- 最终权威报告 `.artifacts/runtime/bytecode-shadow-trace-liveness-final-v4-2026-08-27.json` 为 23/23；SHA-256 为 `ca5e93494610ebdd6a7248d066845184e10b1e7790d14c7384dddfb4679dbe43`。验证器运行前后稳定 SHA-256 为 `0735979d8fe746431fd820d33cdc906549b4e13fe06c6eccd647c2b1aadc65e1`；实际 fixture 均绑定内容摘要，原始 trace、metadata、日志、页面源码、URL 和函数名不进入报告。前三个同名前缀的 v1/v2/v3 报告分别保留 CDP 引导失败和 1 MiB metadata buffer 丢失的诊断事实，未被覆盖，也不计作通过证据。
- OFF 全程 0 条 shadow 记录；ON 得到 11 条合法 `observed`；CANARY 以 `max-bytes=1` 得到 15/15 条 `skipped-too-large`；STRESS 得到 1,022 条，其中一个 renderer 精确达到每进程 1,000 条硬上限。ON/CANARY/STRESS 的全部发射进程均由两次 `SystemInfo.getProcessInfo` 快照映射为 renderer，未知或非 renderer 发射者为 0。
- 四种模式都使用 32 MiB 有界 `recordUntilFull` 专用 trace，`dataLossOccurred=false`。反压校准证明 126,000 bytes 固定合成同步写入在 holder 释放前无法完成且转发为 0，释放后完整转发；STRESS 两阶段页面在 holder 仍未读取、未转发、父进程未消费 Chromium stderr 时完成。
- 四种模式的新 crash、profile crash、fatal signal、SIGKILL 强杀和残留进程均为 0，均收到完整 `close` 且最终退出码为 0。运行前后身份绑定稳定，manifest SHA-256 为 `895e4ad2bc2fe40b02458aa459e9e228b120e0bc5aa55c715e0dfd7f217a48ed`，App tree SHA-256 为 `724c802660785af64bc7de7597aea2ebf64a0e5bc49d7e3a92496a2b9df04819`。身份仍是 `diagnostic-only` / `cooperative-local-workflow`，`trustedBuildAttestation=false`、`release_eligible=false`；运行通过不改变 **No-Go**。

### 公开 validation 与 claims 检查

- 公开 validation 仅评估 4 个合成样本：precision=1、recall=1、FPR=0。该结果只能证明当前工具链对已知样例的行为，不能外推真实准确率；public holdout 未评估，`--final` 仍闭锁。
- AST 分析器在这 4 个合成样本上的 p95 为 `3.059833 ms`。这是离线分析器样例耗时，不是 Chromium 页面开销、V8 shadow 开销或性能门通过证据。
- current gate report 有 25 项 claim 失败，`claimsComplete=false`、`authorizationEligible=false`。即使未来 claims 全过，该检查器也只能给 `eligibility=observe-only`，不能授权发布或阻断。
