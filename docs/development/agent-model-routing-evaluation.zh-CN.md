# Agent 模型与 effort 对照评估

## 目的与证据边界

验证 TypeSafe 快筛后选择模型、推理 effort 和输出预算，是否在保持任务正确性的前提下降低总成本。代码接通、单测通过、模型变便宜，均不能证明实际省 token 或省钱。

`apps/browser/scripts/evaluate-agent-model-routing.mjs` 是离线配对核算器：不调用 API，不生成正确性标签，不修改浏览器配置，不自动发布。报告中的 `releaseEligible` 始终为 `false`。真实浏览器调用记录、独立验收标签及样本充分性需另外审核。

## 实验步骤

1. 冻结至少 100 个任务，覆盖简单提取、搜索、长上下文、多步工具调用、复杂推理和失败恢复。预先写出验收条件，保存 fixture 与数据集 SHA-256。样本数量只是起点，按错误率和业务容忍度决定是否需要扩充。
2. 使用同一个浏览器提交、权限策略和执行预算修订号。每个任务至少重复 3 次，各运行 `fixed_high`、`fixed_low`、`auto` 三组，随机交错组别顺序。高低档都固定模型、effort 和预算；自动组使用同一个冻结模型目录。
3. 使用独立的任务状态和可恢复的测试环境，避免上一次运行的页面、购物车或文件副作用污染下一次。记录缓存命中；冷缓存和热缓存实验分别运行，不能混为路由收益。
4. 采集每次实际发送的生成请求及 TypeSafe 请求，包括失败、重试和回退。记录实际模型、effort、用量与任务创建时的价格快照。网络错误未返回 usage 时保留 `null`，不能据此断言服务商没有计费。
5. 由独立验收程序或不知道组别的评审者标注 `correct`。`completed` 不等于正确；无法判定用 `null`。失败或取消不能标注为正确，且不得从配对任务集中删掉。
6. 归一化为下面的输入，运行核算器，检查标签覆盖率、成本完整率和配对样本完整性，再审查正确率、回退率、延迟、总成本及每个正确任务的成本。

运行方式（输出文件必须尚不存在）：

```sh
node apps/browser/scripts/evaluate-agent-model-routing.mjs input.json report.json
```

## 输入契约 v1

所有字段必填；未知用量、价格或正确性使用 `null`。额外字段拒绝，防止将 prompt、密钥或页面内容混入核算文件。这个白名单只控制字段，导入者仍须确保字符串字段不包含敏感内容。

```json
{
  "manifest": {
    "schemaVersion": 1,
    "datasetId": "routing-pilot-v1",
    "datasetSha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "browserRevision": "git-sha",
    "policyRevision": "policy-v1",
    "budgetRevision": "budget-v1",
    "cases": [
      {"caseId": "extract-001", "fixtureSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    ],
    "repeats": 1
  },
  "records": [
    {
      "taskId": "fixed-high-extract-001-0",
      "caseId": "extract-001",
      "fixtureSha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "repeat": 0,
      "arm": "fixed_high",
      "status": "completed",
      "correct": null,
      "latencyMs": 1500,
      "fallbackUsed": false,
      "attempts": [
        {
          "kind": "generation",
          "model": "configured-model-id",
          "effort": "high",
          "inputTokens": 1000,
          "cachedInputTokens": 200,
          "outputTokens": 300,
          "reasoningTokens": 100,
          "prices": {
            "inputMicrousdPerMillion": null,
            "cachedInputMicrousdPerMillion": null,
            "outputMicrousdPerMillion": null
          }
        }
      ]
    }
  ]
}
```

以上仅展示一个记录的结构，数值为合成示例，不是实测或报价。运行时必须补齐每个 `caseId × repeat × arm`：本例缺少 `fixed_low` 和 `auto`，会被拒绝。每个 `taskId` 必须唯一，fixture 哈希必须与清单一致。核算器检查声明的一致性，不读取 fixture 内容，也不能验证声明的浏览器版本、配置和哈希来自真实实验；验收者必须保留原始实验材料。

