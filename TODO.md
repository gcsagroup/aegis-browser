# Aegis TODO

## Access Roadmap TODO

**SDD 开发与验收计划 · 2026-11-17**　范围为上游 20 个开放 issue。基线为 [upstream/main `6724dd4d`](https://github.com/gcsagroup/aegis-browser/commit/6724dd4deef9d8facc195e7c35f3bad6fdabe2d3) 和 [fork/develop `8c9e9fee`](https://github.com/quinn521/aegis-browser/commit/8c9e9fee9ebe334c9e14782a2a9838a496c627fc)。下列优先级用于安排后续工作，实施和验收状态以各工单的实际记录为准。

### 目标与关键路径

用户在原标签为一个精确入口域名启用 Access 后，该页面通过账户获配的节点访问目标。独立打开另一个入口时重新选路。节点按账户和周期计量，在耗尽或到期时停止转发。关闭保护后恢复原连接。每次验收用同一候选、账户和周期，把用户操作、浏览器请求、节点记录与目标收件对应起来。[阶段一总览](https://github.com/gcsagroup/aegis-browser/issues/98) · [iOS 原生 Options SDD](https://github.com/gcsagroup/aegis-browser/issues/183)

1. **先收后端。** 已完成的 #153 提供权益查询。#155 提供账户授权，#156 提供计量，#157 结算，#158 执行截止。#158 的真实旧流超额风险最高。自然跨日取证有固定时间窗口，可提前准备。#154 的支付渠道验收可与计量并行。
2. **再验 iPhone。** #136 先验承接自 #135 的 WebKit 路由能力，再接入账户网页。#155 的接口已进入上游，网页侧的验收与 #136 共用一次节点及目标取证。#137 验冷启动，#160 验权益界面，#138 汇总同一候选的真机结果。内部 Options 的第一步走 #183 的“应用 → 目标收件”。
3. **再验 macOS。** #165 的首标签白屏影响重试入口，#140 管原标签与账户事务，#159 管权益界面，#141 接收 #139 的可信路由与 #110 的 B4 五步。macOS 缺陷可独立定位。原始 100 站的正式验收按后端 → iPhone → macOS 排序。
4. **独立及后置工作。** #117 按本地化范围验收。阶段一按 #98 的退出清单汇总，两端闭环后再做 #142 的普通用户策略管理。Windows 保留 #170 源码移植与 #182 原生验收的分工，Windows 构建、测试及 runner 继续暂停。

### 按优先级执行与关闭

“前置”中的裸编号指 GitHub 当前开放的阻塞项，括号注明已完成的依赖或由产品规格约定的顺序。P0 为后端与账户网页关键路径，P1 为平台交付与验收，P2 为独立或后置工作。同一优先级先满足前置，再按表内验收条件关闭。

| 优先级 | 工单 | 前置 | 可核验的交付及关闭条件 |
|---|---|---|---|
| P0 | [#155 账户凭据](https://github.com/gcsagroup/aegis-browser/issues/155) | （#153 已关） | 在真实获配节点验证有效账户网页请求、错账户与撤销拒绝、普通／私密隔离和切换后旧流停止。与 #136 对齐网页取证。现有原生下载收据可复用。 |
| P0 | [#156 节点计量](https://github.com/gcsagroup/aegis-browser/issues/156#issuecomment-6946387247) | #155 | **唯一接近只待上游交付的项。** fork 已验证持续传输、A/B 分账、快路径和目标端逐字节对账。上游接收已验实现后，核对实际合并 SHA、计量源文件及适用检查，再按 N1 范围关闭。 |
| P0 | [#157 跨日结算](https://github.com/gcsagroup/aegis-browser/issues/157#issuecomment-6946387799) | #156（#153 已关） | 除上游交付外，须用同一有效 3X-UI 账户跨自然 UTC 零点（北京时间 08:00），核对前后面板、客户端、账本及迟到上报的周期归属。已停用账户的零读数保留为历史观察。 |
| P0 | [#158 耗尽与到期截止](https://github.com/gcsagroup/aegis-browser/issues/158#issuecomment-6946389068) | #155、#156、#157 | 实际部署曾超额 **3,049,300 B**。用真实节点和物理客户端在持续传输时耗尽／到期，证明旧流停止、新流被拒、账户 B 正常、续额可恢复。对齐面板、节点及客户端时间线，并核对上游交付。 |
| P0 | [#136 iOS 网页与内核接入](https://github.com/gcsagroup/aegis-browser/issues/136#issuecomment-6946437355) | #155 | 干净安装的 iPhone 从原标签经获配节点到受控目标。单独记录 I0 的 15 秒预算、跨域登录回跳、Worker 和普通／私密隔离，再验撤销、端点换代、旧回调及内核退出。 |
| P1 | [#154 购买与续额](https://github.com/gcsagroup/aegis-browser/issues/154) | （#153 已关，可与后端并行） | 用选定支付渠道完成一次真实开通与续额，核对订单归属、重复通知幂等、历史用量与新到期时间。已有受控订单回归可复用。 |
| P1 | [#183 iOS 原生 Options](https://github.com/gcsagroup/aegis-browser/issues/183) | （固定 Profile 可先做，账户路径接 #155、#136） | O1–O3 先交付内部 Debug／Alpha 入口、规则及“应用”到两个受控源站的代理／直连对照。O4–O6 再验恢复、导入导出与隐私，并在 iPhone 核对实际支持的协议、网络切换与故障行为。 |
| P1 | [#137 iOS 持久规则与原标签重试](https://github.com/gcsagroup/aegis-browser/issues/137) | #136 | 普通会话强退、重启后首个受约束请求即走已存出口，恢复失败时保持阻断。真机核对私密关闭清除、取消后迟到回调无效、POST 不重放及原标签只重试一次。 |
| P1 | [#160 iOS 权益界面](https://github.com/gcsagroup/aegis-browser/issues/160) | #136、#154、#157、#158 | 签名 iPhone 应用对齐真实账户、面板和账本。覆盖 A→B→A、耗尽、付款返回、续额恢复、VoiceOver，以及额度可见 5 秒／普通前台 30 秒刷新和回前台立即刷新。 |
| P1 | [#138 iPhone 综合验收](https://github.com/gcsagroup/aegis-browser/issues/138#issuecomment-6945509068) | （后端实证、#136、#137，关联 #160） | 核对测试选择器和实际执行清单，保留既有失败。在同一 iPhone 候选记录原标签、实际出口、目标回执及可见页面。按原 100 站表保留失败和待验行。ChatGPT 等代理协议切换后再测。 |
| P1 | [#165 macOS 首标签白屏](https://github.com/gcsagroup/aegis-browser/issues/165) | （可独立定位，影响 #140、#141） | 在干净 Profile 的真实 macOS 浏览器复现首次 DIRECT 失败，关联窗口遮挡、WebContents 可见性和首帧，验证首次失败页可见且可点击代理重试。 |
| P1 | [#140 macOS 发布与重试](https://github.com/gcsagroup/aegis-browser/issues/140) | #155 | 真实浏览器只在原标签重试原 URL 一次，核对获配出口。冷启动首请求遵守规则，切换账户、取消或旧回调均无法恢复旧授权。 |
| P1 | [#159 macOS 权益界面](https://github.com/gcsagroup/aegis-browser/issues/159) | #140、#154、#157、#158 | 用真实浏览器和账户验证界面与账本逐字节一致、付款返回、后台停流、续额恢复及切换后无旧余额。 |
| P1 | [#141 macOS 综合验收](https://github.com/gcsagroup/aegis-browser/issues/141#issuecomment-6946442536) | #140（百站在 #138 后，关联 #159） | 绑定可启动制品、构建锁及补丁来源。验证六类请求、独立登录域往返和服务重启。B4 单独收齐开启、加载、故障、恢复、关闭的日志、开关截图及关联 ID，再按 iPhone 原表完成 macOS 百站记录。 |
| P1 | [#179 macOS 渲染进程崩溃](https://github.com/gcsagroup/aegis-browser/issues/179) | （独立于 #165） | 受控诊断已复现 61/60 断言。关闭前须把真实浏览器的文档路径与帧反馈对应到历史崩溃，或留存能确定归因的等价复现及修正后回归。已有可见性修复只覆盖其已验路径。 |
| 汇总 | [#98 阶段一退出](https://github.com/gcsagroup/aegis-browser/issues/98#issuecomment-6946461475) | （两端原退出项及其承接清单） | 逐项链接 iOS、macOS 已交付行为与各自候选的验收结论，确认残留失败的归属。后置策略页、Windows 和商店发行各自跟踪。 |
| P2 | [#117 iOS 本地化](https://github.com/gcsagroup/aegis-browser/issues/117) | （独立） | 补齐 Swift 和 WebView 文案、语言回退及系统／扩展边界。以母语审校和 iPhone／iPad 的大字体、VoiceOver 记录结项。 |
| P2 | [#142 普通用户网站策略](https://github.com/gcsagroup/aegis-browser/issues/142) | （iOS 域名持久化及 macOS 对等闭环） | 两端实现并验证 DIRECT／PROXY／REJECT，覆盖真实拒绝访问、离线编辑、冲突、重启和私密隔离。#183 的内部编辑器按自身渠道验收。 |
| P2 | [#170 Windows 源码移植](https://github.com/gcsagroup/aegis-browser/issues/170) | （#159、#141 交付已验 macOS 基线） | 将 Windows 适配与最终共享基线对齐，核对差异和最终源码交付。[fork PR #353](https://github.com/quinn521/aegis-browser/pull/353) 当前为 Ready。Windows 原生验证另归 #182。 |
| 暂停 | [#182 Windows 原生验收](https://github.com/gcsagroup/aegis-browser/issues/182) | （#170 最终源码、既有暂停解除） | 恢复执行后在授权 Windows 环境完成 GN、编译、真实单元／回归、浏览器、安装与启动，记录对应制品和候选。 |

### 验收收据

每项回填候选 SHA、测试环境、实际用例数、失败行和证据链接。真实流量附浏览器、节点及目标端的同一请求标识，计量另附账户、周期和上下行原始字节。上游合入、真机验收及签名／发行分别记录。现有负责人、预算及暂停安排沿用原工单记录。

## Build System — CMake

CMake is planned as build infrastructure for future native C/C++ components. The current application build remains on the existing Xcode workflow until a native module needs this support.

- [ ] Introduce the CMake project foundation.
  - Add the initial `CMakeLists.txt` structure.
  - Support Debug and Release configurations.
- [ ] Add Xcode generator support.
  - Verify CMake can generate an Xcode project for supported native targets.
  - Keep the existing Aegis Xcode build workflow compatible.
- [ ] Prepare reusable native module build infrastructure.
  - C++ core libraries.
  - Network engine modules.
  - Cross-platform components shared by supported platforms.
- [ ] Add CI validation for the CMake path.
  - Verify CMake configuration succeeds.
  - Verify project/build generation succeeds for the supported macOS path.

### Activation criteria

Start implementing this roadmap when Aegis introduces a native component that benefits from an independent C/C++ build, such as a reusable network core, performance-sensitive native module, browser-engine integration component, or cross-platform library.
