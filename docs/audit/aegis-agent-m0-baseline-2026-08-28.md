# Aegis Browser Agent v1 M0 基线与 Actor 集成结论

- 日期：2026-08-28
- 范围：macOS 桌面端；iOS 跳过；Android 后置
- 状态：M0 Go，本地开发与验证，不含推送、发布、正式签名或真实交易

## 结论

Chromium 151 的 Actor 可以作为 Aegis 自有执行层复用，但必须经过 Aegis
PolicyBroker，不能把通用 CDP、Glic UI 或 OptimizationGuide 模型调用暴露给模型。
Aegis 使用独立 feature、Profile 服务、任务状态机、工具白名单和模型传输；Actor
只接收已经绑定 Profile、tab、frame、DocumentToken、origin 与预算的页面动作。

M0 判定为 **Go**：Aegis Actor 路径不要求启用 Glic UI，不要求远程调试端口，且
模型出站由 Aegis 自己的结构化传输负责。普通 Profile 可创建服务，OTR、Guest 和
System Profile 拒绝创建。

## 隔离工作区

本轮没有在用户正在使用的两个 checkout 上开发：

- 根仓库实施分支：`codex/aegis-browser-agent-v1`
- 根仓库隔离路径：`<agent-repo-worktree>`
- Chromium 实施分支：`codex/aegis-browser-agent-v1-runtime`
- Chromium 隔离路径：`<agent-chromium-checkout>/src`
- Chromium 固定起点：`910672213c5fcd18167b5ee26f690cf0023415e6`
- V8 固定补丁 HEAD：`9c0b1f276ba116e8b25a55466207e6586b44be16`

用户原根仓库与 Chromium checkout 保持原位；本轮不执行 `git clean`、强制 reset、
自动 stash 或覆盖 overlay。实施期间原根仓库出现并行 iOS 工作，也没有被本轮读取后
回写或合并。

## Actor 复用边界

复用：

- ActorTask 生命周期、语义观察以及 navigate/click/type/select/scroll/drag/wait。
- 用户暂停、接管、取消与受控 tab 释放。
- 登录、表单与 OTP 的受保护动作类型，但仍由 Aegis 风险策略审批。

不复用或不开放：

- Glic UI、Google 模型选择、OptimizationGuide 模型请求和隐式遥测。
- 任意 JavaScript、shell、通用文件系统、通用 CDP 或远程调试端口。
- 跨 Profile、跨 origin、跨主 frame 或旧 DocumentToken 的动作。
- 密码、Cookie、OTP、支付数据等 secret 的模型参数或页面观察值。

## 安全门

1. `kAegisAgent` 及所有写能力 feature 默认关闭；用户偏好也默认关闭。
2. 页面观察有 128 KiB、512 节点、单文本 2 KiB 的上限，并执行敏感字段裁剪。
3. 每个页面动作都校验 Profile、tab、frame、文档和当前 URL；导航后旧节点失效。
4. WebMCP 只接受固定 schema 和同文档结果，返回值继续作为不可信输入。
5. 最终购买始终进入用户接管；购物任务中的 submit 控件不能由通用点击提交。
6. Agent OFF 时取消模型、Actor、待审批和监控，不创建新任务。

## M0 证据边界

M0 的 Go 只代表架构与最小执行层可行，不等同于 RC 或发布。后续仍需分别通过 C++
单测、Browser/Interactive UI 测试、完整 App 构建、A1–A10 运行时、安全、性能、补丁
重放和产物身份门。
