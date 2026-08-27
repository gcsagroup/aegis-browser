# GCSA-aegis 下载加速与 BT 实施记录

- 版本：Local MVP v1.0
- 日期：2026-08-26
- 状态：**本地实现与验收完成；未使用 GitHub，未形成发布产物**
- 产品边界：能力集成到 Chromium Browser，不恢复 GCSA Extension 产品线
- 协作边界：本轮只使用本地 Git；未 fetch、pull、push、PR 或发布
- 本轮排除：视频网站解析下载、媒体提取、MP3/视频转换、FFmpeg 和第三方视频下载扩展

## 0. 本地实施结论

本轮已完成可运行的本地 MVP，并根据实际使用反馈把入口从
`chrome://aegis` 开发面板迁入 Chromium 原生 `chrome://downloads`：

- 普通 HTTP(S) 下载继续使用 Chromium `DownloadItem`，桌面默认启用有界并行；
  计量网络、热压力和电池状态会自动降级，下载记录显示真实并行/分片证据。
- 单文件 RFC 5854 Metalink 在下载中心导入，执行大小、XML、公开地址、凭据、
  重定向和 SHA-256/SHA-512 检查；任务进入原生下载列表，错误镜像顺序故障迁移。
- `.torrent` 与 Magnet 在下载中心检查、选文件、限速并启动；任务以原生风格 BT
  卡片统一显示暂停、继续、取消、peer/seed、上下行速率和进度。
- BT 引擎运行在 Network sandbox Utility Process；默认关闭 UPnP、NAT-PMP、LSD，
  限制 4 MiB 元数据、2048 文件、2 TiB、80 peers，拒绝路径穿越和符号链接，
  完成后不继续做种。
- `chrome://aegis` 只保留功能说明和进入下载中心的链接，不再重复展示下载表单。
- Chromium 原生 `chrome://settings/downloads` 已增加 Aegis 下载加速设置：HTTP
  智能/单连接/最多 3/最多 6、计量网络与电池降级，以及新 BT 任务的
  DHT、PEX、下载/上传限速默认值；设置保存到浏览器级 Local State，重新打开
  页面和重启浏览器后继续生效。
- 取消动作按用户意图幂等处理；清理阶段服务断开也会移除任务卡和 Profile 任务标记，
  不再出现永久“处理中”或 `torrent task not found` 残留。

本地验收结果：

- Chromium 全量目标 `chrome`、`aegis_torrent_unittests`、
  `aegis_browser_unittests`、`components_unittests` 构建通过。
- BT 安全与双本地 seed 传输 6/6；Aegis Browser 40/40；并行下载相关 24/24；
  `DownloadsListTrackerTest` 26/26；仓库核心 47/47。
- 下载设置持久化/校验 3/3，原生设置 Handler 2/2；HTTP 连接策略新增覆盖测试
  验证 6 路、单连接关闭并行任务和智能默认恢复。真实 Chromium 中设置“最多
  6 个连接”、关闭 DHT、BT 默认 4096/512 KiB/s 后重载仍保持，下载中心的新
  Magnet 任务正确继承同一组默认值。
- 12 MiB 受控下载在当前电池/资源降级状态使用 2 路连接：单连接 10024 ms，
  并行 5924 ms，提升 1.692 倍；无 Range 回落为单请求，三种结果 SHA-256 相同。
  先前非降级采样为 3 请求、提升 3.59 倍。最终机器可读证据保存在
  `.artifacts/download-runtime-final-2026-08-26.json`。
- `ip.gcsa.org`、Example、Wikipedia、BrowserLeaks、Cloudflare、YouTube 为 6/6，
  0 dump、0 FATAL；证据为
  `.artifacts/multisite-download-final-local-2026-08-26.json`。
- BT 取消并静置后连续 8 次采样总 CPU 均为 0.0%，BT Utility Process 数量为 0。
- Cloudflare 长观察窗口中默认 Aegis 为 120.49% 单核等价，关闭 Aegis 为
  119.19%，负载几乎全部位于站点 Renderer；这不是下载模块的空闲轮询。

仍属于发布门、没有伪装成已完成的项目：

- 当前 Metalink 是安全的单文件 RFC 5854 导入与顺序镜像故障迁移；尚未实现
  RFC 6249 响应头自动发现、跨镜像并行分片调度和 piece 级跨镜像恢复。
- BT 会话可跨下载页关闭继续运行，但尚未实现浏览器重启后的 session resume；
  HTTPS tracker 因避免 OpenSSL 与 Chromium BoringSSL 混链而暂未启用。
