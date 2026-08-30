# Aegis Browser Agent v2 原型工作区

该目录只用于 P0–P4 隔离比较，不是正式浏览器运行时。所有任务必须从空白页或 Harness 指定
入口开始，使用本次 run 的独立 Profile，并只访问本地 fixture 或显式公开只读 allowlist。

## 当前范围

- M0：版本、许可证、默认外联和禁止能力已锁定。
- M1：统一场景、事件、断言、脱敏、隔离 Profile 和 HTTPS fixture。
- P0：Playwright MCP 确定性基线；不接模型。
- P1：Browser Use 自主候选；只在隔离 Profile 和 fixture 上运行。
- P2：Stagehand 受控语义动作候选；`plannerAutonomy=false`，不能作为自主内核结论。
- P3：Skyvern 因默认云依赖、遥测、代码执行面和 AGPL 服务边界被停止。
- P4：独立 Chromium Native Hybrid Spike，只复用 v1 安全与原生工具资产。

## Provider / model 配置

产品和原型都不写死 provider 或模型，也不设置隐藏默认值。用户在每次运行时选择：

- `AEGIS_V2_PROVIDER`：当前支持的 API 格式为 `openai`、`anthropic`、`gemini`；
- `AEGIS_V2_MODEL`：用户填写的模型标识；
- `AEGIS_V2_BASE_URL`：可选的兼容 API 地址，远端必须使用 HTTPS。

密钥变量由 provider 映射为 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY` 或 `GOOGLE_API_KEY`，启动器
只向 adapter 传递所选 provider 对应的一个密钥。单次 P0–P4 对比组会锁定当次选择作为控制变量；
这不是产品默认值，下一组和最终用户都可以重新选择。

数值 loopback 的 OpenAI-compatible 地址可不提供云密钥。本次固定对照模型为
`mlx-community/Qwen3-1.7B-4bit` revision
`3b1b1768f8f8cf8351c712464f906e86c2b8269e`；模型目录和 MLX 虚拟环境均被忽略，不进入仓库。

## 本地验证

```bash
cd prototypes/browser-agent-v2
npm test
```

已配置本地或云模型后可运行：

```bash
npm run p1:agent -- E0
npm run p2:agent -- E2
npm run m2:smoke
AEGIS_M2_CANDIDATES=p2 npm run m2:matrix
```

本次 M2 结果：P1 smoke 6/12，E0 0/3、E8 0/3，因此未进入 10 轮；P2 smoke 9/9，
随后 10 轮 E1/E2/E8 矩阵 30/30。P2 数据只证明语义动作层稳定，不证明空白页自主规划。

测试产物只写入仓库根目录被忽略的 `.artifacts/aegis-agent-v2-prototypes/`。不要在此目录创建
`.env`；模型密钥只能在运行命令的当前进程环境中提供。
