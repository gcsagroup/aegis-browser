# F：普通网站 mutation 的代理组权限边界

## 范围与设计

基准 B：`c4ffb50a0d8efc684aa1ba0022daf5113def19a6`。本轮授权独立分支开发与质量线并行，合并、晋升和发布门槛保持不变。open PR #160/#161 为测试/runner，无同范围功能 PR。历史 trusted-site workspace 已有未提交 token registry/UI 候选，仅作只读参考，不重复其实现。

本切片补齐普通当前站点 PROXY mutation 的 transport 准入：同一 partition 的 CustomProxyConfig 当前仅有一个 endpoint，按 exact host 选择，不能按顶层网站、scheme 或 port 为同 host 选择不同代理组。旧检查只拒绝 DIRECT/PROXY 对立，会接受同 host 的异组 PROXY 后再在请求侧失败；这里不宣称已有实际误路由证据。

将 host overlap 与 mode/group 兼容性检查放入已有 standalone `site_proxy_rule_group` 模块，coordinator 对已通过 store/matcher 规范化的完整候选调用它。无需新增 GN target 或引入未合并依赖。新返回使用既有 `kUnsupportedTransportScope`，在 runtime/transport publication 之前走既有 supersede 清理，不改变 committed retry。

## 不变量与验收

- exact host 或 label-boundary suffix 重叠时，PROXY 必须属于同组；DIRECT/PROXY 对立继续拒绝。
- 相同组、无重叠 host、独立 REJECT 规则仍保留原处理；本检查不是权限授予，也不覆盖规则 matcher。
- 输入身份来自已验证的 mutation/store owner，检查不会从 URL、活动 tab 或模型建议构造授权。
- 不触碰 pageToken、导航/redirect 失效、Profile/OTR 身份与 UI 生命周期；本切片不宣称这些既有候选已交付。
- 拒绝后 durable snapshot、transport selection、coordinator generation 不变；排空任务队列后没有 publication ACK 请求。
- 同组正控制可发布并提交。真实浏览器回归源码验证冲突拒绝后新导航保持原代理、origin 无新增直连；其实际执行单独报告。

## 验证边界

`nativeImpact=REQUIRED`。standalone unit/regression 运行通过 864 checks，新增 16 项覆盖本切片。Chromium coordinator GTest 与真实 browser regression 已补源码，尚不等于运行通过；最终 HEAD 报告在本地 `.artifacts/feature/` 与独立 native 候选 evidence 中记录。Q 的任何旧结果均不覆盖本候选。

最终本地 full quality、独立 review、fixed Chromium/runtime 与托管 CI 状态由最终交付记录提供。未取得 native/runtime 证据前不可宣称 Feature 验收完成或合并就绪。

## 模型与所有权

独立设计范围评审实际为 Astra high；可用子代理列表不提供 Sol，指定 Sol 实现阶段无法执行，主任务以当前 Astra 完成实现（主任务 effort 未由工具显式确认）。最终评审使用另一新上下文 Astra high，修复后同一 reviewer 复审。评审不代替测试、托管检查或人工批准。

产品 worktree：`aegis-browser-worktrees/trusted-current-site-boundary-20260922`；native 候选：`aegis-chromium-feature-scope-20260922`。F 不写 Q 专属目录。回退按独立提交 revert；不改数据库格式，不删除现场。
