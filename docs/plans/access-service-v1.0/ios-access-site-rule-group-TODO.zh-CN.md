# iOS Access：本站规则组（Site Rule Group）— TODO 草案

日期：2026-11-11。状态：**草案**。产品行为以 [本站自动连接设计](ios-access-site-auto-connect.zh-CN.md) 为准。渠道容量、站点菜单/失败页开关和无人值守主导航恢复已接线。同页选择性代理不在首版。挂靠 PR [#97](https://github.com/gcsagroup/aegis-browser/pull/97)。

**动机：** 单一精确 host 的失败页重试在登录域、apex/`www`、必要 API 域上体验差。产品方向应是**浏览器内按规则分流**，而不是全局 VPN，也不是把 `matchDomains` 后缀当成精确授权。

**不替代：** [精确主机存储 SDD](ios-exact-host-store-sdd.zh-CN.md)、[实现方案](ios-exact-host-recovery-implementation.zh-CN.md) 的 U/K/D；[受阻站点回归](ios-access-blocked-site-regression.zh-CN.md) 的 R。本文件只排后续体验台阶。

## 1. 目标体验（一句话）

用户对「当前网站」开一次代理：浏览器发布**一组已核定的精确 host**，组内走 PROXY，组外默认 DIRECT；PROXY 故障 fail-closed，不静默回原连接。

## 2. 非目标

| 非目标 | 原因 |
| --- | --- |
| 默认全局拦截再分流 | 改变默认 OFF/原连接合同；iOS 也缺请求级可信归属 |
| `*.example.com` / 自动 eTLD+1 | 扩大「本站」；与现冻结精确 host 冲突 |
| 用 `matchDomains` 冒充精确授权 | WebKit 后缀匹配会吞子域；已有 I0 反例 |
| 与 Chromium W1a 请求级 envelope 假等价 | WK 公开 API 做不到 document/request 归属 |
| Beta/Release 通用规则编辑器 | 渠道合同：普通用户只开本站；DEV/Alpha 才调试 |

## 3. 建议合同（草案，待评审后升 SDD）

1. **规则键仍是规范化精确 host**；规则组是 host 的有序/有界集合，不是后缀表达式。
2. **一次用户意图**（失败页「通过代理重试」或本站开关）发布整组；整组撤销。
3. **组成员来源**（择一或组合，须写进验收）：
   - 产品/运营核定清单（优先）；
   - 同次会话内用户对关联失败域的显式追加；
   - **禁止**仅凭公共后缀或 DNS 自动扩权。
4. **执行（iOS 降级）：** 组内 host 的主导航可绑到共用本机 CONNECT 入口（可多专用存储、同一入口）；同页子资源继续跟随该页存储。组外顶层导航保持原连接。
5. **归属上限：** iOS 只保证「目标 host ∈ 已发布组」；不保证「跨顶层站引用同 host 不继承」——该条仍属 Chromium/W1a，此处诚实降级并写进能力矩阵。
6. **渠道：** DEV/Alpha 可展示组成员与命中；Beta/Release 只展示本站开/关与必要状态。

## 4. TODO 清单

### 4.1 规格

渠道容量与一键恢复以[本站自动连接设计](ios-access-site-auto-connect.zh-CN.md)为准。每组含主 host，去重后上限为 DEV 128、Alpha 64、Beta 32、Release 16。

- [x] 组上限、按预期版本发布、重叠撤销和 `AccessHostStoreKey` 的关系已写入自动连接设计，不另开一份会分叉的 SDD。
- [x] 实现方案状态表已有行 `G`，完成含义与 U/K/D/R 分开。
- [x] 能力边界：iOS 只保证顶层 host 是否属于已发布组。组内页的子资源跟随该页存储。组外顶层页保持原连接。请求级「同页只代理某一个子资源」仍属 Chromium，不在本版。

### 4.2 数据与协调

- [x] `AccessSiteRuleGroup`：`groupID`、`primaryHost`、`memberHosts[]`、`generation`、scope/private 绑定（本机单元测试已绿）。
- [x] `AccessSiteRuleGroupRegistry`：publish / 按 host 查找 / revoke / 私密会话 revokeAll。
- [x] 正常页开启只发布组，不批量 `setProxyEnabled`、不建专用存储、不准备入口。超限的整次变更失败并保留旧组。冷失败才为该 host 准备。
- [x] 关闭组与私密会话结束由协调器撤销该组贡献；没有剩余组且没有手动意图时才释放绑定。

### 4.3 UI

- [x] 失败页与站点菜单使用「本站打不开时自动重试」，并说明专用存储会带上该页资源。现有「通过代理重试」仍保留。
- [ ] DEV/Alpha 只读组成员列表。首版不做；不加规则编辑器。

### 4.4 验证

- [x] 组内成员页及其 `cdn.invalid` 经指定代理监听器；组外顶层页由源站收到。`AccessHostRecoveryWebKitTests` 与 `AccessNavigationRecoveryTests` 于 2026-11-11 模拟器通过。
- [x] 入口失效后保持代理配置且不再追加直连请求：`testFailedEndpointKeepsTheProxyAndDoesNotAddADirectRequest`。
- [x] 节点 URI 与本地 Reality 配置不进 git；默认测试门不含 live/R。

### 4.5 明确不做（本 TODO 周期）

- [ ] 全局 TUN/VPN。
- [ ] 真机 D、1.0.2 Beta 打包（仍需另授权）。
- [ ] 把 R 全量 100 站当合并门。

## 5. 与 #97 的关系

| 项 | 状态 |
| --- | --- |
| exact-host U + 进程内 K（模拟器/live） | 已在 PR 头推进；本 TODO 不回滚 |
| 本文件 | 步骤 1–3 已在工作树接线并通过模拟器测试，尚未提交。同页分流与实时探测不在首版 |
| 合并门 | 不因本 TODO 放行或阻断；提交与更新 PR 另授权 |

## 6. 完成定义（草案本身）

- PR #97 说明已引用本文件，并写明「体验下一台阶 = 本站精确 host 组，非全局拦截」。
- 工作树里的步骤 1–3 以 2026-11-11 模拟器回执为准。未提交前，PR 头不代表这轮实现。
- 未改 required checks。同页分流、实时探测和真机 D 不标成已交付。
