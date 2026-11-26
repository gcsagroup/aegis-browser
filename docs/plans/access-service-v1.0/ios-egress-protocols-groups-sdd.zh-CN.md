# iOS Access 出口协议扩展与出口策略组 SDD

基线为 fork `develop@079000d4`。Xray 依据锁定的 v26.11.9（commit `676eaf66`），源码在本机模块缓存中核对。本页描述 iOS 出口协议扩展与多节点策略组的设计和切片。冻结规范（修订 5）、[应用级回环入站合同](app-inbound-contract.zh-CN.md)、[iOS 入站 SDD](ios-app-inbound-sdd.zh-CN.md) 与 [3X-UI 网页与用量合同](../access-3xui-web-entry-sdd.zh-CN.md) 继续有效。主浏览器的出口准入以冻结规范为准，第 8 节列出需要修订的条目。

## 1. 现状

| 位置 | 行为 |
| --- | --- |
| `AccessOutboundProfile` | 只准入 `reality_vision`，`ws_tls_compat` 为预留名并被拒绝 |
| `AccessInternalTestNode` | DEV／内部 Alpha 测试 Profile 支持 `.realityVision` 与 `.vlessWebSocketTLS` 两种单节点 |
| `AccessRealityVisionOutboundConfigBuilder.assertFailClosed` | 遍历配置，拒绝非 `tcp` 网络、非 `reality` 安全层、`wsSettings` 与 `allowInsecure` |
| `AccessSubscriptionClient.parseNodes` | 最多 128 行，只保留 REALITY/Vision 的 `vless://` 并去重 |
| `AccessSubscriptionUsageSession` | 固定使用 `nodes.first`，没有选择与切换 |
| `EmbeddedCore/bridge/bridge.go` | `distro/all` 整包编译，每个 `Runtime` 是独立实例，`Dial` 经 `core.Dial` 走默认出站 |
| `AccessEmbeddedProxyEntrySession` | 新 generation 才调用 `loadOutbound` 启动内核 |

锁定版本已编译的代理出站有 `vless`、`vmess`、`trojan`、`shadowsocks`（含 2022-blake3）、`hysteria`（version 2）、`socks`、`http`、`wireguard`、`masque`。传输有 `raw/tcp`、`ws`、`httpupgrade`、`grpc`、`xhttp`、`mkcp`、`hysteria`、`masque`、`xdrive`，其中 `ws`、`grpc`、`httpupgrade` 被 Xray 标为不再推荐。安全层有 `none`、`tls`、`reality`。扩展出口协议不需要修改内核或重建 xcframework。

## 2. 目标与优先级

1. 当前在用出口节点的协议优先。现有节点清单（脱敏登记，凭据只保存在操作员本机）共 11 种组合，锁定 Xray 支持其中 8 种：

| 组合键 | 节点标注 | 导入格式 | 依赖 UDP |
| --- | --- | --- | --- |
| `vless.raw.reality`（Vision） | VLESS reality_vision | `vless://` | 否 |
| `vless.grpc.reality` | VLESS reality_gRPC | `vless://` | 否 |
| `vless.raw.tls`（Vision） | VLESS TCP TLS_Vision | `vless://` | 否 |
| `vless.ws.tls` | VLESS WS TLS | `vless://` | 否 |
| `vmess.ws.tls` | VMess WS TLS | `vmess://`（v2rayN JSON，`aid=0`） | 否 |
| `vmess.httpupgrade.tls` | VMess HTTPUpgrade TLS | `vmess://`（v2rayN JSON，`aid=0`） | 否 |
| `trojan.raw.tls` | Trojan TLS | `trojan://`（ALPN `http/1.1`） | 否 |
| `hysteria2` | Hysteria2 TLS | `hysteria2://`（`insecure=0`，ALPN `h3`，带 `upmbps`/`downmbps`） | 是 |

   其余 3 种是 TUIC、Naive、AnyTLS。它们只有 sing-box 实现，锁定 Xray v26.11.9 源码中不存在，本 SDD 不覆盖。若要支持，需要另行评审引入 sing-box 内核。
