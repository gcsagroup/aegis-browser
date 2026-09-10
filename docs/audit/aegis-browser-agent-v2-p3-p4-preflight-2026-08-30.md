# Aegis Browser Agent v2 P3/P4 前置报告

- 日期：2026-08-30
- P3：Skyvern `1.0.48`
- P4：Aegis Native Action Broker standalone C++ contract
- 状态：**P3 基础门完成；P4 合同门通过，但均未达到正式候选完成条件**

## P3 Skyvern

Skyvern 基础 CLI 已在独立 Python `3.13.9` venv 安装并运行 `--help`：

- 基础环境 26 个包，约 83 MiB；完整 `local` extra 还会引入 Playwright、数据库、云 SDK、
  secrets、文档处理、LLM 和服务端依赖。
- 基础 CLI 同时包含 Cloud 登录/API key、凭据、计划任务、workflow、server/UI/MCP 管理面。
- 默认配置仍是 `SKYVERN_TELEMETRY=true`、远端 PostHog、
  `SKYVERN_BASE_URL=https://api.skyvern.com`、`ENABLE_CODE_BLOCK=true` 和
  `DISABLE_CODE_BLOCK_EXECUTION=false`。
- 原型环境已强制反向设置这些开关；没有启动服务、创建 `.env`、登录云端或保存凭据。
- 许可证是 AGPL-3.0，只允许在本轮私有隔离评估中运行；正式 Aegis 不复制、链接或分发其代码。

在没有开发模型密钥时，安装完整 local 服务栈不会产生有效能力对比，反而扩大依赖和外联面。
因此 P3 暂停在基础门，不把“CLI 可启动”记为候选成功。

## P4 Native Action Broker 合同门

建立了不依赖 Chromium 的最小 C++20 合同原型，并用本机 `clang++` 的
`-Wall -Wextra -Werror` 编译和执行。12 个断言覆盖：

- E0：从 `about:blank` 主动导航，不要求预先打开目标页；
- 文档身份：导航后旧 DocumentRef 立即失效；
- E7：可信 Planner 可请求原生收藏夹，页面文本不能自行授予原生能力；
- E8：页面提示注入不能升级为上传、原生写入或最终交易；
- E9：未允许 origin 在导航提交前被拒绝；
- 最终购买始终要求用户接管；
- Profile 身份不匹配被拒绝；
- E11：Stop 清空文档租约，排队动作不能重放。

结果：12/12 通过，约 1.63 秒。二进制和运行证据只在 `.artifacts/` 保留。

## 证据边界

P4 当前只是独立合同门，`chromiumIntegrated=false`。它没有证明 Browser Process 集成、真实
WebContents/DocumentToken、BookmarkModel、tab group、模型循环、UI、崩溃恢复或 Chromium
browser test，因此 M3 尚未完成。下一阶段只有在 M2 的自主候选数据形成后，才值得创建独立
Chromium worktree 并做最小原生集成。
