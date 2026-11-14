# P-mac-1 — site intent API (off / allow / block)

## Scope

Product-facing exact-host Access intent under
`apps/browser/overlay/chrome/browser/aegis/access/`, mapped onto ordinary
`AccessServiceCoordinator::CommitSiteGroupMutation` boundaries.

| Type / API | Role |
| --- | --- |
| `AccessSiteIntent` | `off` / `allow` / `block` |
| `AccessSiteHost` | Canonical exact-host key + URL normalization |
| `OrdinaryAccessModeForIntent` | allow→`kProxy`, off→`kDirect`, block→none |
| `BuildOrdinarySiteGroupMutation` | Builds `SiteGroupMutationRequest` for allow/off only |
| `AccessSiteIntentStore` | In-memory product intents (off omitted) |
| `access_site_intent_unittests` | Parse / normalize / map / store |

## Mapping

| Intent | Ordinary site-group mode | Publication |
| --- | --- | --- |
| `allow` | `AccessMode::kProxy` | Caller may `CommitSiteGroupMutation` |
| `off` | `AccessMode::kDirect` | Caller may `CommitSiteGroupMutation` |
| `block` | not ordinary | `kBlockNotOrdinary` — no silent DIRECT |

Intent remains distinct from publication/ACK and connection health.

## Non-goals

- Toolbar bubble UI (P-mac-2)
- Session finalize / ACK orchestration UX (P-mac-3)
- DEV ALLOW/BLOCK panel (P-mac-4)
- Five-step product PASS claim (P-mac-6)


## Native checkpoint (2026-11-10, patches through 0405)

The current product candidate retains exact destination-host rules constrained by the Browser-owned top-level site. Paths on that host share the persisted Profile intent; an explicit proxy retry reloads only its initiating tab. Subdomains and cross-host page resources are not yet covered by this checkpoint.

Implemented: Browser-private full-policy publication and per-hop routing, an asynchronously restored ordinary Profile rule store, a managed authenticated Xray child with certificate-validated HTTPS readiness, and the error-page action wired to an original-tab one-shot retry. Native navigation no longer rejects legitimate selection-generation zero, and subdomain rules/cancellation selectors now use Chromium SchemefulSite identities.

Validation: complete native chrome builds through 0405; affected intent/session/coordinator tests 6/17/24 pass, including six real-core product scenarios. The navigation helper has 15 passing tests, including interaction with Chromium error auto-reloading. Actual Aegis computer use verifies controlled DIRECT DNS failure, one retry click, real readiness and a single original-tab/original-URL reload. This controlled fault is not a natural GFW measurement.

The requested 100-site run remains incomplete: the sealed checkpoint contains 15 natural-connection observations and 14 proxy main-document observations with matching browser NetLog routes. Twelve have page-content observations; Pinterest remains blank because its CDN requests retain native routing, and TikTok needs additional rendering evidence. These results do not close full browser, recovery or isolation acceptance.

Approved follow-up: extend the selection to the trusted top-level website context, including its page resources/CDNs, while retaining Browser attribution, unrelated-site and Profile isolation. That expansion is deliberately not implemented in this checkpoint. Cold-start automatic core preparation, actual runtime-exit/recovery/off coverage, the remaining website matrix and final-candidate acceptance also remain open.

The replacement Alpha test node is supplied separately as a private build resource. This checkpoint does not embed that credential or claim the replacement-node path has been tested. Alpha-only loading and packaging follow after the current PR update.


## 2026-11-11 冷启动请求就绪补充

普通 Profile 的已提交 PROXY 意图在重启后仍为 PROXY。Browser 按可信请求归属先做只读策略评估；仅命中本 Profile 自有 Alpha/DEV 本地组的请求等待真实核心准备。无关原生请求不等待该核心，也不以空策略推断 DIRECT。

核心准备、私有完整快照精确 ACK、认证 HTTPS 复查与当前绑定核验全部成功后才发送业务请求。这一恢复只重建运行时注册和选择代际，不提交新的持久意图、不改变规则 revision 或已恢复的 policy generation。等待期间的导航、document 或策略变更使原请求失效，不将其改发为原生连接。

核心意外退出撤销该注册并发布组不可用，保留选择高水位及保存的 ALLOW；不删除策略、不自动回放已发送的业务。新请求可重新准备核心。健康检查只作用于本服务持有的 child，正常停止不当作意外故障，旧 registration 的退出通知不撤销新的 child。普通 Profile 实际冷启动、退出/恢复和无关网站可用性须另做真实 Aegis 验收。


## 2026-11-11 用户批准的网站上下文范围修订

PR97先交付0948精确host检查点后，后续产品开关改为typed `Website` scope：Browser可信顶层网站（Chromium SchemefulSite，含private PSL边界）中的子域导航、子框架和HTTP(S)页面资源/CDN使用该网站的代理选择。规则中的host是规范网站锚点，既不是目的host通配符，也不是全Profile代理。顶层跨网站跳转逐跳重新判定；同一CDN在其他顶层网站、外来Profile或没有可信site归属时不继承此授权。原独立精确Site规则优先于Website，Website优先于Profile；保护和CORS仍各自执行。

SQLite schema 2为group和journal显式保存website_context；旧schema1事务迁移为false，旧精确host授权与PREPARED日志字节语义保持，不在启动时扩权。只有用户新的明确开关动作生成bubble-site网站组，并在同一候选/提交事务中替换该网站原有的普通bubble精确host组；独立规则不删除。PREPARED before-image绑定全部待替换别名，互斥相关未完成操作，失败时完整回滚。旧版本因compatible_version=2拒绝此库。

网站关闭/屏障按可信owner和两种HTTP(S)顶层网站匹配页面资源，不以CDN目的host或发起开关的伪document键代替网站归属；其他网站/owner不受影响。此范围仅允许已接通完整Browser私有Context的路径，旧CustomProxyConfig全局host选择不能承载网站授权。

验收必须包含根域→www、Pinterest的s.pinimg.com脚本/样式、同CDN其他网站原生、private PSL/外来Profile/无归属负例、旧库及别名提交/回滚、关闭与冷启动。WebSocket/ServiceWorker等尚未经过当前HTTP(S)产品工厂的执行范围仍单独列缺口，不以规则的scheme集合推导浏览器支持完成。
