# Aegis Browser Agent v2 原型工作区

该目录只用于 P0–P4 隔离比较，不是正式浏览器运行时。所有任务必须从空白页或 Harness 指定
入口开始，使用本次 run 的独立 Profile，并只访问本地 fixture 或显式公开只读 allowlist。

## 当前范围

- M0：版本、许可证、默认外联和禁止能力已锁定。
- M1：统一场景、事件、断言、脱敏、隔离 Profile 和 HTTPS fixture。
- P0：Playwright MCP 确定性基线；不接模型。
- P1–P3：只有通过安全前置且由进程环境提供开发模型密钥后才能运行。
- P4：独立 Chromium Native Hybrid Spike，需在 M2 数据形成后开始。

## 本地验证

```bash
cd prototypes/browser-agent-v2
npm test
```

测试产物只写入仓库根目录被忽略的 `.artifacts/aegis-agent-v2-prototypes/`。不要在此目录创建
`.env`；模型密钥只能在运行命令的当前进程环境中提供。
