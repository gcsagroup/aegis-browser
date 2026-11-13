# Access 产品阶段一 — feat 拆分（iOS / macOS）

日期：2026-11-08（Asia/Shanghai）  
目标：点 allow/block（或「本站代理」开关）→ 被墙站可访问；关闭回原连接；故障不静默直连。  
对照验收：`access-product-phase1-acceptance.zh-CN.md`  
相对：工程小闭环（F1–F11 + SOCKS5 无认证）已合入 fork；本拆分只补**产品路径**。

纪律：一 feat 一 PR；分支 `feat/<platform>-access-<slug>-2cd7`；正文不出现自动化工具品牌；CI 绿才合，不用 `--admin`。

---

## 总览

```
前置节点配置 ──► 意图模型 ──► 会话编排 ──► 产品开关 UI
                      │            │
                      ▼            ▼
                 DEV ALLOW/BLOCK   故障 fail-closed
                      │
                      ▼
                 五步证据夹具 / 说明
```

工程管道（入站 / Reality / ProxyConfiguration）当作**已交付依赖**，本阶段不重做 F1–F11。

---

## A. iOS feat 方案

源码主目录：`apps/ios/AccessKit` + 薄 UI 在 `apps/ios/AegisApp`。  
PBX 新区段（避免与 F11 `00A0`、本地导入 `00B0` 冲突）：

| Feat | 分支 | 标题焦点 | PBX | 依赖 | 验收映射 |
| --- | --- | --- | --- | --- | --- |
| **P-iOS-1** | `feat/ios-access-site-intent-2cd7` | 本站意图：`off` / `allow`（代理）/ `block`（本地拒绝）+ 按 host 持久化 | `00C0–00C4` | develop | A1-2 数据面、A3-1 |
| **P-iOS-2** | `feat/ios-access-site-session-2cd7` | 会话编排：意图 → registration/lease → runtime → ProxyConfiguration → HTTP(S) Reality 路径 | `00C5–00C9` | P-iOS-1, F8/F9/F11 | A2-1/A2-2 编排 |
| **P-iOS-3** | `feat/ios-access-site-toggle-ui-2cd7` | 当前页「本站代理」开关；开关态 ≠ 连通态；关闭文案 | `00CA–00CE`（App 侧） | P-iOS-2 | A1-1/A1-3/A1-4 |
| **P-iOS-4** | `feat/ios-access-dev-allow-block-2cd7` | DEV 调试：对明确 host ALLOW/BLOCK | `00CF–00D2` | P-iOS-1/2 | A1-2 |
| **P-iOS-5** | `feat/ios-access-fault-no-direct-2cd7` | 节点/运行时失败时新请求失败或等待；禁止当直连成功 | `00D3–00D6` | P-iOS-2 | A2-3/A2-4 |
| **P-iOS-6** | `feat/ios-access-product-phase1-evidence-2cd7` | 模拟器五步证据目录与操作说明（可 `SIMULATOR_PASS`；真机/TestFlight=`NOT_RUN`） | docs + 夹具 `00F8–00FB`；包目录 `docs/audit/evidence/ios-access-product-phase1/`；NOTES `ios-access-product-phase1-evidence-NOTES.md` | P-iOS-3/5（fault 未合入前 A2-3/A2-4 记 pending） | A2-5、A4 |

### P-iOS-1 细节

- 类型：`AccessSiteIntent`（`off|allow|block`）、`AccessSiteIntentStore`（按规范化 host）
- `block` = 本地拒绝该 host 的本服务代理意图，不等于系统级广告拦截
- 不启动 Xray、不碰 WebKit

### P-iOS-2 细节

- `AccessSiteSessionController`：`enable(host)` / `disable(host)` / `block(host)`
- allow：确保 runtime + 对当前 data store 应用 ProxyConfiguration + 准备 Reality dial 缝
- disable：撤 registration / 清 ProxyConfiguration
- 注入缝保持可测；无节点时返回明确错误，不假成功

### P-iOS-3 细节