2. 多节点出口策略组按冻结规范第 7 节“自动检测 → 选定并保持 → 确认故障才切换”实现。
3. 锁定 Xray 支持、能作为出口的其余协议分批进入 DEV，再按规范修订进入其他渠道。

`freedom`、`blackhole`、`dns`、`loopback` 不转发到远端，或等于直连，一律拒绝。`xdrive` 借第三方云盘承载流量，默认排除，单独评审后才可加入。

## 3. 节点模型

```
AccessOutboundNode {
  kind: vless | vmess | trojan | shadowsocks | hysteria2 | socks | http | wireguard | masque
  endpoint: { address, port }
  security: none | tls(TLSParams) | reality(RealityParams)
  transport: raw | ws(path, host) | httpupgrade(path, host) | grpc(serviceName) | xhttp(path, host, mode) | mkcp(...) | hysteria(...)
  credentials: 按 kind 固定的结构
}
AccessNodeGroup {
  schema: 1
  groupId          // 稳定 ID，不含凭据
  source: bundled | manual | mock | subscription | managed
  lanes: [AccessNodeLane]   // 1...128
  mode: automatic | pinned(laneTag)
  protocolPriority?: [profileKey]
}
AccessNodeLane { tag: "lane-<a-z0-9>", node: AccessOutboundNode }
```

- 协议名改为组合键 `<kind>.<transport>.<security>`，例如 `vless.raw.reality`、`vless.ws.tls`、`trojan.xhttp.reality`。`reality_vision` 与 `ws_tls_compat` 作为兼容别名保留，原有编码与诊断值不变。桌面 SDD 中 `vless_ws_tls` 的命名统一到同一张别名表。
- 单 lane 组与现有单节点等价，生成的配置与现状字节一致，用回归测试锁定。
- 准入矩阵是一份数据表，Swift 与桌面共用 `fixtures/access/share-links/*.json`。新增组合先加用例，再改两端。

## 4. 生成器、校验器与存储

- 每种组合用固定字段生成唯一出站，不透传用户 JSON。JSON 导入只读白名单字段，再规范化重建。
- `assertFailClosed` 改为按组合的结构白名单遍历，未知字段拒绝。以下项对所有组合统一拒绝：`allowInsecure` 及任何关闭证书校验的字段，`mux`，`fragment`，`proxySettings`，`sockopt.dialerProxy`，非空 `routing` 或 `inbounds`，第二个出站。
- 明文上游拒绝。SOCKS、HTTP 上游必须叠加 TLS。VLESS 的 `none` 安全层只在同时使用 `mlkem768x25519plus` 加密时准入。VMess 拒绝 `none`、`zero` 与 `alterId > 0`。Shadowsocks 拒绝 `none`、`plain`。Hysteria2 拒绝 `insecure=1`。
- 每种组合显式列出秘密字段，诊断日志按清单脱敏。清单包括 UUID、密码、Shadowsocks 密钥、Hysteria2 auth、WireGuard 私钥与 PSK、REALITY 短 ID，以及 WS、xhttp 路径中的查询值。超过 256 个值时整体压制日志。
- 测试节点 Keychain 记录升为 v3，内容为带 `kind` 的规范 JSON。v1、v2 照旧可读。降级前需在 Options 中显式删除 v3 节点。

## 5. 导入与订阅

- Options 的文本与扫码入口按 scheme 分发到各解析器：`vless://`、`vmess://`（v2rayN Base64 JSON）、`trojan://`、`ss://`（SIP002）、`hysteria2://` 与 `hy2://`、`socks://`。WireGuard、MASQUE、mKCP 只接受单出站 JSON。单条输入、8192 字节上限、拒绝混入第二条分享等现有约束保留。
- `AccessSubscriptionClient.parseNodes` 返回 `[AccessOutboundNode]`，再按渠道准入过滤成组。订阅中的全局路由、DNS、allow/block 和上游策略组仍不导入（规范 A41）。DEV 视图显示被过滤的条数与原因类别。
- 签入订阅的用户 ID 绑定检查推广到每种 `kind` 的身份字段。
- 解析器接受现有节点使用的别名：Trojan 与 Hysteria2 的 `peer` 等同 `sni`，VMess v2rayN JSON 的 `peer` 等同 `sni`。`upmbps`/`downmbps` 映射到 Hysteria2 的带宽字段，缺省时交给拥塞控制。