- 当前只完成 macOS 本地沙箱和构建验证；Windows/Linux、fuzzer、签名、公证、
  安装包、正式依赖来源审计与 Notice 汇总仍是发布前门槛。
- libtorrent 2.1.1 来自 SourceForge 的精确镜像项目而非上游官方发布站，固定
  SHA-256 为 `0f163516ecef2e3331500266751de3098835a3c3ae0c2290448046c632bc0e93`；
  可重复本地构建，但正式发布前必须换成可证明的上游来源或完成独立来源审计。

## 1. 结论与推荐

推荐范围收敛为两条产品链：

1. **普通下载加速**：复用 Chromium 已有的并行下载、断点续传和 `DownloadItem` 体系，在桌面端启用并增加 Aegis 下载状态。第一阶段不重写分片写盘器。
2. **镜像与 BT**：镜像优先实现 Metalink 标准和强哈希校验；BT 使用独立沙箱 Utility Process 承载 libtorrent，Browser 只负责权限、状态和 UI，不把 P2P 网络栈放进 Browser 主进程。

视频下载和媒体转换不做，也不预装第三方下载扩展。保留 Chromium 原有的用户自行安装扩展能力即可，Aegis 官方不捆绑、不背书、不为扩展授予静默权限。

这个选择有三个直接好处：

- 不重新引入已经删除的 Extension 产品面，下载体验和生命周期仍由 Browser 统一管理。
- 避免视频扩展要求大范围 host、tabs、cookies、webRequest 等权限带来的供应链和浏览数据风险。
- 不会因为“换成扩展实现”而错误地绕过 YouTube 等网站条款、版权或 DRM 边界。

## 2. 为什么不直接内置视频下载扩展

技术上可以把 CRX 或 component extension 随 Chromium 预装，但它仍然是 Extension，不是 Browser 原生能力：

- 需要独立 manifest、权限、Service Worker/content script、更新和签名链。
- 常见视频下载器需要读取页面、跨源请求或拦截网络，往往要求宽 host 权限；Chrome 官方安全指南明确建议最小化并尽量改成可选权限。
- 预装会替用户跳过正常的安装选择和权限理解；一旦扩展更新源或开发者账户受损，风险会扩散到全部用户。
- Chrome Web Store 政策不允许扩展帮助未经授权下载或串流受版权保护的媒体；视频下载器本身也属于不会被商店重点推荐的类别。
- YouTube 服务条款只允许服务明确授权的下载，或取得 YouTube 及相应权利人的事先书面许可。把解析器放入扩展并不能改变这一点。

推荐处理方式：

- Aegis 不预装视频下载扩展。
- 用户仍可通过标准 Chromium 扩展机制自行安装，自行审查来源、权限和条款。
- 企业将来若要求白名单扩展，只能走独立的扩展审计、固定 CRX hash、固定更新源、最小权限和管理员策略项目，不并入本下载计划。

## 3. 当前项目基线

### Chromium 已有并行下载

当前固定 Chromium 151 源码已经包含完整的 `ParallelDownloadJob`：

- `components/download/public/common/download_features.cc`：Android 默认开启，桌面默认关闭。
- `components/download/internal/common/download_job_factory.cc`：满足强 ETag/Last-Modified、Range、Content-Length、文件大小和 HTTP(S) GET 条件后创建并行任务。
- `components/download/internal/common/parallel_download_utils.cc`：默认 3 个请求，默认最小分片约 1.3 MiB，并复用已保存的 slice 做恢复。
- 服务器不支持 Range、没有可靠内容长度、内容校验条件不足或 Service Worker 响应时，会回落到普通单连接下载。

因此“多线程下载”的最小正确方案是启用、产品化和补测试，而不是新建一套与 `DownloadItem` 竞争的下载器。

### 当前缺口

- 桌面端并行下载默认关闭，用户看不到连接数、分片状态和回落原因。
- Chromium 原生并行下载只从同一 URL 拉分片，没有跨镜像调度和整文件强哈希合同。
- 当前没有 `magnet:`、`.torrent` 的内置下载引擎。

## 4. 功能范围

### P0：普通 HTTP(S) 并行下载

支持：