- `kind`：`generation` 或 `typesafe`。TypeSafe 请求也是独立 attempt，不得隐去其开销。
- `model`：实际使用的模型；TypeSafe 失败且未返回模型版本时允许空字符串，不能因此删除该次请求。
- `effort`：记录实际发出的值，未发送填空字符串。契约可以接收多个供应商的 effort 枚举，并不表示任意 GPT 模型均支持这些值。
- `status`：`completed`、`failed` 或 `cancelled`。`correct` 只能由独立验收提供。
- 价格单位：每百万 token 的微美元，即 1 美元/百万 token 填 `1000000`。普通输入、缓存输入和输出分别计价。
- `cachedInputTokens` 是 `inputTokens` 的子集；`reasoningTokens` 是 `outputTokens` 的子集，不能额外加收一次输出费用。
- `fallbackUsed=true` 至少需两个生成 attempt。没有模型请求的原生任务保留在正确率和延迟样本中，但不稀释生成回退率。
- `attempts=[]` 仅适用于确实未发送任何计费请求的任务；不能用空列表表示丢失的调用日志。发生调用但未收到 usage，应保留 attempt 并填 `null`。

浏览器任务详情提供的观测 JSON 使用持久化字段命名，需手动归一化：`input_tokens` → `inputTokens`、`cached_input_tokens` → `cachedInputTokens`、`output_tokens` → `outputTokens`、`reasoning_tokens` → `reasoningTokens`，`prices.input/cached_input/output` 分别映射到三种价格字段。非空数字字符串需验证后转换为安全整数；`null` 保持不变。核算器不接收原始观测中的 `phase`、`succeeded` 和单次 `latency_ms`，任务端到端 `latencyMs` 由实验计时获得，不能用模型耗时之和替代。`taskId`、fixture、组别和独立正确性标签由实验记录补充；现阶段没有自动批量 benchmark runner。

归一化前检查 `attempts_complete`，为 false 的旧任务不能充当完整成本证据。每个 `completed=false` 的占位 attempt 必须保留，所有用量按 `null` 导入；不得删除占位后把剩余列表作为全量。`observation_id` 用于原始材料中的逐次核对，不作为正确性标签。任务恢复不能补出供应商未返回的用量。

快筛发生在任务创建前，独立的“未关联任务的快筛记录”保存这部分失败或取消记录；实验不得仅从成功创建的任务采样。未创建任务时可将路由 UUID 用作核算记录的 `taskId`，映射到原本的 case/repeat/arm，最终状态由实验实际结果确定。成功关联任务后，快筛调用由任务记录统计一次，不再把关联的独立记录重复相加。历史导出有容量边界，实验期间应及时留存原始记录，而非依赖浏览器作为长期账单档案。

## 报告与验收

| 输出 | 口径 |
| --- | --- |
| correctness | 正确数 / 已独立判定数，同时报告 unjudged；缺标签时不输出组间正确率差值 |
| fallbackRate | 发生生成模型回退的任务 / 发起生成请求的任务 |
| latencyMs | 所有任务端到端耗时的 p50、p95、p99，采用 nearest-rank 分位数；包含 TypeSafe 与失败时间 |
| tokens | 各类已知 token 小计与未知 attempt 数；reasoning 和 cached 是子集，不再相加 |
| knownCostUsd | 可计算 attempt 的成本小计；不是总成本 |
| totalCostUsd | 任一 attempt 成本未知则为 null |
| costPerCorrectTaskUsd | 所有任务总成本 / 正确任务数；成本或标签不完整、没有正确任务时为 null |
| comparisons | auto 相对各基线的正确率差值（小数，-0.02 表示下降 2 个百分点）、总成本和每个正确任务成本相对变化、p95 延迟相对变化 |

成本计算为 `(input − cached) × 普通输入价 + cached × 缓存输入价 + output × 输出价`，按百万 token 和微美元换算。缓存用量未知且两种输入单价不同时，成本保持未知。失败调用的已知用量照常计费。TypeSafe 没有价格快照时，整体成本仍不完整。

建议先沿用试点阈值：相对固定高档正确率下降不超过 2 个百分点、p95 增长不超过 20%、生成回退率不超过 10%，且每个正确任务成本不得上升。阈值应在查看结果前冻结；核算器不会自动作出上线判定，也没有实现置信区间或显著性检验。对关键任务需要单独设定正确性约束，不能由普通任务的收益抵消。

上线结论至少需要：完整配对样本、完整且独立的标签、包含 TypeSafe/重试/回退的计费证据、真实浏览器验证，以及满足预先确定的质量和成本阈值。没有真实实验时，结论只能是“实现和离线核算已就绪，节省效果未验证”。
