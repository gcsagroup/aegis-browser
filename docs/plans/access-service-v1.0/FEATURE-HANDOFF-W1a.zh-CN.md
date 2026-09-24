# W1a 请求路由合同交接

日期：2026-09-24。范围：请求级多组路由的接口设计和独立可执行合同模型。行为权威仍是[冻结规范修订 4](spec.zh-CN.md)，交付门槛以 [DEV CI 指南](../../development/ci.zh-CN.md)为准。

## 来源与边界

- 起始 B：`7f74e0a4e971f91d08d90536e429aba7b82cf37d`，已刷新 `origin/develop`；当时 `origin/main == upstream/main == c1399852270c1bbce612dbea1558266d6fc57162`。
- 冻结候选前再次刷新并快进到 PR base `42f48b535f4ff0c302b6c4e98762fcee86495e1c`（#176 仅调整三份 README 排版）；设计引用的产品调用链没有变化。最终本地门仍在快进后的候选重新运行。
- 2026-09-25 对齐新 base：[Q 的 #177](https://github.com/quinn521/aegis-browser/pull/177) 已 squash 合入 `develop`，S=`43e4e55070d098986585034616029588a75e104d`。其合并前 H=`1f86a6e218c2bccebf2654c266a4d6e2ab0e2e37` 的固定 Chromium 回执记录 native 17 个目标/181 项、Chrome browser 56 项、Content 6 项通过；S 的 push CI `36039414436`（quality/quality-gate）与 `36039414451`（C++）均成功。H 的固定 Chromium 运行证据不能冒充 S 的浏览器运行，也不等于 W0 全部完成；Q 的 #177 描述仍标记 W0 open、G0 UNVERIFIED。本 PR 已将 S 纳入分支，最终 W1a 的 B/H/M 与检查另按新 base 核验。
- GitHub 实时回读确认 [#162](https://github.com/quinn521/aegis-browser/pull/162) 已合并，H=`4670c4dd5f24db61f38f102cc60475658e63554a`，S=`ca4e1b24c750746d6e20a83fa58f1d2500791d02`。旧架构/主 Handoff 的 Draft、BUILDING 文字属于历史快照。其窄范围 native/browser 证据不能转用于本 PR，也不代表 W0 完成。
- 本切片不修改生产 overlay、patch 或 transport；不重做 host 冲突拒绝。模型的多组正路径只验证拟议合同，生产的多组并存仍待 W1b。
- Q 独占 Chromium candidate/out/锁及共享开发计划、主 Handoff、验收台账。本任务没有写入该现场、运行 Ninja 或改变共享台账。
- W0 的明确完成回执尚未取得；W1b/W1c 生产接线继续受该前置门约束。Agent 模型路由仍为 DEFERRED。

## 可审查交付

1. [W1a 接口设计](w1a-request-routing-design.zh-CN.md)：现有符号与调用链、可信载体、注册/快照、池及缓存隔离、重启、认证缺口和后续 PR 切片。
2. [合同 fixture](w1a-fixtures/README.md)：独立 Node 模型及 unit/regression，测试所需的不可变输入、并存路径与拒绝路径。CI 的薄入口纳入现有 `ci:test`，不添加 required check。
3. 本交接：交付边界、复核命令与 W2 实验输入；不将模型 PASS 写入 A/PF 主行。

设计阶段显式选择 Astra/high，fixture 实现选择 Sol/xhigh，独立评审使用新上下文 Astra/high。任务负责人的运行时模型/effort 若未由运行时回执提供，不根据文档或自身推测补填。

## 复核与证据身份

最终 H、tree、独立 review、实际命令结果与托管 run/attempt 记录在本 PR 描述及本地忽略目录 `.artifacts/`，不在本文件制造自引用的最终 SHA。复核时必须从 Git 和 GitHub 重新读取：

```bash
git rev-parse HEAD HEAD^{tree} origin/develop
git diff --check
mise exec -- node --test scripts/ci/tests/w1a-request-routing-contract.test.mjs
mise exec -- node scripts/ci/run-quality.mjs \
  --scope full --base "$(git merge-base HEAD origin/develop)" \
  --report-dir ".artifacts/ci/local-$(git rev-parse --short HEAD)"
```

本地 full 必须绑定干净 H，`result=PASS` 且 `sourceStable=true`。托管 PR 检查绑定 M：记录 B/H/M、M 的两个父提交、workflow/event/run/attempt/check source。未合并时 S 为不适用，不记录假想的 push CI。base 前移、修复或 rebase 后重新评估证据。

模型运行不证明 Mojo 端点的安全性、实际 stream/pool/cache 行为、HTTP/SOCKS5 握手、浏览器回归、真实服务或 G0/G1。本任务未执行 Chromium 构建、受控外网服务、节点部署、收费 API、签名或安装包发布。完成本切片只允许记录 W1a 设计/合同准备，不能记录整个 W1 已完成。

## 给协调者的共享状态更新建议

- 在共享计划添加本 PR 的 W1a 链接，保留 W0 独立结论及其精确被测候选。
- A10/A11/A15/A16/A53/A76/A78/A108/A113/A115 与 PF01–PF03 可链接到本合同的场景输入；实现、浏览器运行和主行结果不因模型测试升级。
- W1b 开始前取得 Q 的完整 W0 回执，然后将本设计拟新增 API 逐点落实到固定 Chromium；同 PR 交付真实 unit 和入口 regression。
- W1c 必须另行证明旧连接与缓存不串用、Network Service 重启及 HTTP/SOCKS5 最小认证。源码 hook 或模拟凭据查询不能替代实际握手。

## 2026-09-24 新发现：canonical 尾点与生产入口

PR [#178](https://github.com/quinn521/aegis-browser/pull/178) 的旧 H=`eda9dfd156f823c88484e528e5b97928aab73571` 曾把模型输入称为 canonical，但模型实际接受尾点 `exactHost`，且已发布 `target.example` REJECT/PROXY 时，首次或 redirect 的 `https://target.example./` 会走 `native` 并可派发。修复前的直接 Node 回归为 29 项中 21 PASS、8 FAIL；修复后需以新 H 的直接/CI/full 和同一独立评审者复审为准，旧 CLEAR 不再足以覆盖该发现。配置原始 `exactHost`/本站 `topLevelSite` 拒绝尾点；请求只对**解析后仍有尾点**的目标或顶层网站在已发布快照/恢复约束下 fail closed，IPv4 单尾点等价输入的后续定界见下文；从未发布且无恢复约束时保留 native。此模型修复不证明生产入口已接通。

协调者还转述 Q 的固定 Chromium `Hceb6ead` netlog：缺 endpoint 的 frame prefetch 曾走 DIRECT，origin 收到 GET 并返回 HTTP 200，cache created 而非 cache hit。本切片未亲自复跑该现场，完整提交身份及实验记录以 Q 报告为准；生产旁路由 Q 修复。现有模型“已提交 PROXY 缺 endpoint 不退 native”的回归仍保留，但不能将其 PASS 当作真实 frame prefetch 或 G0 验收。

在 #177 合并前，Q 的对照报告还显示普通 canonical URL 在已发布代理策略、缺 endpoint 时走 DIRECT 并从 origin 收到 HTTP 200；尾点 URL 发布策略后的实际浏览器请求同样曾到达 origin。因此当时的生产失败范围包括普通文档子资源、尾点子资源与 frame prefetch，不能只按尾点规则故障收口。Q 后续将原因定位到提交前创建的 document factory 与文档身份激活时序，并在 #177 的固定 Chromium 候选验证了修复。该历史故障及其修复不改变本 PR 的证据边界：W1a 模型、独立复审和托管 CI 不替代 S 的浏览器验收，也不把 W0/G0 升级为通过。

同一独立评审者在后续 H=`ecb87f32998ec06eb1b8f182bd7c6205a9ec85f2` 发现 IPv4 单尾点边界：Node URL 将 `127.0.0.1.` 先归一为 `127.0.0.1`，旧模型因原始配置与请求混用检查而接受非规范本站规则、或使已发布快照的请求按非预期 native 派发。Q 随后用固定 Chromium 151 GURL 动态实验明确：配置原始 host/site 拒绝尾点或非 canonical 拼写；请求按解析后的 host/site 决策，IPv4 单尾点、`%2e` 与 `127.1.` 同 canonical IPv4 路由；DNS 尾点和 IPv4 双尾点仍保留并在已有快照/恢复约束下拒绝。从未发布快照且无恢复约束继续原生。F 仅修 Node 合同模型和本 W1a 文档；Q 的实验不是本模型执行的 Chromium 验收，仍以 Q 原始回执为准。旧 H 的 review/CI 不能转用到本次修复候选。

Q 给出的实验索引为 `/Volumes/ExternalSSD/repositories/access-ipv4-dot-diagnostic-18ldxaa3`；其 manifest 报告 compile/run 均 exit 0，`probe.cc` SHA-256 `18fb49cd6fc465b9e9cb8aded3411bf47c8b65cda98965dc2a6c2ba284e78ad3`，`result.log` SHA-256 `2d4b7500a12a7eee8907f4e23dc1e3bb78913e0fdc48c96b5b811d32a6883dee`。这些身份由 Q 转交，F 未亲自执行 Chromium probe；新 H 的模型、完整本地门和同评审者复审须另行记录。

## W2：仅整理实验输入

本轮未绑定受控 Linux 环境、执行负责人或真实服务配置，W2 执行保持 BLOCKED。以下输入齐备并获得相应执行授权后，才可按[架构实验协议](architecture-review-20260922.zh-CN.md#3-vision计量与额度的提前验证)开展实验：

| 输入 | 必须记录的内容 |
| --- | --- |
| 受控环境与责任 | 执行人、合法测试节点、网络与故障注入范围、停止/回收办法；秘密仅用引用标识 |
| 固定运行身份 | Xray commit、二进制 SHA-256、OS/kernel、入站/出站/flow、配置 hash、真实计量位置 |
| 拓扑与隔离 | endpoint/deployment/capacityGroup/trafficPool/failureDomain 映射，Profile/主体与短期凭据边界 |
| 预先冻结预算 | 目标字节口径、采样周期、计量延迟/误差、并发与缓冲导致的最大超额、资源上限 |
| 耐久与恢复 | 中心预留、节点累计结算/单调序号、journal/checkpoint、失联/崩溃/重启后的可恢复量与未知量 |
| 原始观察 | 长连接未结束时的计数、耗尽截断、kill/restart、失联恢复、实际 splice 与对照路径、关联 ID |

Stats API 轮询不等于数据面限额；预留余额不等于已消费字节；macOS 模型不证明 Linux Vision/splice。未得到真实结果前不申请或虚构 PASS，不部署节点，不调用收费服务。
