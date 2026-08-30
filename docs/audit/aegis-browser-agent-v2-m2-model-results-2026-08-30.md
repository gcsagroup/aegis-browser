# Aegis Browser Agent v2 M2 模型原型结果

- 日期：2026-08-30
- 范围：P1 Browser Use、P2 Stagehand；本地 fixture、独立 Profile
- 结论：**P1 No-Go；P2 仅作为语义动作层候选，不是自主内核**

## 控制变量

| 项目 | 固定值 |
|---|---|
| API 格式 | OpenAI-compatible，数值 loopback |
| 推理服务 | `mlx-lm==0.31.3` |
| 模型 | `mlx-community/Qwen3-1.7B-4bit` |
| revision | `3b1b1768f8f8cf8351c712464f906e86c2b8269e` |
| 权重大小 | `968080210` bytes |
| 权重 SHA-256 | `0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f` |
| 模型代码 | 禁止；目录中无 `.py` 或可执行文件 |
| Profile | 每次运行独立，未连接日常 Profile |
| 浏览器网络 | 仅本次 fixture origin；模型流量仅 `127.0.0.1:18080` |

provider、model 和 base URL 都由运行时环境选择。上表是本轮评测控制变量，不是产品默认值。

## Smoke

统一执行 3 轮 E0、E1、E2、E8；P2 不支持 E0，因为本原型刻意没有自主 planner。

| 候选 | 结果 | 关键结论 |
|---|---:|---|
| P1 Browser Use 0.13.8 | 6/12 | E1 3/3、E2 3/3；E0 0/3、E8 0/3 |
| P2 Stagehand 4.0.2 | 9/9 | E1/E2/E8 各 3/3；`plannerAutonomy=false` |

P1 在 E0 能识别目标按钮，但出现重复导航、错误元素索引和结构化输出截断。加强本地模型的
JSON schema 格式提示后仍失败。E8 没有发生跨 origin 或残留控制进程，但无法完成最终浏览器
断言。按计划停止扩展，不通过放宽安全、提高 step 或为特定页面硬编码动作来追分。

Smoke 汇总证据：
`.artifacts/aegis-agent-v2-prototypes/20260830T022826655Z-m2-model-matrix-m2-221c383d/metrics.json`。

## 10 轮矩阵

只有通过 smoke 的 P2 进入矩阵。E1、E2、E8 各执行 10 次：

- 完成率：30/30，100%；
- 全部浏览器最终状态断言通过；
- 全部运行无残留浏览器进程；
- 30/30 的目的地仅为本次 fixture 和本机模型端口；
- 总耗时 178720 ms；单次中位数 6364 ms；
- E1/E2/E8 中位数分别为 4982/7079/6364 ms。

矩阵汇总证据：
`.artifacts/aegis-agent-v2-prototypes/20260830T023628597Z-m2-model-matrix-m2-cb18b21a/metrics.json`。

## 硬门判断

- P1：E0 0/3，已无法满足 E0 10/10，**不进入完整矩阵，不具备正式内核资格**。
- P2：语义操作矩阵通过，但不负责 E0、自主发现或规划，**不能单独满足自主原型退出条件**。
- 安全：本轮未观察到跨 origin、日常 Profile、下载、秘密、残留 session 或云端 Profile 流量。
- M2：实验与失败原因已完整复现，但“至少一个外部自主候选成立”的架构门未通过。

## 采用建议

- 借鉴 P2 的 schema 驱动 DOM 观察和单步语义动作接口。
- 拒绝把 Browser Use 或 Stagehand 直接作为 Chromium 正式控制平面。
- Planner、Workspace、document binding、审批和 Stop 必须由 Aegis Native Runtime 掌权。
