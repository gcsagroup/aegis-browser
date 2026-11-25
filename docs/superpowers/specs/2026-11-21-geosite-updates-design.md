# 网站加速 Beta 分类与 Xray 官方更新设计

首期范围为普通 iOS DEV，代码基线 `24c3b9a1d4ff80c16966883de43976bc780f1afc`。历史前版 [d046ab4e](https://github.com/quinn521/aegis-browser/commit/d046ab4e454919f52de1a828639e0983a0282e3d) 的假定团队 Ed25519 信封由本文替换。[iOS #402](https://github.com/quinn521/aegis-browser/pull/402) 与 [macOS 静态 #403](https://github.com/quinn521/aegis-browser/pull/403) 是已验证的 **V2Fly** 实现，不能追记成 Xray 下载证据。

主负责人先发布本设计与[实施计划](../plans/2026-11-21-geosite-updates.md)，再写产品代码；先交付内置三组的可用分类入口，再接完整更新闭环，随后迁移 macOS 来源、接入 Android。HY2 独立；既有 owner、FIRST、期限、累计预算和失败记录不变。[既有产品规格与历史证据](2026-11-21-access-geosite-design.md)继续用于原功能，本次分类与更新约束以本文为准。

## 产品与授权

入口保持「设置 → 网站加速 → 访问中国大陆网站 → 手动／智能」。智能下增加可导航的「加速分类」行，旁置非交互 Beta 标记；行值显示已选名称、数量或「未选择」，打开原生小型多选列表。VoiceOver 行名只读一次 Beta，具有导航语义与当前值；分类项有本地化名称、选择状态和 selected trait，支持 Dynamic Type 换行。三个选项均真实可用，不列未实现的占位项；此入口不增加网络诊断。

新安装默认手动、分类预选 DEBIAN；升级仅在选择字段缺失时迁移为 DEBIAN，保留已有手动／智能与 exact 覆盖。显式空集合独立于缺失／迁移状态，允许取消最后一项并持久保存；智能空选提示「未选择加速分类。」，非空提示「按所选分类加速网站。」；#402 的「仅 Debian」提示只属于 Beta 前版本。未配置服务时仍保留既有简短提示。

同一普通 owner 的所有普通窗口共享选择并跨重启保存；手动忽略分类并保留选择。private、Guest、非 DEV（含 release）、unknown／冲突身份及其他 owner 不能读取、修改或触发该状态，UI 与原生入口都校验身份。零选择和手动均不触发更新网络；零选择后的显式新增选择可进入取数／确认流程，未获准前不贡献路由。

勾选即确认屏幕展示的**已验证当前版本及完整分类**，不是授权该组未来任意内容。列表优先显示名称与勾选状态，美团注明含大众点评。规则数量、含子域语义、版本及完整范围收在可展开的详情中。首次启用智能即可从分类行看到默认 Debian；已授权且等价的升级迁移保留选择。打开列表后候选变化须刷新并重新操作，旧点击不能批准新内容。取消勾选立即影响新导航，并停止失去唯一授权的旧操作；重叠分类按 OR 合并，exact 用户选择优先，独立有效授权继续保留。

## 官方来源与首批完整分类

选用 XTLS/Xray-rules-dat 官方 **standard geosite.dat**。[固定 README](https://github.com/XTLS/Xray-rules-dat/blob/0f8082e3b11bbe8ee65f26de86cbd2e0d510c983/README.md)说明标准数据随 Xray 捆绑，expanded 为可选；[固定 Xray-install](https://github.com/XTLS/Xray-install/blob/9d3ad49a3294d4c1d042f1fb6a16360b4d1befd1/install-release.sh)的 Linux update-geodata 选 expanded，不要求本产品跟随。

2026-11-21 已核验[官方发布 20261120235103](https://github.com/XTLS/Xray-rules-dat/releases/tag/20261120235103)：release id `453302649`，published_at `2026-11-20T23:52:15Z`，immutable=false，tag commit `0f8082e3b11bbe8ee65f26de86cbd2e0d510c983`，GeoSite source `d74acca73490cb57a937674ce8a8709d2a3021ba`。raw DAT 为 **7,750,066 字节**，SHA-256 `6fb761384d0141a9bd7dc3c18caf74b70516018ca91e3c36af11afefb543dcf9`；gzip 为 2,408,476 字节。两资产均核对 API SHA 与配对校验文件，gzip 解压等于 raw；独立 protobuf 解析得到 1,572 组。这是原始来源证据，尚非产品更新验收。

| 原生名称／官方组 | 完整条数 | canonical typed SHA-256 |
| --- | ---: | --- |
| Debian／DEBIAN | 2 | `d865d67c829d0f13bf508e152ef402d5d9634227ed12a8b49434d231baf5a643` |
| 豆瓣／DOUBAN | 3 | `62cfcbf5e006744783206139a2cbb6a3dffb05dbc366f1784a193e887e038619` |
| 美团／MEITUAN | 19 | `7f23061fb1a46f4150077aa56c369188cfda5bb49bd99649264c5bfb7bf8efa9` |

上述规则全部为无属性的 domain，且已逐条通过固定真实 iOS PSL。DEBIAN 完整为 debian.org、dotdeb.org；DOUBAN 完整为 douban.com、douban.fm、doubanio.com；MEITUAN 完整为 100.me、51ping.com、baobaoaichi.cn、ddcorp.net、ddfresh.net、ddimg.mobi、ddmaicai.net、ddmc.mobi、dduser.mobi、ddxq.mobi、dianping.com、dpfile.com、imaicai.mobi、maoyan.com、meituan.com、meituan.net、mtyun.com、neixin.cn、sankuai.com。typed 摘要取按 type/value ASCII 排序的 `type:value\n` UTF-8 字节。

U1a 只把这三组小快照及来源清单放入 App 签名范围，豆瓣、美团初始不选；内置信任来自应用签名。保留[继承的 V2Fly MIT](https://github.com/XTLS/Xray-rules-dat/blob/d74acca73490cb57a937674ce8a8709d2a3021ba/LICENSE-inherited)、[官方分类来源说明](https://github.com/XTLS/Xray-rules-dat/blob/d74acca73490cb57a937674ce8a8709d2a3021ba/README.md)及 XTLS 版本、来源、许可元数据。其他官方组常含属性、regexp、共享后缀或过大集合，不能过滤坏行后冒充完整组；新菜单项经相同完整准入、许可和产品验证后再加入。

## 最小更新线与准入

远端信任是系统验证的 GitHub HTTPS、固定官方仓库的发布权限，以及 API asset SHA-256 与同 tag 的 `.sha256sum` 一致性；摘要不是独立签名，不能防官方账号／发布链被攻破。上游没有独立 Ed25519 信封、expiry 或 revoke；不需要团队 URL、公钥、发布服务或新信任部署。本地时限、用户授权和水位是本产品约束。

元数据固定 GET `https://api.github.com/repos/XTLS/Xray-rules-dat/releases/latest`；只接受非 draft、非 prerelease 的预期 schema。唯一数据资产名为 `geosite.dat`，配对 `geosite.dat.sha256sum`，两者必须属于同一 release/tag，名称唯一、API SHA 与长度齐全。构造或逐字符验证 `https://github.com/XTLS/Xray-rules-dat/releases/download/<tag>/<name>`；元数据不重定向，资产仅允许该 URL 到精确 `release-assets.githubusercontent.com` 的一次 HTTPS/443 跳转，使用 GitHub 返回的临时签名 URL，拒绝 userinfo、fragment、其他主机／端口及再次跳转。

使用独立 ephemeral URLSession、系统 TLS／代理／企业策略，禁用 cookie、凭据、URLCache，不发送 Referer、页面 URL、历史、账户 token 或跟踪字段。启用且到刷新时点才访问上述三个主机；关闭／手动／空选立即取消，已发出的请求无法收回，随后无新更新流量。更新不经 GeoSite、订阅节点或页面 lease，节点未配置也能更新；日志不记录 CDN 签名参数或浏览轨迹，隐私默认不变。

首版仅 raw DAT，无 gzip 解析器；请求 identity，拒绝压缩、206 与非预期状态。逐块累计并计算完整 SHA，下载到 EOF 后与 API 及校验文件三方核对，切换前完成；不信任 Content-Length。限元数据 256 KiB、校验文件 4 KiB、DAT 16 MiB、单次更新 30 秒；校验文件自身也核对 API digest，只接受对应文件名的一条 SHA。protobuf 上限：4,096 组、累计 4,000,000 字段／记录、深度 8、varint 10 字节、组名 64 字节、每目标组 128 条；所有长度受剩余文件约束并检查溢出。完整扫描外层到 EOF 和组标识，安全跳过非菜单组载荷，不能因找到目标就提前成功；单值字段重复、目标大小写伪装／重复、截断、坏 wire、超限或任一目标坏行拒绝整次候选，旧有效 active 不受损。

目标只接受 domain/full，拒绝属性、keyword、regexp、未知类型、重复行及不规范主机；输出排序而不要求上游行序。主机必须为 canonical 小写 ASCII/IDNA A-label，长度 ≤253、标签 1–63；拒绝 IP、本地域、单标签、空标签、URL／转义字符。URL 端可经平台 IDNA 与单个根点规范化；full 精确命中，domain 按 DNS 标签边界命中。PSL 公共后缀、domain 跨嵌套 ICANN/PRIVATE 边界及租户范围不明均拒绝整组，不能推算成更宽父域。

复用 [RegisteredDomain](../../../apps/ios/AegisPolicyKit/RegisteredDomain.swift) 数据，增加可失败的严格查询；不能用其宽松 normalizedHost／空资源回退做准入。iOS ICANN+PRIVATE PSL SHA-256 固定 `ba7d836c0ea57a8bcf9f1fcb868066a7554bed029b441ecc6204ad8494a32612`，缺失／不符即拒绝新准入。各平台绑定自己的可信来源、实际 PSL digest 与准入版本；macOS Chromium 的 PSL 不能声称与 iOS 资产相同。

## 版本、刷新与官方移除

tag 必须恰为 14 位 ASCII 数字并解析为有效 UTC 日历时间；published_at 为有效 UTC，满足 `tagTime ≤ published_at ≤ tagTime+24h`、`published_at ≤ now+300s`。远端快照有效期为 `published_at+7天`，下载、重启和 304 均不延长。尚未采用远端版本的干净安装可以离线使用随 App 签名交付的三组内置规则，内置发布日记录来源，不设七天安装期限。一旦某组正式采用官方远端快照或收到官方完整移除，持久退休它的内置副本；过期、损坏和重装缓存均不能恢复该副本。

持久保存官方高水位 H（tag、release id、两项 asset id/digest、首次认可的 published_at）。新 tag 必须高于 H；同 tag 仅允许原回执、原字节的幂等恢复，改字节或改发布时间拒绝；低 tag、坏 checksum 拒绝。完整验证才推进 H，待确认候选不替换已有授权。官方以更高 tag 重新发布旧内容可接受，但仍须新时限与通常范围同意；不提供本地降级绕过水位。

普通 owner 选智能且非空、至少一个普通前台窗口存活才可刷新：首次合资格启用异步检查，后续启用／前台遵守 nextAttempt 并合并为单次在途任务，导航只读快照；成功后 24h 再查。失败退避 1min、5min、30min、6h，持久保存 nextAttempt，抖动后仍封顶 6h；开关和重启不重置。失去最后一个合资格窗口、切手动、空选、退出 owner／DEV 时取消任务并使代次失效；关一个窗口不取消另一个仍合资格窗口，迟到回调不能发布。

元数据可用强或弱 ETag（≤256 字节、无控制字符），只表示 API 表示的新鲜度，不证明 DAT 字节。If-None-Match 必须绑定可读取回执和仍有效 active；304 仅复用同一绑定，不延长 published_at／寿命，不引入新 scope。丢回执、丢 active、冲突 ETag 或到期的 304 按失败退避，下一次无条件请求，不立即循环补拉。

网络错误、404、限流／认证门禁、未知 schema、坏文件表示未知，不构成官方撤回，保留仍有效 active。只有 SHA、完整外层遍历和所有目标组准入均成功的较新整库，才可把**缺组或合法空组**确定为移除：原子持久记录该组贡献为空及内置回退退休，保留用户勾选并提示「暂无规则」；新的用户导航按 exact／其他有效组求值。所选组格式错误或不支持不是移除，整候选拒绝。移除状态不随回执到期失效；之后更高版本恢复该范围须重新同意，不能由重启或删除缓存复活。

## 冷快照与原子持久化

共享 DAT 每版本只下载一次并抽取三个完整目标组；不按勾选分类各下载一份。缓存只保存有界的聚合 committed/staged 快照及来源回执，包含每组版本、typed digest、获准范围、状态与期限。一次更新中等价／收窄组可提交，扩围组保留仍有效原 active 等待同意，缺／空组立即退役；一次原子快照记录这些组决定，不能发布半组或扩展历史授权并集。

安全权威是本机不可同步 Keychain 账本：安装／迁移状态、H、模式与选择（区分空）、每组已提交版本及获准 scope、内置退休／到期状态、聚合文件 hash、clockFloor、nextAttempt。偏好与 NSURLCache 均非权威；清网站数据、模式切换、删缓存不清水位。首次干净初始化／已知基线迁移才建账本；读取失败或安装标记冲突不能解释为首次安装。

后台验证 → 同目录临时文件写完、fsync、rename、同步目录 → 既有主协调器复核 owner／选择 revision／候选／期限 → 无 await 的短提交区更新单条账本 → 替换不可变快照。账本是线性化点：之前崩溃恢复旧提交，之后只恢复它指向的精确文件，重验 hash、scope、来源、PSL 与期限；文件缺失／损坏不能扫描较旧包补救。持久化失败不宣布生效；关闭先在内存封住受影响发送并报告未保存。首个官方提交或明确移除后，该组不能自动回退内置；H 较高时只允许恢复此前已经提交且仍有效的旧 active。

冷启动异步读取、重验并恢复当前获准快照，不等待 HTTP、不阻塞界面；未恢复前暂停依赖智能且不能安全判定的发送。过期、损坏或范围不明时，已知受保护／无法判定的目标 fail closed；能证明不依赖该范围的目标与 exact／独立授权照常求值。官方确认收窄／移除不同于未知失败。有效时间取 `max(墙钟, clockFloor)`，启动／前台／提交维护水位；回拨 >300s 暂停依赖智能的发送和新激活，会话内单调到期定时器不随回拨延后。已观察到的到期持久记录，每次发送／回前台重验，不能调时复活；不声称抵御账本、应用数据和系统时钟同时被外部回滚。

## 范围同意与 WebKit 切换

同意绑定 `(owner, 选择revision, candidateID, 旧snapshotID, typed范围digest, deltaDigest)`；candidateID 绑定来源回执、raw digest 与准入版本。新增覆盖才需确认，full→domain、父域扩展和不能证明子集均按扩围处理；一次确认最多 32 条增量，列出数量／域名／含子域与同页资源随文档出口说明，可在详情中完整查看。超限或拒绝时整组保留有效旧范围；绝不裁剪坏行或把同意授予未来贡献。取消、候选／选择变化、owner 失效、到期均使令牌作废；收窄后授权同步收窄。

复用 [AccessHostRoutingPolicy](../../../apps/ios/AccessKit/AccessHostRoutingPolicy.swift)、[AccessHostStoreCoordinator](../../../apps/ios/AegisApp/AccessHostStoreCoordinator.swift) 的 changeWebsitePolicy／policyEpoch 与现有 lease。快照绑定 owner、模式、选择 revision、各组获准 scope/期限、exact revisions、独立 grants；异步准备、绑定、发送、重定向及续租重验文档和 transport generation。更新代次不等于 transport 代次，旧请求不能发布新策略。

只处理决定变化的依赖：取消选择／收窄／过期先阻止受影响准备和发送；新增保护也先停止仍走原设置的受影响文档，不能留旧连接继续。让文档及 worker/流真正 inert，再释放自己的 consumer；退场前保留 store 代理配置和 lease，不能先清代理或释放共享 transport。失败消费者保持封闭，其他分类 grant 与无关准备不受损；等价数据不全量重载，等价操作复核后换发令牌。停止请求不自动迁移重发，尤其 POST、正文、下载和长连接；结果不确定告知用户，POST 只能由用户重新提交。

保留 #402 原三项回归：landing reload 重新准备、编辑 A 不取消 B 准备、切智能保留已提交 legacy landing 且冷标签不继承。另补后续 P2：exact service／clear 只增删对应 exact 依赖，独立有效的已提交 landing 仍存活；不得把它推广为同 host 新文档的授权。WebKit 文档退场和两侧网络见证为验收条件，reducer 或 stopLoading() 不足以证明闭环。

验收按原始来源、完整产品集成、模拟器、签名 DEV 产物、真机、最终 SHA CI、发布分别登记。先完成对应功能、构建、集成及功能测试，才对精确候选做最终独立只读审查；本次文档修订不代表实现、设备或发布通过。
