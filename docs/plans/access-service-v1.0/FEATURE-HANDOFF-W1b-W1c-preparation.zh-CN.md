# W1b/W1c 接口与验收准备交接

日期：2026-09-26。核对基线 `origin/develop=edd02853f65ab6a089defac29fd5c73c3cbbdeed`。本交接是 [W1a 设计](w1a-request-routing-design.zh-CN.md)与 [W1a 可执行模型](w1a-fixtures/README.md)之后的增量清单；下文的拟新增接口和测试 ID 均未进入生产代码。冻结行为以 [规范修订 4](spec.zh-CN.md)为准，执行顺序以 [开发计划](development-plan.zh-CN.md)为准。

## 前置门与本轮边界

[W0 质量交接](QUALITY-HANDOFF.md)记录了原有矩阵和 #187 新增的 relay 取消/watchdog、缓存 REJECT、已提交 MHTML 预取早拒绝回归。#187 已合并到 develop，实际 `S=edd02853f65ab6a089defac29fd5c73c3cbbdeed`；其 [develop push run 36238830929/1](https://github.com/quinn521/aegis-browser/actions/runs/36238830929) 已按 S 验证通过，Q/I 的最终候选审查与固定 Chromium 回执关闭**有界 W0 底座工程**。这不证明生产 MHTML 默认 factory 回调的普遍终态、完整 BFCache/prerender BLOCK、性能、双 Profile/双出口、真实服务或分发；**G0 仍为 `UNVERIFIED`，131 个 A/PF 主行仍未逐项验收**。本交接不修改 overlay、patch、GN、Xray、Network Service 或验收追踪表，亦不操作 Q 的源码、`out` 或锁。

有界 W0 底座已退出前置队列；W1b/W1c 可以按本清单开始生产切片，但它们自己的接口、真实流量和认证验收仍须分别完成。每个 `feat(...)` PR 在最终 HEAD 同时执行新增逻辑的 unit 和至少一项真实入口 regression；[DEV CI 指南](../../development/ci.zh-CN.md)的本地全门、独立 Review、托管检查及适用固定 Chromium 证据分别核验。模型通过或本文完成均不改变 G0 和 131 个 A/PF 主行的状态。

## 当前调用链与待实现的最小接口

以下路径相对 `apps/browser/overlay/`；符号是当前产品树的审查锚点。W1a 第 4–6 节列出的 Chromium `net` 插入位置是**待实现位置**，实施时须在已准入的固定候选中重查可达路径、feature defaults 和实际签名。