## 6. 出口策略组

### 6.1 选择状态机

纯 Swift 实现，注入时钟，可单测。

- 排序按 `principalId + groupId` 生成稳定顺序。目前只有一个容量组，退化为组内稳定顺序。订阅行序与延迟不参与排序。存在 `protocolPriority` 时先按协议优先级分层，层内再按稳定顺序。
- 初次选择按顺序验证候选，第一个通过的即绑定。总预算 15 秒，最多 5 个候选，Profile 并发 2，单候选 4 秒。
- 已绑定后只在活跃时复核，间隔约 60 秒 ±20%，成功的业务流量可替代探测。复核失败进入 suspect，再复核两轮（共约 6 秒），确认后才切换。网站 403/429/5xx、证书错误、本机断网与本地内核退出不使节点失效。
- 冷却从 30 秒指数退避到最多 10 分钟，带抖动。两次复核成功后回到候选池，不抢占当前绑定，原节点恢复不回切。
- 每种组合标记是否依赖 UDP。同一网络代次内 UDP 类节点连续两次确认失败时，整类冷却。`NWPathMonitor` 报告网络变化时清除该冷却。
- `pinned` 只在 DEV／内部 Alpha 开放，固定节点失败时保持并报错。每个组只允许一个恢复任务。全部候选失败时 fail closed。

### 6.2 验证与切换

- 候选验证启动一个临时 `Runtime`，只加载该候选的单出站，经它连接 canary `www.gstatic.com:443` 并完成 TLS 握手即通过。浏览器级验证资源槽最多 2 个，跨 Profile 公平排队，临时实例结束后立即停止并确认释放。
- 切换顺序：候选验证通过 → 暂停该组新的 REQUIRE_PROXY 派发 → `AccessProxyEntryPublisher` 发起新 generation，`loadOutbound` 返回新 lane → 发布并收到全部相关上下文 ACK → 提交绑定 → 恢复派发 → 旧实例连接排空到截止。已发业务不复制到新节点，POST 不重放。
- 该路径不修改 `bridge.go`，不需要重建 xcframework 或更新 `embedded-core-lock.json`。

### 6.3 与 Xray balancer 的关系

`burstObservatory` + `routing.balancers`（`leastPing`、`leastLoad`）对每条新连接重新选点，并在后台持续探测。选中的出站发生在 Xray 内部，generation、ACK 与诊断都无法观察。这与规范第 7 节“不逐请求轮换”“闲置停止扫描”“原节点恢复不回切”冲突，所以只作为 DEV + `mock` 来源的实验，回执单独记账。桌面 SDD 的 D3 需要据此对齐。

### 6.4 单实例多出站备选

用 `session.SetForcedOutboundTagToContext` 在 `Dial` 时指定出站，一个实例即可承载整组。代价是 bridge 新增 `DialVia(tag, host, port)` 并重走锁定构建，`assertFailClosed` 改为逐出站校验，一个 lane 配置错误会拖垮整组。G4 上线后根据实测内存决定是否采用。

## 7. 准入矩阵