- HTTP/HTTPS、重定向、带时效签名的直接文件链接，以及 Chromium 已支持的 `blob:` 页面下载。
- 服务器条件允许时自动使用多连接 Range；否则无感回落到单连接。
- 暂停、继续、重启恢复、另存为、下载完成后的 SHA-256 校验。
- 默认“智能”模式：1–3 个连接；确定服务器和本机仍有收益时最高 6 个，不把“线程越多越快”当作产品承诺。
- 计量网络、省电模式、低电量或系统热压力高时自动降为 1 个连接。
- 每主机、全局连接和同时活跃下载数设置硬上限，避免挤占网页、CPU 和磁盘。

用户感知：

- 下载气泡显示“普通 / 并行 3 连接 / 单连接回落”，以及速度、剩余时间和恢复能力。
- 只展示真实状态，不显示无法证明的“已加速 300%”。
- 高级设置提供“智能、单连接、最多 3、最多 6”；默认智能。

明确不做：

- 不支持 FTP；Chromium 已移除 FTP，重新引入会扩大明文凭据和旧协议攻击面。
- 第一阶段不做 Thunder、ed2k、网盘解析码或自动读取剪贴板。

### P1：镜像加速与 Metalink

支持两种来源：

1. RFC 5854 `.meta4/.metalink` 文档。
2. RFC 6249 `Link: rel=duplicate` + `Digest` 响应头。

安全合同：

- 自动发现的跨源镜像必须有 SHA-256/SHA-512 整文件哈希；没有强哈希时忽略跨源镜像。
- 多镜像必须下载同一字节内容；ETag、长度或 hash 不一致立即剔除错误镜像，不能静默拼成损坏文件。
- 跨源镜像请求不携带原站 Cookie、Authorization、Referer 或 URL userinfo。
- 只允许 HTTP/HTTPS；默认拒绝 loopback、私网、链路本地、保留地址和 DNS 重绑定目标，企业内网镜像必须通过显式管理策略放开。
- 重定向后重新执行协议、地址和凭据检查。
- 手工添加镜像时要求用户同时提供可信 SHA-256，或只允许同源镜像。

调度策略：

- 先做小的有界探测，再按实际吞吐、错误率和延迟分配分片。
- 单镜像变慢或失败时迁移未完成分片，不重下已经通过 piece hash 的内容。
- 镜像评分只在当前下载任务内使用，不形成跨站浏览画像。

### P2：BT / Magnet

推荐依赖：libtorrent 2.x。其官方说明支持 BitTorrent v2、桌面平台并以 BSD 许可发布；发布时需要保留作者和许可证声明。

架构：

```text
magnet/.torrent
       ↓
Browser 权限与文件选择 UI
       ↓ Mojo（有界消息）
沙箱 Aegis Torrent Utility Process
       ↓
libtorrent + 独立磁盘目录
       ↓
下载完成校验 → Chromium 下载记录
```

第一版范围：

- `magnet:`、`.torrent`、BitTorrent v1/v2/hybrid、tracker、文件选择、暂停/继续和 session resume。
- 不提供种子搜索、排行榜、内容推荐、资源索引或“热门影视”入口；用户必须自己提供 magnet 或 torrent。
- 首次使用必须说明公网 IP 暴露、P2P 上传、带宽和内容版权责任。
- 默认下载完成后停止上传；长期做种、分享率目标和上传限速必须由用户显式开启。
- 默认关闭 UPnP/NAT-PMP 和局域网发现；DHT/PEX 独立开关。关闭 DHT 时，无 tracker 的 magnet 可能无法工作，UI 必须明确说明。
- 对 torrent 内文件路径执行绝对路径、`..`、符号链接、超长名称、特殊设备名和文件数/总大小检查。
- 每个 piece 由 BT hash 校验，最终文件仍可附加 SHA-256；可执行文件继续走 Chromium 危险下载提示。
- 限制磁盘 cache、peer 数、连接数和内存；后台和电池模式降低并发。

隐私模式后续可增加“只走用户配置代理，不接受入站连接”，但不能宣称 BitTorrent 匿名。代理不可用时应停线，不能回落直连。

## 5. 下载中心与用户体验

在 Chromium 下载气泡和 `chrome://downloads` 上扩展，不创建独立 Extension：

- 类型：HTTP、镜像、Metalink、BT。
- 状态：连接数、镜像数、peer/seed、下载/上传速度、ETA、已验证分片、最终 hash。
- 控制：暂停、继续、取消、限速、打开目录。
- 原因解释：服务器不支持 Range、镜像 hash 不一致、DHT 已关闭、磁盘空间不足等。
- BT 首次使用显示一次清晰的公网 IP、上传和版权提示，普通下载不反复弹窗。
- 下载历史不记录 URL query value、Authorization 或 magnet tracker 密钥；显示前对敏感参数做脱敏。

