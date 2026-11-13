# iOS Access：受阻站点回归套件（接 #97）

日期：2026-11-10。状态：设计稿；**未实施**。挂靠 PR [#97](https://github.com/gcsagroup/aegis-browser/pull/97) 的 iOS 精确主机恢复线，不替代 U/K/D。

**行为依据：** [精确主机存储 SDD](ios-exact-host-store-sdd.zh-CN.md) R7、[实现方案](ios-exact-host-recovery-implementation.zh-CN.md)、[本地 V2Ray 导入](../ios-access-local-v2ray-config-NOTES.md)、[阶段一证据](../ios-access-product-phase1-evidence-NOTES.md)。

## 1. 目的与边界

### 要证明什么

在**已有**进程内固定内核 + 本地 Reality Vision 节点可用时，对一批「直连失败、经本服务代理后主框架可加载」的公开站点做抽样回归，发现出口/路由/WebKit 回归，而不是重新证明 U 或 K。

### 不证明什么

| 非目标 | 原因 |
| --- | --- |
| 替代 U | U 用可控入口与票据矩阵，不依赖公网站点 |
| 替代 K / D | K 要 CONNECT host + slice 摘要 + 出口响应关联；D 要真机同摘要 |
| 默认 CI / required checks 门 | 公网波动、限流、挑战页会使门闪红 |
| 宣称「翻墙能力」或发行完成 | 本套件是工程回归，不是产品宣传或商店证据 |
| 把页面 HTML 金标化 | DOM/CDN/A-B 极易漂移 |

### 与 #97 验收的关系

```text
U（模拟器逻辑/WebKit 可控入口）     —— 默认门，已有
K（进程内内核 + 单次真实出口）       —— 有节点才跑；正式收据
D（真机复测 K）                       —— 另授权
R（本文件：受阻站点回归，opt-in）     —— U+K 绿之后的补充覆盖
```

R 的通过**不能**写成 U/K/D PASS，也不能单独放行合并。

## 2. 站点语料

### 2.1 类别（写入每条记录，禁止混算）

| 类 | 含义 | 期望（在节点健康时） |
| --- | --- | --- |
| `direct_fail_proxy_ok` | 本机直连主框架失败（DNS/超时/重置等可恢复网络失败），经 Access 后主框架有可信进度 | 主回归正例 |
| `cf_challenge` | 直连或代理后出现 Cloudflare / 类似人机挑战 | 记 `CHALLENGE`，**不算**产品 FAIL，除非此前金标为 `proxy_ok` 且挑战是新增回归 |
| `geo_or_auth` | 地区墙、登录墙、应用商店墙 | 记 `BLOCKED_EXPECTED` |
| `unstable` | 历史抖动大 | 只进 nightly 全量，不进金标 |

「被 CFW」在本方案中拆成可观测类，不假设 100 站同质；录入时由操作者标定初始类，首跑校准后再冻结。

### 2.2 名单存放（永不入库）

| 路径 | 角色 |
| --- | --- |
| `.local/access-service/regression/sites.jsonl` | 操作者名单（gitignore，与节点同树） |
| `.local/access-service/regression/gold-ids.txt` | 金标 ID 子集（建议 5–10） |
| `.local/access-service/test-reality-vision.json` | 既有节点 flat JSON |
| `.local/access-service/ENABLE_LIVE` | 既有 live 开关 |

`sites.jsonl` 每行一个 JSON 对象，字段最小集：

```json
{
  "id": "ex-001",
  "url": "https://example.invalid/",
  "host": "example.invalid",
  "class": "direct_fail_proxy_ok",
  "method": "GET",
  "notes": "optional operator note"
}
```

约束：

- 只允许 `http`/`https`；默认只跑 `GET`（与 SDD：POST/PATCH 不自动重发一致）。
- `host` 必须是规范化精确 host，与 exact-host 键一致；禁止把名单写成后缀规则。
- 不收录需登录才能判定的业务流程作为金标正例。
- 仓库可提交**空模板**与字段说明；真实 URL 列表不进 git、不进 PR diff、不进 CI 缓存制品。

### 2.3 规模分层

| 层 | 规模 | 何时跑 | 失败语义 |
| --- | --- | --- | --- |
| Smoke | 1–2 站 | 与 `AccessEmbeddedCoreLiveTests` 同条件的开发机冒烟 | 失败 → 查节点/内核，不扩名单 |
| Gold | 5–10 站 | 操作者在 U+K 绿后主动跑；可挂 nightly opt-in | `direct_fail_proxy_ok` 的意外失败 → 调查 |
| Full | ≤100 站 | nightly / 发版前手工；限时与并发有上限 | 默认汇总，不单站阻断；超阈值再人工看 |

建议 Full 并发 ≤3、单站预算 45s、整包墙钟 90min；超限记 `TIMEOUT`。

## 3. 单站判定合同

对每个 `id` 产出一条脱敏结果，不保存 Cookie、完整 HTML、节点密钥。

### 3.1 步骤（对齐产品路径，不做 URLSession 直连冒充成功）

1. **直连基线（可选但金标建议有）：** 同一模拟器/设备上，**不**经 Access 打开该 URL；记录是否出现可恢复网络失败（或明确非网络失败）。
2. **Access 准备：** 复用产品发布器（进程内核心 + 本地节点）；15s 内就绪或明确失败。
3. **精确 host 绑定：** 仅该 host 的专用存储走代理；对照 host 不得误绑（抽检即可，不必每站双开）。
4. **一次重载：** 仅对该失败导航 GET 重载一次；断言主框架出现文档提交/标题/受控进度之一，**或**明确的挑战/地区墙类结果。
5. **失败关闭抽检（Gold 子集）：** 停内核或拔节点后，已绑定标签不得静默改走原连接（可与现有 fault 用例共用，不必 100 站各测一遍）。

### 3.2 结果枚举

| 结果 | 含义 | 是否算套件回归 FAIL |
| --- | --- | --- |
| `PROXY_OK` | 代理路径下主框架达到约定进度 | 否（正例） |
| `DIRECT_OK` | 直连已成功 | 金标若标为 `direct_fail_*` 则要重标定，不记产品 FAIL |
| `PREPARE_FAIL` | 入口/内核/节点未就绪 | **是**（基础设施） |
| `NAV_FAIL` | 代理就绪后主框架仍网络失败 | 金标 **是**；Full 记入统计 |
| `CHALLENGE` | CF / 人机挑战 | 否（除非金标历史为 `PROXY_OK`） |
| `BLOCKED_EXPECTED` | 地区/登录等预期墙 | 否 |
| `TIMEOUT` / `FLAKY` | 超时或已知不稳 | Full 默认否；Gold 连续两次 → 调查 |
| `NOT_RUN` | 无节点、无名单、未授权 live | 否 |

套件总判：

- `NOT_RUN`：缺输入（与 K 无节点同语义）。
- `FAIL`：任意 `PREPARE_FAIL`，或 Gold 中出现不可接受的 `NAV_FAIL`。
- `PASS_WITH_FINDINGS`：Gold 过，Full 有挑战/超时等发现。
- `PASS`：Gold 过且 Full 无意外 `NAV_FAIL`（或未跑 Full）。

## 4. 实现落点（接到现有工程）

不新建第二套编排器；复用 #97 已接线的发布器与协调器。

| 组件 | 职责 |
| --- | --- |
| `scripts/release/ios-access-blocked-site-regression.sh` | Opt-in 入口：预检节点/锁摘要/`ENABLE_LIVE`、读名单、调 xcodebuild 或 host 驱动、写证据 |
| `apps/ios/Tests/AccessKitTests/AccessBlockedSiteRegressionTests.swift`（或后续独立 Integration target） | 仅当环境开启时展开；默认发现列表**排除**全量 100，避免拖垮 `ios-access-tests.sh` |
| 现有 `AccessEmbeddedCoreLiveTests` | 保持 1 站级 live；R-Smoke 可委托它或共享 helper |
| `.artifacts/ios-access-regression/<run-id>/` | xcresult、`summary.json`、按站 `results.jsonl`（脱敏） |
| `docs/audit/evidence/ios-access-product-phase1/regression/` | 仅提交**索引模板**与操作说明；真实结果留 artifacts |

环境变量：

| 变量 | 含义 |
| --- | --- |
| `AEGIS_ACCESS_LOCAL_V2RAY_CONFIG` | 已有 |
| `AEGIS_ACCESS_LOCAL_V2RAY_LIVE` / `ENABLE_LIVE` | 已有 |
| `AEGIS_ACCESS_REGRESSION_SITES` | 覆盖名单路径 |
| `AEGIS_ACCESS_REGRESSION_TIER` | `smoke` / `gold` / `full` |
| `AEGIS_ACCESS_REGRESSION_ENABLE` | `1` 才展开回归测试类 |

默认 `ios-access-tests.sh` **不**设置 `AEGIS_ACCESS_REGRESSION_ENABLE`，因此 R 不进 U 门。

## 5. 证据最小集

每次跑写 `summary.json`：

- 候选 git SHA / dirty 摘要、App 构建身份、模拟器或设备 UDID、OS
- `embedded-core-lock.json` 的两个 slice SHA-256
- 节点来源路径**名**（不写内容）、tier、站点数
- 计数：`PROXY_OK` / `NAV_FAIL` / `CHALLENGE` / … / `NOT_RUN`
- 入口 `identity` / `generation`（若本次启动了产品发布器）

禁止写入：节点 UUID/公钥、Cookie、Authorization、完整敏感 URL query 中的 token。

## 6. 实施顺序（仍属 #97 后续，可另 commit）

1. **模板与 gitignore：** `sites.jsonl.example`、regression 目录说明；确认 `.local/access-service/` 已忽略。
2. **Runner 骨架：** 预检 → tier 过滤 → 调用现有 live 冒烟 → 写出 `NOT_RUN`/`PASS` 摘要（可先不跑 100）。
3. **Gold 驱动：** 5–10 站，走真实 WKWebView + 发布器；与 S1 同语义。
4. **Full 批处理：** 并发与超时；结果分类；不阻断 CI。
5. **文档回写：** 本文件状态改为「骨架已接线」；实现方案表增加 R 行；PR #97 说明注明 R 为补充、非合并门。
6. **D 之后：** 真机只复跑 Gold，不强制 Full 100。

## 7. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 名单政治/合规敏感 | 本地持有；PR/CI 零名单；审计只留计数 |
| CF 挑战误判失败 | 独立 `CHALLENGE`；金标单独标定 |
| 站点改版导致假红 | 断言进度信号而非字节金标；Full 允许 findings |
| 拖慢 U 门 | 默认发现排除；独立脚本 |
| 用直连 URLSession「验证出口」 | 禁止；必须经产品 CONNECT → 进程内 Dial |

## 8. 完成定义

- 设计被 #97 实现方案引用，且不把 R 写进 U/K/D 完成含义。
- 操作者按文档能在有节点的机器上跑通 `smoke` 与 `gold`，并得到脱敏 `summary.json`。
- `full` 可跑完或诚实 `TIMEOUT`/`NOT_RUN`，不污染 `ios-access-tests.sh` 退出码。

未完成 D、未提交名单、未改 required checks，均不阻塞本设计成立。