| 批次 | 组合 | 导入 | DEV | 内部 Alpha | Beta/Release |
| --- | --- | --- | --- | --- | --- |
| E1 | 现有节点的 7 种 TCP 组合：`vless.raw.reality`、`vless.grpc.reality`、`vless.raw.tls`、`vless.ws.tls`、`vmess.ws.tls`、`vmess.httpupgrade.tls`、`trojan.raw.tls` | `vless://`、`vmess://`、`trojan://` | 是 | 是 | `vless.raw.reality` 走现有签入订阅路径，其余待规范修订 |
| E2 | 现有节点的 `hysteria2` | `hysteria2://`、`hy2://` | 是 | 是 | 依赖 #213 的计量结论 |
| E3 | 其余 Xray 组合：VLESS 其他传输与 `none` + mlkem，Trojan 其他传输与 REALITY，VMess 其他传输，Shadowsocks AEAD 与 2022-blake3，SOCKS／HTTP over TLS | `vless://`、`trojan://`、`vmess://`、`ss://`、`socks://`、JSON | 是 | 是 | 待规范修订 |
| E4 | WireGuard（强制 `noKernelTun: true`）、MASQUE、mKCP | JSON | 是 | 否 | 否 |
| 排除 | TUIC、Naive、AnyTLS（Xray 不支持），`xdrive` 传输，明文上游，直连类出站 | 无 | 否 | 否 | 否 |

## 8. 规范修订项

主浏览器扩展出口需要一次冻结修订，至少涉及：规范第 7 节“主协议与兼容协议”的准入表，`allowedEgressProfiles` 的取值，W5“WS+TLS 兼容出站”的阶段归属，以及 A89 的协议组合列。服务端计量方面，3X-UI 可对 VLESS、VMess、Trojan、Shadowsocks 计量，Hysteria2 的计量方式由 #213 决定。修订单独提 PR，经冻结门禁与迁移条目评审。

## 9. 切片与验收

按顺序实施，每片一个 PR。现有节点协议（E1、E2）排在策略组之前。

| 切片 | 内容 | 完成条件 |
| --- | --- | --- |
| E0 | 类型化节点模型、生成器注册表、按组合的校验器、Keychain v3 | 现有 REALITY 与 WS 配置字节一致；v1、v2 记录可恢复；共享用例文件建立 |
| E1 | 现有节点的 7 种 TCP 组合：解析、生成、校验、脱敏，订阅解析返回 `[AccessOutboundNode]` 并按渠道过滤，用户身份绑定推广到各 kind | 共享用例覆盖每条拒绝规则；`bridge_test.go` 每种组合 `core.LoadConfig` + `core.New` 通过；macOS loopback 服务端联调经内嵌实例 Dial canary；Beta/Release 只保留 REALITY |
| E2 | 现有节点的 Hysteria2 | 同 E1，另在真机蜂窝与 Wi-Fi 验证；Go 注册测试确认 `proxy/hysteria` 在内嵌构建中可加载 |
| G1 | `AccessNodeGroup` 与 `AccessNodeLane`，测试 Profile 与签入订阅统一产出组 | 单 lane 组行为与现状一致 |
| G2 | 选择状态机 | 注入时钟覆盖保持、suspect 确认、冷却退避、两次成功回池、不回切、UDP 整类冷却、pinned 失败保持、预算耗尽 fail closed |
| G3 | 候选验证器与浏览器级资源槽 | 并发不超过 2；超时与取消后临时实例确认停止 |
| G4 | 接入 publisher 换代 | 受控环境封掉当前节点，15 秒内切到下一节点并有新代次证据；全部失败时阻断，旧连接新增接收为零 |
| E3 | 其余 Xray 组合 | 同 E1 |
| E4 | 第 4 批（仅 DEV） | 同 E1，另记录 WireGuard 用户态网络栈的实例内存 |
| G5 | DEV 调试视图与诊断 | 列出 lane 协议、安全别名、状态与冷却剩余；不显示 host、UUID、公钥 |
| R1 | 规范修订与主浏览器准入 | 冻结修订合并后按批次开放 Beta/Release |

## 10. 待核实

- `distro/all` 没有直接导入 `proxy/hysteria` 与 `proxy/shadowsocks_2022`，推断经 `infra/conf` 间接注册，E2/E3 的 Go 注册测试负责确认。
- `AccessProxyEntryPublisher` 能否在同一会话内不经撤销发起新 generation 并排空旧实例，G4 开始前逐行核对。
- MASQUE 只核对到 `address`、`port`、`remoteDNS`、`pass` 字段，客户端完整语义与 iOS 可行性未核实。
- 各协议在 iOS 上的实例内存与网络切换表现未实测。