| 切片 | 当前断点 | 必须一同落地的接口/边界 |
| --- | --- | --- |
| W1b-1 可信载体与安装 | `access_browser_request_adapter.cc::BuildBrowserOwnedRequestMetadata` 构造 Browser 归属；`access_proxying_url_loader_factory.cc::PrepareProxyDispatch` 捕获五元组和选定 endpoint，最终 `ForwardNative` 仍交出普通 `ResourceRequest`。`access_network_context_transport.cc::PublishPolicyCandidateToClients` 的 ACK 只确认已有 publication metadata。 | Browser 私有 `AccessFactoryBinding` 绑定 owner、partition、document/pending-navigation 归属和 NetworkContext incarnation；私有 `CreateLoaderAndStartWithRoute` 在一次 IPC 中携带原请求与 `AegisAccessRequestContext`。NetworkContext 原子安装完整 `AccessPublishedRouteSnapshot` 和 `AccessEndpointRegistration`，返回与候选、client 集合及 incarnation 精确相符的 ACK；半安装不得 READY。renderer 不得获取 receiver 或自报 owner，原 CORS/process/origin-lock 检查继续运行。此切片保留现有多组准入限制。 |
| W1b-2 请求级执行 | `AccessNetworkContextTransport::PartitionState` 只有一个 endpoint 和 exact-host 列表；`BuildConfig` 写 partition 级 HTTP CustomProxyConfig。`AccessProxyingURLTrackedRequest::RebindOwnershipForRedirect` 仅放行 PROXY→PROXY，再调用普通 `FollowRedirect`；初始 native 路径没有等价的逐跳控制。 | 按 owner/group/registration 发布不可变表；把已验证的 `AccessResolvedRoute` 从 URLLoader 经 URLRequest、`HttpRequestInfo` 送到实际 proxy/stream 决定点。受约束请求在缓存和首次发送前完成校验。私有 `FollowRedirectWithRoute` 每跳重验 token、hop、目标、可信站点、版本和 Chromium 计算的 method/body；初始 native 路径同样保留控制。只有同一候选真实证明多组并发正路径及基础连接隔离，才有替换 `AccessServiceCoordinator::ValidateTransportScope` 冲突保护的依据。 |
| W1c-1 复用、租约、恢复 | `RegisteredProxyEndpoint` 只有 owner/group/五元组、HTTP transport、host/port；没有 listener incarnation、credential handle 或租约期限。模型只拦新派发，不持有真实 socket/session。 | `AccessRouteIsolationKey` 至少包含 owner、group、registration、listener incarnation、完整命中组五元组和 NetworkContext incarnation，并进入 HTTP/1、CONNECT、HTTP/2/coalescing、新旧 stream pool、preconnect、auth/retry cache 的查找与回收。受约束 HTTP cache 首版按 W1a 设计禁用复用；REJECT 仍在缓存前阻断。明确到期、撤销、Profile/OTR 关闭、Network Service 重启时新派发和既有流各自的终态。W1b-2 对真实并发安全所需的基础隔离须随执行器同交，不能等 W1c 才补。 |
| W1c-2 实际认证 | `RegisteredProxyTransport` 目前只有 `kHttp/kInvalid`；W1a 的 `authorizeCredentialLookup` 只返回模型中的 identity。 | 已验证 route 才能调用 `AccessProxyCredentialProvider::LookupForRoute`。HTTP forward 与 CONNECT 均处理 407、拒绝错误/跨 Profile 凭据，且不把 `Proxy-Authorization` 发给 origin。新增 SOCKS5 transport、受信 socket 参数与 username/password 握手；需要认证的已登记入口不能降为无认证。未知 registration、外部代理、过期或已关闭 owner 不获秘密。SOCKS5 当前原生适配缺口的源码观察见 W1a 第 6 节，实施前重新核对固定候选。 |

所有切片保持：owner、document/pending navigation 和顶层 SchemefulSite 由 Browser 确定；URL、活动 tab、NAK、renderer/header 输入不能授权。`DIRECT`/未命中保留当前原生代理解析结果，`PROXY` 仅一个已登记入口且无原生/DIRECT fallback，`REJECT` 在缓存命中和发送前阻断。五元组分别为 policy、identity、**命中组** selection、network epoch、base proxy config，再加 NetworkContext incarnation。完整候选安装→精确 ACK→durable commit→finalize；新 BLOCK 的即时屏障不能被旧 ACK 解除。每个 `(requestId, hop)` 业务发送至多一次，合法 307/308 新 hop 单独计数，恢复不得重发旧 hop。

注册 ID 在 owner 历史中不可复用。同地址换 listener、凭据或任一代次都须新注册；secret handle 绑定 owner/incarnation/group/registration/transport/listener，注册再绑定地址、五元组与 `now < expiresAt <= connectionDeadline`。到期停止新连接，既有连接依截止规则终止；Network Service 重启保留已提交约束直到新 incarnation 安装完成，旧 ACK、receiver、redirect、连接与 secret 均无权复活。无唯一 client 的后台请求保持 Profile-only；不得通过新增路由让 Guest 获得未授权站点作用域。

## 可执行验收清单

下表是**待新增**的测试 ID 和实际运行条件，不是现有测试结果。每行至少有健康正对照、明确失败返回、请求相关 ID、代理入口/出口及 origin 计数；连接类再记录 socket/session ID，生命周期类记录状态转换与截止时间。真实代理转发本来会到 origin，单看 origin 非零不能证明 DIRECT；超时也不能替代可定位的拒绝。

