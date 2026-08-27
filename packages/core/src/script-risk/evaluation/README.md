# Script Risk 研究评测协议

本目录只用于离线研究评测，不进入浏览器页面执行路径，也不授权阻断。
评测工具不联网、不下载恶意样本、不执行 fixture 源码；本地源码只作为文本交给
TypeScript AST 分析器。可接受的语料形态只有：

- 项目自建的 `synthetic-fixture`；
- 只有 SHA-256 和标签证据、没有本地样本的 `metadata-only`。

## 数据约束

`fixtures/corpus.json` 为可审计定义，生成后的清单为每条样本保留：内容地址、
来源、许可证、标签证据、站点组、家族组、采集时间组和混淆层级。相同内容、
站点、家族或时间组会先合并成连通分量，再整体分配到 train、validation 或
test，避免同源变体跨集合泄漏。

仓库内的 test 只是 `deterministic-public-holdout`：`corpus.json` 公开 seed、样本和
完整标签，协议输出也公开 manifest 与 split assignment。因此 SHA-256 只能校验
内容和分组结果是否被篡改，不能证明样本曾被盲化隔离，也不能把公开 test 升格为
sealed/final evaluation。输出固定为 `sealIsolationVerified=false`、
`finalEvaluationEligible=false`；`--final` 会闭锁失败，且不接受 expected seal。
真正的 sealed test 必须由仓库外的独立持有方保管样本、标签和评测权限，本工具
目前没有这样的可信 provider，不能产生相应授权。

## 运行

先构建 Node-only AST 分析器：

```sh
pnpm --filter @gcsa-aegis/core build
```

运行 validation，并同时保存完整清单与分组协议：

```sh
node packages/core/scripts/evaluate-script-risk-corpus.mjs \
  --split validation \
  --protocol-output /tmp/gcsa-script-risk-protocol.json \
  --report-output /tmp/gcsa-script-risk-validation.json
```

报告固定包含混淆矩阵、precision、recall、FPR、各混淆层结果以及解析耗时的
均值、p50、p95、p99 和最大值。合成语料结果只能证明工具链与已声明样例上的
行为，不能外推真实网页流行率、破站率或生产误报率，报告因此始终为
`research-only`、`releaseEligible=false` 和 `enforcementAuthorized=false`。
报告中的 `publicHoldout.integrityDigestSha256` 仅为公开内容完整性指纹，不是 seal。

## 研究准入门

研究证据必须由调用方明确提供；CLI 不采集、推导或补写证据，也不接受阈值
参数。输入文件必须提供预先固定的 SHA-256，CLI 对读取的同一组字节核验后才会
解析。缺失证据会生成 `observe-only` 报告并以状态码 `2` 退出；非法 JSON、未知
字段、非法类型、非有限数值或写入失败以状态码 `1` 退出。报告只允许写到仓库
`.artifacts` 下的显式输出根目录，拒绝路径逃逸、符号链接和覆盖已有文件：

```sh
pnpm --filter @gcsa-aegis/core build
pnpm script-risk:evaluate-gates -- \
  --evidence /absolute/path/to/evidence.json \
  --expected-evidence-sha256 <64位小写SHA-256> \
  --output-root "$PWD/.artifacts/research/script-risk" \
  --report-output gate-report.json
```

这个 evaluator 只检查调用方自报 claims 的完整性和数值关系，不会从混淆矩阵、
原始运行记录或签名审计材料重算与验证结论。因此报告固定标记
`trustLevel=unverified-claims`、`authorizationEligible=false` 和
`enforcementAuthorized=false`。状态码 `0` 只表示 claims 全部通过，不是可信发布
结论；CLI 始终保持 `currentMode=observe-only`、`wouldBlock=false`，绝不授权页面
阻断。