## 6. 安全、隐私与资源预算

### 网络

- 普通下载沿用 Chromium Network Service、代理、证书、Safe Browsing/Aegis 恶意信誉和危险文件门。
- 多连接不能绕过同源凭据与重定向策略；镜像默认无凭据。
- BT 流量与网页流量分进程、分 traffic annotation、分代理设置和统计。
- 不自动扫描剪贴板，不自动发现局域网下载源。

### 文件

- 所有任务先写随机临时文件，校验成功后原子改名。
- 恢复前核对 ETag/Last-Modified、总长度、piece 状态和目标路径；远端内容变化就重新开始。
- 预分配前检查真实可用空间；稀疏文件和超大 torrent 设置上限。
- 镜像/BT 输入均按不可信数据解析，fuzzer 和损坏样例是发布门。

### 性能预算

- HTTP：默认 3、最高 6 连接；全局活跃下载连接建议上限 12。
- BT：默认最多 80 peers、256 MiB cache，后续由实测收紧；后台/电池模式减半。
- 浏览普通网页时，下载功能空闲 CPU 中位数相对 Aegis 当前基线增加不超过 0.5 个单核百分点。
- 1 个普通并行下载时 Browser UI 线程不得出现超过 100 ms 的新增长任务；hash 和写盘必须在后台序列。

## 7. 依赖与许可选择

### 复用 Chromium 下载组件

- 无新第三方依赖，是 HTTP 并行下载的首选。
- 保留现有 `DownloadItem`、危险下载、路径选择、恢复和 UI 生命周期。

### libtorrent

- 官方说明为 BSD 许可，支持 macOS/Windows/Linux 和 BitTorrent v2。
- 实施前固定官方源码包版本、SHA-256、许可证和构建参数；按当前约束不从 GitHub 拉取。
- 只把库放进独立 Utility Process，不允许库回调直接触碰 Browser UI 对象。

### 不选的组合

- 不把 aria2、视频下载扩展、yt-dlp 或 FFmpeg 可执行文件作为隐藏 sidecar 打包。
- 不恢复 `apps/extension`，也不把第三方 CRX 转成 component extension 规避用户安装授权。

## 8. 分阶段实施计划与完成状态

### D0：下载基线与合同（1–2 人日）

状态：**本地完成**。

步骤：

- 固定当前 Chromium 下载功能、feature 状态、现有下载 UI 和 native tests 基线。
- 建本地 HTTP fixture：Range/无 Range、ETag 变化、断流、限速、重定向、错误长度和恢复。
- 定义 `AegisDownloadEvidence`：协议、连接数、来源数、校验状态、回落原因；禁止包含敏感 URL 参数。
- 建下载 CPU、内存、磁盘和网页稳定性基线。

验证：未修改功能前，fixture 能稳定复现单连接、恢复和失败路径；机器可读报告不含 Cookie、Authorization 或 query value。

### D1：桌面并行下载与用户感知（3–5 人日）

状态：**本地 MVP 完成**。连接策略、下载列表证据、真实吞吐和回落已验证；
原生下载设置页已提供智能、单连接、最多 3 和最多 6 档位。

步骤：

- 在 Aegis Browser 桌面端启用 Chromium `ParallelDownloading`。
- 增加智能连接上限、计量网络/电池降级和可解释回落原因。
- 在下载气泡及 `chrome://downloads` 显示真实连接数和校验状态。
- 在 `chrome://settings/downloads` 提供浏览器级持久设置；计量网络、电池降级
  可配置，严重/临界热压力降级作为稳定性保护固定开启。
- 补 `ParallelDownloadJob`、恢复、取消、Profile 退出和浏览器重启回归。

验证：3 连接受控 fixture 相对单连接达到至少 2.2 倍吞吐；不支持 Range 的服务器 100% 回落成功且文件 hash 相同；杀进程后恢复两次不重下已确认分片。

### D2：Metalink 与镜像（4–7 人日）

状态：**安全子集完成**。完成 RFC 5854 单文件导入、强散列、公开地址和顺序镜像
故障迁移；RFC 6249 自动发现和跨镜像并行调度留在后续阶段。

步骤：

- 解析 RFC 5854/RFC 6249 的最小安全子集。
- 实现来源集合、跨源无凭据请求、地址检查、hash/piece 校验和失败迁移。
- 增加镜像状态 UI，不做外部镜像搜索服务。

