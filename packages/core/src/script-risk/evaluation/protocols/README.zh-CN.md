# Script Risk blind-v1 研究协议

`blind-v1` 只用于本地操作员盲化研究：预测程序读取源码但不读取真实标签，预测文件
封存后，评分程序才连接标签。它不能证明样本、标签或操作员彼此独立，因此固定为
`operator-blinded-local`，不是 `independent-sealed test`，也不授权发布或页面阻断。

## 可重复流程

1. 构建 AST analyzer bundle 后冻结候选：

   ```sh
   node packages/core/scripts/freeze-script-risk-candidate.mjs \
     --candidate-id <candidate-id> \
     --output .research-data/script-risk/<run>/candidate.json
   ```

   候选锁同时绑定 analyzer bundle、`corpus-eval.mjs` 分类规则、Clopper-Pearson
   置信界实现、协议、`pnpm-lock.yaml`、Git commit/tree/dirty 指纹、Node 和
   TypeScript 身份。候选锁只有
   普通 SHA-256 完整性摘要，没有外部签名或独立见证。

2. 对公开 pilot 先用 acquisition 工具取得并复核 pinned 字节，再生成无标签 envelope：

   ```sh
   node packages/core/scripts/bridge-script-risk-public-pilot.mjs prepare \
     --candidate .research-data/script-risk/<run>/candidate.json \
     --receipt .artifacts/research/script-risk/<acquisition>.json \
     --source-root .research-data/script-risk/miner-capability-public-v1 \
     --envelope-id <envelope-id> \
     --output .research-data/script-risk/<run>/unlabelled.json
   ```

   `prepare` 会重建 acquisition plan，并再次核对 receipt、文件长度和 SHA-256。公开定义
   中的原始 sampleId 会被候选绑定的伪名替换，真实标签不会进入 prediction envelope；
   definition、plan 和 receipt 摘要会作为 public/unsealed provenance 一同绑定。

3. 由不含真实标签的 envelope 生成预测：

   ```sh
   node packages/core/scripts/predict-script-risk-blind.mjs \
     --candidate .research-data/script-risk/<run>/candidate.json \
     --input .research-data/script-risk/<run>/unlabelled.json \
     --output .research-data/script-risk/<run>/predictions.json
   ```

   一个 case 使用稳定 `sampleId`，并可包含多个文件：

   ```json
   {
     "sampleId": "case-001",
     "contentAddress": "sha256:<bundle-digest>",
     "files": [
       {
         "path": "src/worker.js",
         "sha256": "<file-digest>",
         "byteLength": 123,
         "sourceBase64": "<canonical-base64>"
       }
     ]
   }
   ```

   `files` 必须按规范相对路径排序，不能含符号链接或路径穿越。每个 case 只进入一个
   有时间、旧生代、新生代和栈内存上限的 worker；worker 只调用冻结的 AST analyzer，
   不执行源码。全部文件解析完成后才聚合信号。任何超时、资源错误、截断、解析失败或
   摘要不符都会终止整次预测，且不生成输出。

4. 预测文件已经落盘后，用 `reveal` 再次核对 plan、receipt、本地字节、输入和预测，
   然后创建绑定该 `predictionDigestSha256` 的 label envelope，再评分：

   ```sh
   node packages/core/scripts/bridge-script-risk-public-pilot.mjs reveal \
     --candidate .research-data/script-risk/<run>/candidate.json \
     --receipt .artifacts/research/script-risk/<acquisition>.json \
     --source-root .research-data/script-risk/miner-capability-public-v1 \
     --input .research-data/script-risk/<run>/unlabelled.json \
     --predictions .research-data/script-risk/<run>/predictions.json \
     --output .research-data/script-risk/<run>/labels.json
   ```

   ```sh
   node packages/core/scripts/score-script-risk-blind.mjs \
     --candidate .research-data/script-risk/<run>/candidate.json \
     --input .research-data/script-risk/<run>/unlabelled.json \
     --predictions .research-data/script-risk/<run>/predictions.json \
     --labels .research-data/script-risk/<run>/labels.json \
     --output .research-data/script-risk/<run>/score.json
   ```

   正负类由协议的 `positiveLabel` 与 `negativeLabel` 声明；当前版本是
   `mining-capable` 和 `benign-control`，评分代码不硬编码这两个值。评分报告还输出
   95% Clopper-Pearson 单侧 recall 下界和 FPR 上界；如果对应正类或负类分母为零，
   该置信界明确为 `null`。

## 闭锁边界

- freeze、prepare、predict、reveal 和 score 都拒绝 `--final`。
- 所有输出使用排他创建，已有文件不会被覆盖。
- 预测输出不包含源码或真实标签；评分报告可以包含连接后的真实标签。
- 协议、候选、输入、预测与标签均有严格 schema 和内容摘要，但本地操作员仍可能同时
  控制候选与评测材料，所以摘要不能替代独立 sealed test。
- 所有结果固定 `releaseEligible=false`、`enforcementAuthorized=false` 和
  `independentSealVerified=false`。