- 工具栏或页面菜单入口；绑定当前导航 host
- UI 两行状态：`intent` + `connection`（idle/connecting/ready/unavailable）
- 文案键进 String Catalog（中/英/繁最小集可后补，先英+简）

### 非目标（iOS 本阶段）

F12/F13/F14 纯工程切片可并行但不阻塞本退出；WS+TLS 主出站、有认证 SOCKS5、TestFlight 发行门另轨。

---

## B. macOS feat 方案

源码：`apps/browser/overlay/chrome/browser/aegis/access/` + toolbar UI。  
依赖已有 `AccessServiceCoordinator` / `AccessRuleStore` / site proxy rule group。

| Feat | 分支 | 标题焦点 | 依赖 | 验收映射 |
| --- | --- | --- | --- | --- |
| **P-mac-1** | `feat/macos-access-site-intent-api-2cd7` | 产品意图 API：对当前 host 提交 allow/block/off → `CommitSiteGroupMutation` 边界清晰 | coordinator | B3-1 |
| **P-mac-2** | `feat/macos-access-toolbar-bubble-2cd7` | 工具栏气泡：域名 + 开关 + 短状态（开关≠连通） | P-mac-1 | B1-1/B1-4 |
| **P-mac-3** | `feat/macos-access-bubble-session-2cd7` | 气泡 → 发布快照 + 本机代理就绪；失败可读 | P-mac-2, 本地代理 | B2-1/B2-2 |
| **P-mac-4** | `feat/macos-access-dev-allow-block-2cd7` | DEV 调试 ALLOW/BLOCK 面板 | P-mac-1 | B1-3 |
| **P-mac-5** | `feat/macos-access-fault-no-direct-2cd7` | 故障后新请求不 DIRECT；browser test / 夹具 | P-mac-3 | B2-3/B2-4 |
| **P-mac-6** | `feat/macos-access-product-phase1-evidence-2cd7` | 五步证据包说明 + 关联 ID 约定 | P-mac-3/5 | B2-5、B4 |

### P-mac-1 细节

- 冻结「用户意图」与「publication/ACK」边界；禁止 test-only setter 充当产品开启
- host 规范化与 site group 一致

### P-mac-2 / P-mac-3 细节

- 气泡只读当前导航 trusted URL
- 开启：PrepareCandidate → Publish → 等 ACK → ready
- 关闭：本地可提交；服务不可用仍可关

### 非目标（macOS 本阶段）

完整管理页流量账单可后置为 Beta；SOCKS5 产品入口可标 PARTIAL（先 HTTP）；付费/多区域不做。

---

## 并行与合入顺序

| 窗口 | 负责 |
| --- | --- |
| W-iOS | P-iOS-1 → 2 → 3，再 4/5；6 收尾 |
| W-macOS | P-mac-1 → 2 → 3，再 4/5；6 收尾 |
| W-review | 串行审 PR；冲突时 pbx / overlay 分区优先 |

硬依赖：

- iOS：P-iOS-3 需要 2；产品退出至少 1+2+3+5+6  
- macOS：P-mac-3 需要 1+2；产品退出至少 1+2+3+5+6  

建议：**两窗并行**；每窗一次只推一个 PR。

---

## 与用户点名的后续工程轨关系

| 项 | 与产品阶段一 |
| --- | --- |
| F12 HTTPS→Reality | iOS 工程加项；P-iOS-2 可先 HTTP 路径，F12 补齐 HTTPS 汇合 |
| F13 私密隔离 | 产品加项（A3-2）；可与 P-iOS-1 store 按 Profile 分桶一起做或紧随 |
| F14 模拟器目录 | 工程矩阵保留；**产品**五步包由 P-iOS-6（`docs/audit/evidence/ios-access-product-phase1/`）承接 |
| WS+TLS 主出站 | **另轨**（改出站合同） |
| 有认证 SOCKS5 | **另轨** |
| 真机/TestFlight | **另轨**（发行门，不阻塞模拟器产品 PASS） |
