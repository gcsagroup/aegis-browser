# 钓鱼检测资料评估、差距与完善方案

实施日期：2026-08-25—2026-08-26
范围：GCSA Aegis 集成式 Chromium Browser；不包含历史 Extension，也不包含邮件客户端/邮件网关。
状态：**已完成本地实施与 Release 子门验收；发布仍为 No-Go**。

## 结论

三份资料都有参考价值，但用途不同：

- Cloudflare 与 CyberHoot 给出的是用户识别方法和防护常识，适合转化为浏览器可解释提示、链接去向预览和测试用例，不能直接当作自动检测算法。
- CN107992469A 给出了 URL 分词、定长词序列和双向 LSTM 分类方法，能补当前规则无法识别的词序列与路径语义，但其英文词典、历史数据、随机训练/验证划分和模型热路径并不适合原样集成。
- 本轮已把编辑距离/数字替换品牌仿冒、路径品牌与凭据词、已知短链、跨站凭据提交和本地威胁情报接入 Chromium 主产品路径，不是 Extension 旁路。
- “URL 0 分就不检查页面”的主要盲区已关闭：所有 HTTP(S) 页面都执行有上限的密码框/表单检查，只有 URL 可疑或存在密码框时才读取最多 2 KiB 正文。
- 免费数据源已按边界接入：CERT.PL 可在 Browser 后台更新；PhishTank、URLhaus 有离线 adapter 和密钥门；导航热路只查本地 SHA-256 索引，不逐页请求第三方 API。
- 仍未完成 UTS #39 confusable skeleton、有界跳转链、OTP/助记词专属输入识别、情报源 UI/撤销与完整误报评测；PhishLang/专利模型/视觉检测仍是研究项，不在默认热路。

当前落地为“**确定性 URL 层 → 有界凭据意图层 → 本地信誉层**”。灰区模型与视觉层继续作为后续离线研究，不进入普通网页默认加载路径。

## 一、三份资料能怎样参考

### 1. Cloudflare：适合定义威胁面和用户解释