| 拟议 ID / 层 | 操作与必须观察的正路径 | 必须观察的负路径与冻结映射 |
| --- | --- | --- |
| `F-B1-Binding` / native + browser | 可信 Browser binding、合法 clone、正常 CORS/preflight 和原生非 Aegis 请求仍成功。 | 伪造/跨 owner、旧 document、断连 receiver、非法 origin-lock、renderer `TrustedParams` 均拒绝且目标发送增量 0；A10/A11/A108。 |
| `F-B1-InstallAck` / unit + browser | 完整 snapshot、每个 client 和对应 incarnation 的精确 ACK 后才 READY。 | 半安装、缺端点、旧 ACK、后发 BLOCK、持久提交失败均不能恢复旧权限；候选已发送业务不重放；A15/A53/A113。 |
| `F-B2-ConcurrentRoutes` / browser + 双受控代理 | **同一 Profile、同一 partition** 内 A→同 CDN→X 与 B→同 CDN→Y 同时在途且分别经 X/Y；host-a→X 与 host-b→Y 也并发成功。http/https/ws/wss、默认端口/8443、本站与 Profile scope 按真实目标精确匹配。 | 不得串行切 partition 全局配置；缺失/过期组无 DIRECT，另一组和原生系统/PAC/扩展/企业配置正对照不受污染；A10/A11/A76/A108/A115。 |
| `F-B2-HopOnce` / browser + origin 业务标记 | 首次 POST/PATCH 只发送一次；302、307、308 的每个 hop 按原生 method/body 规则分别选路，包含 native→PROXY/REJECT、PROXY→native/异组。 | 被拒下一跳发送增量 0；旧 hop、过期 redirect、故障恢复、407 前转发均不增加业务标记；A20/A76/A108。 |
| `F-C1-ReuseLease` / native + 真实连接 | 先建 HTTP/1、CONNECT、HTTP/2 session；相同有效 key 可复用，同地址新注册能建立新的合法连接。 | 换 owner/group/registration/listener/五元组/incarnation 不复用旧 socket 或 H2 alias；到期停止新连接，旧流按截止终止，无关流不误杀；A16/A30。 |
| `F-C1-RestartCache` / browser | 真正重建 Network Service 后，完整新 incarnation 安装才恢复受约束请求；预热缓存后的原生非 Aegis 请求仍可按原配置完成。 | READY 前没有受约束 DIRECT 窗口；旧 ACK/secret/session/redirect 失效；预热 HTTP cache 后 REJECT 仍无发送；无业务重放；A15/A53/A96。 |
| `F-C2-AuthMatrix` / 固定 Chromium + 本地受控 HTTP/SOCKS5 代理 | 两个普通 Profile 分别以自己的凭据在 HTTP forward、CONNECT、SOCKS5 成功；IPv4/IPv6 listener 分别记录健康握手和出口。 | 无/错/跨 Profile/过期/关闭凭据、未知 registration、非 loopback 连接均明确拒绝；无认证降级、origin 不收到代理凭据，错误认证不预转发 POST/PATCH；A10/A78。 |

PF01–PF03 仍须按冻结样本规模、计时边界和预算独立跑性能实验；这些功能用例不产生性能 PASS。HTTP/SOCKS5 × REALITY/WS+TLS、完整 OTR/Guest 矩阵属后续 W5，不能由两普通 Profile 最小原型推断。

### 现在可执行的合同基线

从仓库根运行：

```sh
node --test scripts/ci/tests/w1a-request-routing-contract.test.mjs
node --test docs/plans/access-service-v1.0/w1a-fixtures/model.test.mjs
```

只记录 `CONTRACT_MODEL_ONLY`；输出中的 `native/browser/authNetwork=NOT_RUN` 必须保留。两个入口会覆盖相同模型，不能相加为两套独立证据。fixture 只接受模型中的 IPv4 endpoint；即时 pre-ACK BLOCK、durable commit、既有流终止、真实缓存、Mojo 信任边界及实际认证均未被模拟。

### 生产测试加入后的运行门

实现者先在隔离固定 Chromium 候选中完成源码准入，记录 Chromium/V8 pins、顺序 patch、overlay、GN args、工具与二进制 hash，并确认源码/产物未被其他任务修改。现有 `scripts/dev/chromium_access_gtests.py` 可运行 17 个 Access native targets，`--target` 选跑会标为 `PARTIAL_PASS`，不能冒充完整矩阵。新 native 用例须接入对应 GN target；浏览器用例须接入实际 `browser_tests`/适用 Content target。下面的 `AccessW1*` 名称是拟议 suite，**当前不存在**；未枚举到测试时立即停止，不能用零匹配退出码作 PASS。