验证：快/慢/离线/损坏四镜像 fixture 均得到唯一正确 SHA-256；恶意私网镜像、DNS 重绑定、凭据泄漏、hash 不一致和超大 XML 全部 fail closed。

### D3：BT Utility Process（8–12 人日）

状态：**本地 MVP 完成**。完成沙箱服务、torrent/magnet、v1/v2 检查、文件选择、
限速、DHT/PEX、暂停/继续/取消、双 seed 传输和隐私说明；浏览器重启恢复、
HTTPS tracker 与跨平台发布验证尚未完成。

步骤：

- 固定 libtorrent 源码包、许可证和 GN 构建。
- 建立最小 Mojo 接口、sandbox、任务持久化和下载 UI 适配。
- 支持 torrent/magnet、v1/v2/hybrid、文件选择、限速和恢复。
- 加首次隐私说明、DHT/PEX/UPnP/做种控制，不加搜索和目录。

验证：只用本地私有 tracker/DHT fixture 完成两 seed 下载、断点恢复和文件选择；路径穿越/符号链接/超大元数据拒绝；Browser/Renderer 崩溃不破坏 torrent session，Utility 崩溃不带崩 Browser。

### 工期建议

- 第一个可见版本：D0 + D1，约 4–7 人日。
- 完整下载增强 MVP：D0–D3，约 16–26 人日，不含首次 Chromium 全量构建等待、libtorrent 许可确认和正式发布签名。
- 推荐按 D0 → D1 完成本地验收后再进入 D2，D2 通过后再引入 libtorrent；不要一次把 HTTP、镜像和 BT 三套网络路径同时塞进补丁链。

## 9. 最终验收门

### 功能

- HTTP 并行、回落、暂停、恢复和文件 hash 全部通过。
- Metalink 镜像故障迁移不会产生混合或损坏文件。
- torrent/magnet、文件选择、恢复、限速和完成校验可用。

### 稳定与性能

- 原有 Aegis common/browser tests、`quality:fast`、补丁/overlay 状态全部通过。
- 下载和 BT 各自有 native test、fuzzer、Utility 崩溃恢复和受控端到端测试。
- `ip.gcsa.org`、Wikipedia、Cloudflare、YouTube 等现有多站点门继续 6/6，0 dump、0 FATAL。
- 下载空闲、单 HTTP、三连接、镜像和 BT 五种状态分别记录 CPU/内存/磁盘，不能只测平均速度。

### 合规与发布

- 没有站点视频 extractor、Cookie 导出、MSE 截取、媒体转换或 DRM 绕过代码。
- 没有预装视频下载扩展；用户自行安装扩展仍走标准 Chromium 权限流程。
- BT 无搜索/推荐/目录；首次公网暴露与上传说明可见。
- libtorrent 源码、许可证、构建参数和 Notice 完整。
- 产品身份、签名、公证、安装包、Android/Linux 仍按原项目发布门单独验收。

## 10. 已确认并执行的默认选择

1. 普通下载：启用 Chromium 原生并行下载，智能 1–3、最高 6。
2. 镜像：只做 Metalink/强 hash 镜像，不做公网镜像搜索。
3. BT：采用 libtorrent Utility Process；无搜索，首次使用确认，完成后默认停止上传。
4. 视频下载和媒体转换：不做。
5. 第三方视频下载扩展：不预装；只保留用户自行安装能力。

上述选择已在本地分支实施。后续若进入正式发布，再单独执行依赖来源、跨平台、
签名、公证和安装包验收；本轮没有因此触发任何 GitHub 操作。

## 11. 主要参考

- [Chrome Extension 权限声明](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions)
- [Chrome Extension 安全建议](https://developer.chrome.com/docs/extensions/develop/security-privacy/stay-secure)
- [Chrome Web Store Program Policies](https://developer.chrome.com/docs/webstore/program-policies/policies)
- [YouTube Terms of Service](https://www.youtube.com/static?template=terms)
- [RFC 5854：Metalink Download Description Format](https://www.rfc-editor.org/rfc/rfc5854)
- [RFC 6249：Metalink/HTTP Mirrors and Hashes](https://www.rfc-editor.org/rfc/rfc6249)
- [libtorrent 官方功能与许可说明](https://www.libtorrent.org/)
- [BitTorrent Protocol v2 / BEP 52](https://www.bittorrent.org/beps/bep_0052.html)