[Cloudflare 的钓鱼攻击说明](https://www.cloudflare.com/zh-cn/learning/access-management/phishing-attack/)列出了伪造网站、域名与邮件欺骗、链接操纵、DNS Fast Flux、可信基础设施滥用、紧迫感和多渠道传播，并建议结合 URL 核验、邮件安全和 Zero Trust。

对本项目有用的部分：

- 把“域名不像正站”“页面要求凭据”“催促立即处理”做成可定位的原因，而不是只显示风险分数。
- 明确 HTTPS 只表示传输加密，不能作为“安全站点”的负风险分。
- 把品牌仿冒、账号停用话术和登录凭据收集组合为高置信信号。
- 将域劫持、可信站点被攻陷、邮件发件人欺骗列为浏览器检测边界，避免宣称浏览器能单独解决所有钓鱼。

不能由当前 Browser-only 产品直接覆盖的部分：

- 邮件显示名、真实发件人、Reply-To、附件、通用问候语和邮件上下文；浏览器打开页面后看不到这些原始证据。
- 电话、短信、社交媒体账号真实性和组织内部付款流程。
- DNS Fast Flux 的完整基础设施关系；可作为异步信誉情报，不能放到同步导航热路径。

### 2. CyberHoot：适合转成可操作的浏览器能力

[CyberHoot 的链接检查文章](https://cyberhoot.com/zh-CN/%E6%96%B0%E9%97%BB/%E9%92%93%E9%B1%BC%E9%93%BE%E6%8E%A5%E6%A3%80%E6%9F%A5%E6%8A%80%E5%B7%A7%EF%BC%8C%E4%BF%9D%E9%9A%9C%E6%82%A8%E7%9A%84%E5%AE%89%E5%85%A8/)的五个核心建议是：点击前查看真实去向、检查拼写与异常字符、不迷信 HTTPS、谨慎短链、识别子域和附加词；还包括紧迫感、意外附件/发票和通用问候语。

这些建议可以映射为：

- 悬停/点击前突出最终注册域，而不是让用户自行从长 URL 中找。
- 自动识别品牌编辑距离、数字替换、Unicode confusable 和混合脚本。
- 对短链显示“初始域 → 跳转后注册域”，在跨域且伴随登录意图时提升风险。
- 在警告中并列显示“页面自称品牌”和“真实注册域”。
- 对密码提交做最后一道高置信检查，而不是只在页面打开时检查一次。

邮件来源、意外附件和通用问候语仍属于邮件产品能力，不应在这一轮扩展 Aegis 的授权范围。

### 3. CN107992469A：适合作为模型候选，不适合原样照搬

[CN107992469A](https://patents.google.com/patent/CN107992469A/zh)描述了以下流水线：去掉协议和部分通用顶级域，用符号切分 URL，以英文词典正向最大匹配得到词序列，编码为定长向量，再用嵌入层、双向 LSTM、dropout 和 sigmoid 做二分类。页面披露的实施例使用随机约 80/20 训练/验证划分，并报告词序列双向 LSTM 的 Precision 0.9808、Recall 0.9716、F1 0.9762，以及普通服务器单线程不少于 600 URL/s。

参考价值：

- 能学习 `login / verify / update / paypal` 等词的顺序与上下文，比当前只检查 host 内少量品牌 token 更强。
- 只分析 URL，隐私和运行成本低于抓取 WHOIS、页面截图和远端沙箱。
- 可作为 20–54 分灰区的离线候选模型，与规则结果融合。

不建议原样实施的原因：

- 英文词典和正向最大匹配对中文、IDN、随机串、数字替换和新品牌不稳健。
- 去掉 TLD 会损失注册域边界和 TLD 风险；固定长度 13 会截断长 URL；这些都要用独立消融实验判断。
- 随机 80/20 容易让同域、同活动或同模板同时出现在训练与验证中，不能代表未来时间段和未见品牌。
- 专利页的法律状态显示为 Pending，同时明确其状态并非法律结论。技术上可以研究，但商业发布前要做独立的专利自由实施审查；本文不是法律意见。

建议对照实验采用三组：确定性规则、字符/子词轻量模型、词序列模型。不要预先指定双向 LSTM 为产品答案。

## 二、当前 Aegis 的真实覆盖范围

### 已实现

源码证据：

- `packages/core/src/phish/detector.ts` 与 `chrome/common/aegis/phish_score.cc`：原有 HTTP、IP、Punycode、子域、TLD 和 `@` 规则上，新增受保护品牌的数字替换/编辑距离 ≤ 1、品牌路径、凭据路径和已知短链原因。
- `chrome/renderer/chrome_render_frame_observer.cc` 与 `aegis_phish_tab_helper.cc`：所有 HTTP(S) 页面最多查 64 个表单、32 个 action、128 个 input；普通页不读正文，只在 URL 有风险或出现密码框时读最多 2 KiB。
- `aegis_phish_tab_helper.cc`：在 Browser 侧用 Chromium Public Suffix 规则比较 form action，“密码提交到其他注册域”作为高置信组合信号。
- `threat_feed_index.cc` 与 `threat_feed_updater.cc`：本地 `AEGISTI1` 二进制 SHA-256 索引、排序去重查询、新鲜度降级、原子持久化和 CERT.PL 后台更新；导航期不解析 CSV/JSON。
- `packages/core/scripts/compile-threat-feeds.mjs` 与 `threat-feed-lib.mjs`：CERT.PL、PhishTank `verified+online`、URLhaus 本地/网络 adapter，带大小、记录数、gzip 和密钥门。
- `aegis_phish_blocking_page.cc`：新原因均有中英文人类可读说明，威胁情报会显示来源名，不显示原始 hash。

### 代表性实测

2026-08-25—2026-08-26 使用当前 TypeScript/C++ 规则和 Release Browser 运行：

| 场景 | 当前结果 | 判断 |
|---|---:|---|
| `http://paypal-secure-login.tk/signin` + 密码框 + 催促语 | 95，拦截 | 已覆盖 |
| `https://login.microsoft.com.attacker.com/` + 密码框 + 催促语 | 80，拦截 | 已覆盖组合信号 |
| `https://micros0ft.com/` | 40，不单信号拦截 | 已识别数字替换；出现密码框后达 65 |
| `https://example.com/paypal/login` | 25，不拦截 | 路径品牌 + 凭据词只作辅助信号 |
| `https://bit.ly/example` | 15，不拦截 | 短链只提示隐藏去向，不单独定性 |
| `https://xn--pple-43d.com/login` + 密码框 | 65，拦截 | Punycode + 凭据路径 + 密码意图组合 |
| 普通 HTTPS `/login` + 密码跨注册域提交 | ≥ 55，拦截 | 跨站凭据提交门已生效 |
| 新鲜 PhishTank/URLhaus 精确 URL | +100，拦截 | 本地精确 hash 命中 |
| 新鲜 CERT.PL 域名 | +35，不单源拦截 | 与密码等页面证据组合后可拦截 |
| 过期情报 | +25，不单独拦截 | 降为辅助信号 |

当前 core 10 个文件 47/47、Chromium common Aegis 57/57、browser Aegis 37/37 通过。这些结果证明规则、索引和生命周期与固定样例一致，不等于在真实基率下已达发布级准确率。

### 按资料逐项映射

| 方法 | 当前覆盖 | 差距 |
|---|---|---|
| 查看真实 URL | 部分 | 内部已用可靠注册域边界；地址栏/链接预览的专属突出仍未做 |
| 拼写错误/数字替换 | 已实现有界子集 | 受保护品牌、数字归一化和编辑距离 ≤ 1；键盘邻近和更广泛品牌库仍未做 |
| Unicode 相似字符 | 很弱 | 只看是否含 `xn--`，没有解码、脚本分析或 skeleton 比较 |
| HTTPS 判断 | 已按正确方向组合 | HTTP 加风险；HTTPS 不减风险；普通 HTTPS 页也会进入轻量凭据检查 |
| 短链 | 部分 | 已知短链域是辅助原因；有界导航跳转链尚未实现 |
| 品牌放在子域 | 已改进 | C++ 用 Chromium Public Suffix 能力确定注册域 label |
| 品牌放在 path/query | 部分 | path 已检查；query key/value 默认不读 |
| 紧迫话术 | 部分 | URL 可疑或密码触发后读最多 2 KiB；不全页扫描 |
| 密码/凭据表单 | 已改进 | URL 0 分页也检查；已比较 form action 注册域；OTP/助记词类型待做 |
| 伪造视觉页面 | 无 | 没有 logo、布局或凭据意图视觉模型 |
| 已知恶意信誉 | 已有本地链 | CERT.PL 自动更新 + 三源离线编译；PhishTank/URLhaus 实时导入仍受密钥/许可门限 |
| 发件人/邮件上下文 | 无且超出范围 | 需要邮件客户端、邮件网关或独立集成 |

## 三、完善方案

### 总体原则

1. **多信号才阻断**：高置信组合进入拦截页；单一弱信号只提示或继续收集。
2. **凭据动作优先**：页面是否要求密码、OTP、助记词或付款，比单纯页面长得像谁更重要。
3. **热路径有界**：每次导航只做 O(URL 长度) 的规范化和索引查询；模型、截图、WHOIS、DNS 图和动态交互不进入默认热路径。
4. **解释必须来自证据**：只展示实际命中的确定性原因或模型固定标签，不让生成模型自由编造拦截理由。
5. **不把 HTTPS 当信任**：它只能证明连接被加密，不能证明站点身份合法。

### P0：先修基础检测盲区

目标：不用模型也能覆盖三份资料中浏览器可观察的大部分方法。

实施状态：**核心子集已完成**。已完成注册域边界、数字替换/编辑距离 ≤ 1、品牌/凭据路径、短链辅助原因和结构化证据；下列 UTS #39 skeleton、键盘邻近、query key、有界跳转链以及 `hard_block / warn / observe` 显式类型仍是未完成项。

1. URL 规范化与注册域：
   - 使用 Chromium 的 Public Suffix/registry controlled domains 能力提取 eTLD+1。
   - 解析 userinfo、非默认端口、IP、子域深度、host/path/query key；不记录 query value 或 fragment。
   - 区分“品牌正站”“品牌在非注册域标签中”“品牌只在 path/query 中”。

2. 品牌仿冒：
   - 对 Punycode 解码结果执行 [Unicode UTS #39](https://www.unicode.org/reports/tr39/) 的 mixed-script、restriction level 和 confusable skeleton 检查。
   - 对注册域 label 做长度有上限的 Damerau–Levenshtein/键盘邻近/数字替换比较。
   - 只在命中受保护品牌且真实 eTLD+1 不在品牌域集合时加高风险，避免把所有 IDN 都判为钓鱼。

3. URL 词序列：
   - 为 `login / verify / wallet / recover / update / invoice` 等词做语言无关的分隔符、camelCase、数字边界切分。
   - host、path 和 query key 分区评分；query value 默认不读取，降低隐私泄露和攻击者构造成本。
   - 先使用可审计规则；同时保留离线特征导出，供 P3 模型对照。

4. 短链和跳转：
   - 短链本身只提示“隐藏最终去向”，不能直接判恶意。
   - 在实际导航重定向中维护最多 8 跳、10 秒、同标签页的内存链；记录注册域和风险原因，不持久化完整 URL。
   - 短链/跨注册域跳转最终落到凭据页或品牌不一致页时进入高置信组合。

5. 规则合同：
   - 将评分改为结构化证据，区分 `hard_block / warn / observe`，不能只靠分数相加。
   - HTTPS、热门域或 allowlist 不能抵消无效 URL、明确信誉命中或跨域凭据提交等硬信号。
   - 移除“整个 TLD 天生危险”的独立阻断能力；TLD 只能作为弱信号。

### P1：凭据意图与用户感知

目标：补上“URL 看着普通、页面却偷凭据”的最大盲区，同时提升用户能感知的保护。

实施状态：**页面扫描和拦截解释已完成，提交时 UI 仍局部完成**。已实现全 HTTP(S) 轻量检查、固定 DOM 上限、条件式 2 KiB 文本、跨注册域 form action 和中英文证据提示。仍需补 OTP/助记词专属识别、真正 submit-time 再确认、SSO/支付负例库和地址栏/链接预览突出。

1. 两段页面采样：
   - 所有 HTTP(S) 页面只做极轻的凭据触发检查：是否存在密码/OTP/助记词输入、表单数量、form action 注册域。
   - 只有 URL 风险、凭据触发或跨域 form action 命中时，才读取最多 2 KiB 可见文本并检查紧迫语。
   - 表单、input、iframe 均设置固定遍历上限；导航取消、标签关闭和后台冻结时立即取消任务。

2. 凭据提交门：
   - 密码/OTP/助记词提交到不同 eTLD+1、HTTP、IP host、Unicode 品牌仿冒域或高风险跳转链时阻断。
   - OAuth/SSO、支付 iframe、企业 IdP 和密码管理器场景建立真实负例，不用简单“跨域表单即钓鱼”。
   - 隐藏 iframe 只作辅助证据，不单独阻断。

3. 感知方案：
   - 地址栏/链接预览突出真实 eTLD+1，次要显示完整 host。
   - 风险提示最多展示三个可操作原因，例如“页面自称 Microsoft”“真实域是 attacker.com”“正在索取密码”。
   - 对短链显示“正在跳转到 …”，最终域稳定后更新，不预测或主动访问链接。
   - 拦截页提供“返回安全页面”为主操作；继续访问放在二级路径，并记录为仅本机、仅当前 Profile 的一次性决定。
   - `chrome://aegis` 显示本次避免了什么动作，不展示模糊的“AI 已保护”口号。

[PhishXplain](https://arxiv.org/abs/2505.06836)报告上下文解释和标注页面线索能改善用户理解；较早的 [Alice in Warningland](https://www.usenix.org/conference/usenixsecurity13/technical-sessions/presentation/akhawe)也表明警告体验会明显影响用户是否继续访问。项目应复用“证据解释”的方向，但先用确定性模板，不默认调用云端 LLM。

### P2：本地信誉与隐私可选项

目标：补启发式发现不了的已知恶意站，同时不把完整浏览历史外发。

实施状态：**本地骨架与 CERT.PL 在线子集已完成**。三源 adapter、不可变 SHA-256 索引、原子写入、新鲜/过期证据强度和离线安装已落地；Browser 只自动更新公开 CERT.PL 列表。PhishTank/URLhaus 在线导入需本机密钥，ETag/随机抖动、源状态 UI、撤销/回滚固定样例和发布许可仍未关闭。

#### 候选数据源

| 数据源 | 内容与更新 | 免费/许可边界 | 建议 |
|---|---|---|---|
| [PhishTank](https://phishtank.org/developer_info.php) | 经社区验证、仍在线的钓鱼 URL；数据库每小时更新；自动下载建议申请免费 app key | 开发者页明确 API 免费；旧条款称 API Data 可免费商业使用，但当前页面又转向 Cisco General Terms，因此发布前仍需取得当前条款的明确确认 | **首选钓鱼源，本地原型可接入；发布许可设门** |
| [URLhaus](https://urlhaus.abuse.ch/api/) | 正在分发恶意载荷的 URL，不收钓鱼站；CSV/JSON dump 每 5 分钟生成；需要免费 Auth-Key | 2025-11 起社区 API 的免费范围明确偏向非营利，商业/盈利使用可能需要 Spamhaus 订阅 | **首选恶意下载源，仅本地研究免费；发布版需授权** |
| [CERT Polska Warning List](https://cert.pl/en/warning-list/) | 活跃危险域名，API/hosts/Adblock 格式约每小时更新，无逐 URL 查询 | 官方公共列表，但主要面向波兰攻击活动；再分发和全球产品使用仍要确认适用条款 | **补充源，只作区域/多源证据** |
| [OpenPhish Community](https://www.openphish.com/phishing_feeds.html) | 有限钓鱼 URL 文本，约 12 小时更新 | 免费社区版条款只允许个人用途，未经书面许可不得商业使用或向第三方再分发 | **只用于本地评测，不进入发布快照** |
| [Block List Project](https://blocklistproject.github.io/Lists/) | 聚合的 phishing/malware 域名列表 | 项目声明 Unlicense；但来源是 GitHub 聚合列表，来源质量和误报需独立验证 | **按当前“不使用 GitHub”要求延后；将来仅作佐证** |
| [Google Safe Browsing v5](https://developers.google.com/safe-browsing/reference) | Google 维护的恶意/社工 URL，支持本地 hash list、前缀查询、缓存和可选 OHTTP | 官方 API 仅供非商业使用，商业产品应使用 Web Risk | **独立授权路线，不伪装成免费发布依赖** |

“免费访问”不等于“可以随 Apache-2.0 浏览器自由再分发或用于商业产品”。因此本地开发可以先用 PhishTank、URLhaus、CERT.PL 做多源原型；发布版必须逐源冻结条款版本、归属、是否允许商业使用和是否允许再分发。

#### 集成方式

1. 后台更新而非逐导航查 API：
   - 独立 `ThreatFeedUpdater` 在后台按源更新，Browser 导航不访问第三方。
   - 支持 ETag/If-Modified-Since、指数退避、随机抖动和源规定的最小间隔；不因失败高频重试。
   - app key/Auth-Key 只放本机忽略配置或系统凭据存储，绝不写入仓库、补丁、日志或安装包。

2. 不信任下载内容：
   - 只用 HTTPS，限制压缩包/解压后大小、记录数、字段长度、解压比和解析时间。
   - PhishTank 只接收 `verified=yes && online=yes`；URLhaus 区分 active 与历史记录；非法 URL 和私网地址丢弃。
   - 下载、解析、规范化在临时文件完成，校验成功后原子替换；失败保留上一代有效快照。

3. 编译本地不可变索引：
   - 对规范化 URL、host+path 和 eTLD+1 分层生成 SHA-256；Bloom filter 只能作负向预筛，命中后必须用完整 hash 集确认，避免 Bloom 误报直接拦截。
   - Browser 在后台有界读取 `threat-index.bin` 为不可变排序 hash 向量，按 generation 原子切换；导航热路不解析 CSV/JSON，也不持有原始 URL 字符串。
   - 快照记录源、抓取时间、上游时间、条款版本、记录数、SHA-256 和编译器版本；未来若由 GCSA 服务器再分发，manifest 必须使用离线发布密钥签名。

4. 按证据强度处理：
   - 新鲜的 PhishTank verified+online **精确 URL** 或 URLhaus active **精确 URL** 可进入硬阻断候选。
   - 只有 host/domain 命中时先提示；共享托管、CDN、对象存储和被入侵的合法站点不能因单个恶意 path 封整个域。
   - CERT.PL、OpenPhish 社区版和聚合域列表只作第二来源或灰区加分，不凭单源直接硬阻断。
   - 快照过期后从“阻断”降为“提示”，再超过保留期后停用，避免已清理站点长期误杀。

5. 用户与隐私：
   - 拦截页说明“命中哪个来源、记录何时更新、命中的是完整 URL 还是域名”，不显示内部原始 hash。
   - `chrome://aegis` 显示各源启停、最后成功时间、记录数、快照新鲜度和许可状态。
   - 默认不持久化用户访问的完整 URL；Incognito 共享只读信誉快照，但不写命中历史和每页缓存。

6. 现有 Chromium 能力：
   - Aegis 已有自己的本地信誉链，但不能因此宣称取代了 Chromium Safe Browsing；仍需独立审计当前构建的 Safe Browsing API key、更新状态和真实出站。
   - 第三方 API 上线不列入 P0/P1 完成条件；先在本地离线快照、无密钥失败、损坏 feed、陈旧 feed 和撤销条目场景跑通。

#### 本地使用

```bash
# 编译一个公开 CERT.PL 快照
pnpm threat-feeds:compile -- \
  --out .artifacts/threat-index.bin \
  --cert-pl https://hole.cert.pl/domains/v2/domains.txt

# 安装到 Release 的 Default 浏览器 Profile；浏览器运行时会拒绝覆盖
pnpm threat-feeds:install -- \
  .artifacts/threat-index.bin \
  "$HOME/Projects/GCSA-aegis-chromium/profiles/AegisRelease" \
  Default
```

PhishTank 和 URLhaus 网络导入分别需要 `PHISHTANK_APP_KEY` 和 `URLHAUS_AUTH_KEY`。编译器只从进程环境读取，不写入索引、日志或仓库。

### P3：专利与 PhishLang 启发的灰区模型

目标：提高新型 URL 和页面语义召回，不增加普通网页的持续 CPU。

候选：

- 字符/子词 URL 小模型：对数字替换、随机串和多语言更稳健，输入最小。
- 词序列 URL 模型：验证专利思路，但保留 TLD、host/path 分区，不限定英文词典或长度 13。
- [PhishLang](https://arxiv.org/abs/2408.05667) 类轻量页面上下文模型：只在 20–54 分或凭据触发的灰区页运行。

执行约束：

- Browser 进程只调度；推理在独立有界 Worker/utility process，低优先级、可取消、页面隐藏后暂停。
- 不运行 3B/8B 通用 LLM、AST、动态沙箱或全页源码分析作为默认检测。
- 输入为 URL token、固定结构信号和有上限的可见文本；不持久化完整页面内容。
- 模型只能输出固定标签和置信度；拦截理由仍须绑定到可验证证据。
- 任何模型在取得独立、时间切分和真实基率结果前，仅 report-only，不参与拦截。

### P4：视觉/品牌意图只作为研究能力

[Phishpedia](https://www.usenix.org/conference/usenixsecurity21/presentation/lin)用 logo 识别和品牌域比较增强可解释性；[PhishIntention](https://www.usenix.org/conference/usenixsecurity22/presentation/liu-ruofan)进一步结合品牌意图、凭据意图和动态交互，降低单看 logo 的误报。

本项目只建议：

- 在“有凭据意图但品牌无法确认”的高风险灰区，对缩小后的可见区域截图做本地 logo/登录布局分析。
- 视觉结果不能单独阻断，必须结合真实域不匹配或凭据意图。
- 不在用户真实 Profile 中自动点击、填写或动态探索不可信页面；需要动态研究时放到隔离的离线爬虫环境。
- 视觉模型默认关闭。USENIX Security 2025 的[大规模真实评估](https://www.usenix.org/conference/usenixsecurity25/presentation/ji)发现，多种视觉相似检测器在真实数据上明显弱于整理过的实验数据，并能被去 logo、伪装良性 logo 或直接攻击流水线绕过。

## 四、验证与发布门

### 当前实测证据

- `pnpm quality:fast`：core 10 个文件 47/47，lint、typecheck、构建、仓库合同和 Browser 脚本门通过。
- Release 原生定向测试：common Aegis 57/57，browser Aegis 37/37。
- Release 真实站点：`ip.gcsa.org`、Example、Wikipedia、BrowserLeaks Canvas、Cloudflare、YouTube 6/6，0 dump、0 FATAL。
- Release CDP 运行门：4/4，覆盖一次性精确文档授权、失败握手消耗、公开页并发和跨文档失效。
- Release 跨站凭据 fixture：URL 自身低于阻断阈值，但页面密码表单提交到其他注册域后显示中文 Aegis 拦截页和“密码会被提交到另一个网站”，1/1，0 dump、0 FATAL。
- 三源代表索引 4 条的 Release 端到端验证通过：Browser 确认加载索引，PhishTank 精确 URL 显示中文 Aegis 拦截页和来源名，0 dump、0 FATAL。
- 根仓库标准安装命令已把代表索引原子安装到临时 `Default/AegisThreatFeeds/threat-index.bin`，文件权限为 `600`；相对路径按命令调用目录解析。
- 公开 CERT.PL 实际编译为 138,767 条、4.8 MiB 索引。PhishTank/URLhaus 无密钥会 fail closed，本轮未使用生产密钥。
- 新增的 3×15 秒 `ip.gcsa.org` 回归烟测：Aegis ON/OFF 进程树 CPU 中位数为 24.60%/23.47% 单核等价，差 1.13 个百分点，6/6 为 0 dump、0 FATAL。这只是本轮页面扫描的回归烟测；正式长窗口结论仍以项目已有 5×60 秒协议为准。

机器可读证据保存在未跟踪的 `.artifacts/`，不进入产品提交。上述证据关闭了实现和本地运行子门，没有关闭发布许可、真实基率误报、产品签名/公证和 Android 门。

### 数据与拆分

- 钓鱼正例：至少两个独立公开 feed 的时间快照、隔离环境自建捕获和定向对抗样本；保存来源、时间和标签依据。
- 良性负例：真实热门站、长尾站、合法 IDN、多级子域、短链、OAuth/SSO、支付、银行、企业 IdP、开发/测试域和共享托管。
- 去重必须按 eTLD+1、证书、页面模板和活动聚类；同一活动不得跨训练/测试。
- 正式集采用时间切分、域隔离和品牌留出；另设一次性 sealed test，禁止看结果后调阈值。
- 以真实基率重加权，报告每 10,000 次导航产生的警告/误报；随机平衡数据上的 Accuracy 不作发布指标。

### 建议门槛（目标，不是当前成绩）

检测门：

- 硬阻断：代表性基率下 Precision ≥ 99.9%，良性导航 FPR ≤ 0.01%。
- 提示：Precision ≥ 99%，良性导航 FPR ≤ 0.1%。
- 对编辑距离、Unicode confusable、品牌子域、短链跳转、路径品牌词、跨域凭据、无 logo 仿冒分别报告 Recall，不能只报总分。
- allowlist/用户反馈不得削弱无效 URL、明确信誉命中和跨域凭据提交的硬保护。

性能门：

- URL 确定性层：桌面参考设备 p95 ≤ 0.25 ms/导航，p99 ≤ 1 ms，无网络、无主线程模型。
- 凭据触发检查：p95 主线程占用 ≤ 2 ms/页面；超限立即降级，不反复扫描 DOM。
- 灰区模型：仅后台进程，预热后 p95 ≤ 25 ms/候选页；超时 100 ms 取消，不阻塞导航提交。
- 继续沿用项目整页门：Aegis ON 相对 OFF 的稳态均值增量不超过 3 个单核百分点或 OFF 基线 10%（取较大值），0 Renderer/GPU 崩溃、0 Mojo/FATAL。

隐私门：

- 默认不持久化完整 URL、query value、页面文本、截图或浏览历史。
- Profile、Incognito 和网络隔离键分区；Incognito 只用内存数据。
- 任何远端查询必须在设置中说明发送字段、接收方、缓存与关闭方式，并有 ON/OFF 出站实测。

### 测试矩阵

1. 单元：URL canonicalization、eTLD+1、UTS #39、编辑距离、token 化、reason contract、阈值单调性。
2. 原生：TypeScript 与 C++ 同输入同输出；导航取消、文档替换、错误页、后退/前进、一次性继续访问。
3. 对抗：Punycode、混合脚本、零宽字符、`@`、IP、非默认端口、5+ 子域、短链多跳、品牌 path/query、无 logo、伪 logo、隐藏 iframe。
4. 兼容：OAuth/SSO、企业登录、支付、银行、合法 IDN、密码管理器、CAPTCHA、二维码登录。
5. 运行时：至少 20 个普通站 + 控制钓鱼页，多标签、后台标签、低性能设备；对照 Aegis ON/OFF CPU、内存和网络。
6. 用户感知：原因理解率、真实域识别率、继续访问率和关闭提示率；不能只测试“用户喜欢不喜欢”。

## 五、实施顺序与完成标准

### 阶段 A：P0 确定性 URL 层（核心子集完成）

完成标准：六个当前漏检代表例都有明确 reason；普通 HTTPS、合法 IDN、OAuth/SSO 负例不被阻断；TypeScript/C++ 一致；性能门通过。

### 阶段 B：P1 凭据意图与感知（扫描/拦截完成，交互子项未完成）

完成标准：URL 0 分的仿冒凭据页也进入检查；跨域 form action 有解释；页面扫描有上限；地址栏/拦截页能让用户读出真实注册域；真实站回归无崩溃。

### 阶段 C：P2 离线信誉原型（本地骨架/CERT.PL 完成）

完成标准：PhishTank、URLhaus 和 CERT.PL adapter 能在本地按各自条款更新并编译同一不可变索引；快照可校验、原子切换、回滚和按新鲜度降级；损坏 feed、撤销条目、无 API key、429/5xx 均有测试；导航默认无完整 URL 外发；未取得发布许可的源不进入发布包，也不宣称已接入实时 Safe Browsing。

### 阶段 D：P3 模型离线竞赛（未开始）

完成标准：规则、字符/子词模型、词序列模型在同一时间/域/品牌隔离协议下比较；只有显著提高灰区 Recall 且不突破误报、CPU、内存门的候选才能进入 report-only。

### 阶段 E：P4 视觉研究（未开始）

完成标准：先复现 USENIX 2025 指出的无 logo、伪 logo和流水线绕过；通过真实数据与资源门后才讨论产品化，默认仍关闭。

### 发布顺序

1. 本地 Git 分支实现与离线测试。
2. 本地 Chromium Release 构建、独立 Profile、真实站和控制钓鱼页验证。
3. report-only 观察，不改变用户导航。
4. 先启用提示，再只对多信号高置信场景启用阻断。
5. 本地全部跑通并经确认后，才考虑 GitHub、外部数据更新或发布。

## 六、本轮交付结论与后续退出条件

本轮已完成并本地提交的范围：

- Browser-only 确定性 URL 改进、有界页面凭据检查、跨站 form action 证据与人类可读拦截理由。
- PhishTank、URLhaus、CERT.PL 三源 adapter，与 Chromium 共用的 `AEGISTI1` 不可变索引和默认 Profile 安装路径。
- Browser 侧 CERT.PL 低优先级后台更新，严格下载/记录上限、原子写入、新鲜度降级和无导航时远程查询。
- Release 多站点、CDP、跨站凭据拦截、精确情报拦截和 3×15 秒 CPU ON/OFF 子门均通过。

不得随本轮一起宣称完成的项目：

- UTS #39、跳转链、OTP/助记词、提交时再确认、情报源 UI/撤销、大规模误报评测、P3 模型和 P4 视觉研究。
- PhishTank/URLhaus 在线导入：代码已就绪，但本轮没有生产密钥，且发布/商用/再分发许可仍是独立门禁。
- OpenPhish 不进入发布快照；Block List Project 仍按“不使用 GitHub”要求延后。
- 产品身份、正式签名/公证、安装包、Android/Linux 当前源码构建和真实基率发布指标。

因此，本轮目标“在集成式 Browser 中接入有界钓鱼检测和免费威胁情报，并证明不再造成普通网站崩溃或明显稳态 CPU 放大”已完成本地验收。GitHub、外部发布和产品密钥仍未使用。