```sh
# 仅在 Q 释放重型资源且 F 获得独立固定源码/out 后运行。
set -euo pipefail
export CHROMIUM_ROOT="<isolated-fixed-chromium-root>"
export W1_OUT="$CHROMIUM_ROOT/src/out/<isolated-w1-output>"
export W1_EVIDENCE="<external-evidence-directory>"
python3 -B scripts/dev/chromium_access_gtests.py \
  --out "$W1_OUT" --report-dir "$W1_EVIDENCE/native"
test -x "$W1_OUT/browser_tests"
test ! -e "$W1_EVIDENCE/browser-summary.json"  # 每轮使用新的证据目录
"$W1_OUT/browser_tests" --gtest_list_tests \
  --gtest_filter='AccessW1RouteBrowserTest.*:AccessW1AuthBrowserTest.*' \
  > "$W1_EVIDENCE/browser-list.txt"
"$W1_OUT/browser_tests" \
  --gtest_filter='AccessW1RouteBrowserTest.*:AccessW1AuthBrowserTest.*' \
  --gtest_repeat=1 --test-launcher-jobs=2 --test-launcher-retry-limit=0 \
  --test-launcher-test-part-results-limit=-1 \
  --test-launcher-total-shards=1 --test-launcher-shard-index=0 \
  --test-launcher-summary-output="$W1_EVIDENCE/browser-summary.json" \
  > "$W1_EVIDENCE/browser.log" 2>&1
python3 -B - "$W1_EVIDENCE/browser-list.txt" "$W1_EVIDENCE/browser-summary.json" <<'PY'
from pathlib import Path
import sys
from scripts.dev.chromium_access_gtests import gtest_names, runtime_test_count

suites = ("AccessW1RouteBrowserTest.", "AccessW1AuthBrowserTest.")
listed = gtest_names(Path(sys.argv[1]).read_text(encoding="utf-8"))
enabled = [name for name in listed if name.startswith(suites)
           and not any(part.startswith("DISABLED_")
                       for part in name.replace("/", ".").split("."))]
if len(enabled) != len(set(enabled)) or any(
    not any(name.startswith(suite) for name in enabled) for suite in suites
):
    raise SystemExit("missing or duplicate enabled W1 browser tests")
print(f"W1 browser tests: {runtime_test_count(Path(sys.argv[2]), enabled)} PASS")
PY
```

这是未来候选的调用模板，变量值须由该候选的 owner 填写，实际 suite 名随实现同步修订。`python3 -B` 防止内嵌校验导入仓库 runner 时在源码树生成 `__pycache__`。校验复用原生 runner 的清单/运行摘要规则：每个必需 suite 至少有一项启用用例，运行摘要必须与完整启用清单一致、恰好执行一次且成功；`GTEST_SKIP()` 在 `result_parts` 中留下的跳过也会被拒绝。`browser_tests` 是否足以覆盖该候选的 Content/Network Service 边界，需根据 GN 枚举加跑适用目标；不得删减 W0 原有必需目标。测试列表、真实匹配数、失败/退出码、源码前后稳定性、产物及受控代理配置 hash 必须一并保存。负路径须与同产物健康正对照关联；不能以模型、helper 或仅编译成功替代真实入口。最终 HEAD 变化后重跑受影响层级、独立 Review 和托管检查，按 B/H/M/S 各自身份报告。

## 交接结论

当前可执行的是 W1a 合同模型；W1b/W1c 的七组生产验收 ID 还没有对应实现或运行回执。W1b-1 先保住可信入口与完整安装门，W1b-2 才进入真实并发与逐跳选路；W1c-1 补齐全资源生命周期，W1c-2 用实际 HTTP/SOCKS5 握手收口最小认证。每个切片的已知隔离前提必须与其执行器一起提交，任何阶段都不以另一个阶段的待办漏洞对外放行。
