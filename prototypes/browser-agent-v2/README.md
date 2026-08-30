# Aegis Browser Agent v2 原型工作区

该目录只用于 P0–P4 隔离比较，不是正式浏览器运行时。所有任务必须从空白页或 Harness 指定
入口开始，使用本次 run 的独立 Profile，并只访问本地 fixture 或显式公开只读 allowlist。

## 当前范围

- M0：版本、许可证、默认外联和禁止能力已锁定。
- M1：统一场景、事件、断言、脱敏、隔离 Profile 和 HTTPS fixture。
- P0：Playwright MCP 确定性基线；不接模型。
- P1–P3：只有通过安全前置且由进程环境提供开发模型密钥后才能运行。
- P4：独立 Chromium Native Hybrid Spike，需在 M2 数据形成后开始。

## Provider / model 配置

产品和原型都不写死 provider 或模型，也不设置隐藏默认值。用户在每次运行时选择：

- `AEGIS_V2_PROVIDER`：当前支持的 API 格式为 `openai`、`anthropic`、`gemini`；
- `AEGIS_V2_MODEL`：用户填写的模型标识；
- `AEGIS_V2_BASE_URL`：可选的兼容 API 地址，远端必须使用 HTTPS。

密钥变量由 provider 映射为 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY` 或 `GOOGLE_API_KEY`，启动器
只向 adapter 传递所选 provider 对应的一个密钥。单次 P0–P4 对比组会锁定当次选择作为控制变量；
这不是产品默认值，下一组和最终用户都可以重新选择。

## 本地验证

```bash
cd prototypes/browser-agent-v2
npm test
```

测试产物只写入仓库根目录被忽略的 `.artifacts/aegis-agent-v2-prototypes/`。不要在此目录创建
`.env`；模型密钥只能在运行命令的当前进程环境中提供。
