# iOS Access：本站规则组（Site Rule Group）— TODO 草案

日期：2026-11-10。状态：**草案 / 未实施**。挂靠 PR [#97](https://github.com/gcsagroup/aegis-browser/pull/97)。

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

## 4. TODO 清单（实施前）

### 4.1 规格

- [ ] 将本草案升为短 SDD（或并入 exact-host SDD 附录），明确组大小上限、发布/撤销原子性、与现 `AccessHostStoreKey` 的关系。
- [ ] 更新实现方案状态表：增加行 `G`（Site Rule Group），完成含义与 U/K/D/R 分开。
- [ ] 能力矩阵：标明 iOS 降级项 vs Chromium 完整请求级分流。

### 4.2 数据与协调

- [ ] `AccessSiteRuleGroup`：`groupID`、`primaryHost`、`memberHosts[]`、`generation`、scope/private 绑定。
- [ ] 发布器：一次准备入口，对组内 host 批量 `setEndpoint` / 绑定策略；失败整组不部分生效（或明确部分生效语义并测）。
- [ ] 关闭代理 / 私密结束：整组解除，淘汰专用存储。

### 4.3 UI

- [ ] 失败页与本站开关：文案从「仅此 host」改为「本站（含已授权关联域）」；不展示通用规则编辑（非 DEV/Alpha）。
- [ ] DEV/Alpha：只读或受控列表查看组成员；不加完整 ACL 编辑器除非另开任务。

### 4.4 验证

- [ ] U 扩展：主 host 开启后，组内第二 host 新标签走代理；组外第三 host 仍原连接。
- [ ] 故障：入口失效后组内保持绑定且无原连接请求（对齐 S6）。
- [ ] 不回归：默认发现列表仍不含 live/R；节点与组清单不进 git。

### 4.5 明确不做（本 TODO 周期）

- [ ] 全局 TUN/VPN。
- [ ] 真机 D、1.0.2 Beta 打包（仍需另授权）。
- [ ] 把 R 全量 100 站当合并门。

## 5. 与 #97 的关系

| 项 | 状态 |
| --- | --- |
| exact-host U + 进程内 K（模拟器/live） | 已在 PR 头推进；本 TODO 不回滚 |
| 本文件 | 仅文档草案，**未接线** |
| 合并门 | 不因本 TODO 放行或阻断；实施另 commit |

## 6. 完成定义（草案本身）

- PR #97 说明已引用本文件，并写明「体验下一台阶 = 本站精确 host 组，非全局拦截」。
- 未把组功能标成已交付；未改 required checks。
