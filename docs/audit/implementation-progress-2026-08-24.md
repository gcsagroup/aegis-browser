# GCSA-aegis 本地实施进度

- 日期：2026-08-26
- 当前阶段：49 补丁的 macOS official 语义本地构建、原生定向测试、钓鱼/本地威胁情报、`ip.gcsa.org` CPU/崩溃回归和 Release 多站点稳定性子门已通过；M3–M6 完整产品门仍在进行
- 当前结论：跨序列 Renderer 崩溃和 GPU 诊断致死→软件合成放大链已关闭；项目整体仍为 **No-Go**，当前 non-component build-tree App 不是 RC 或分发包
- 产品边界：只交付集成式 Chromium Browser，不保留、不构建、不分发 Extension
- 上一轮跨序列崩溃修复：根仓库 `04df1c4`；Chromium checkout `969aa19d45`。本轮钓鱼与情报集成后的 Chromium checkout 提交为 `cf0f5f3bfbb289520dcc6e9a39f648d5da115f46`。
- 外部协作边界：仅本地 Git；未执行 GitHub fetch、pull、push、PR、Release、tag 或远程 CI
- 发布边界：不使用生产签名密钥，不公证，不上传 Play，不公开发布

## 已完成

### 1. Browser-only 与可重放补丁链

- 根仓库与 Chromium checkout 均使用本地分支 `codex/aegis-local-dev`；`.artifacts/` 中的恢复和运行证据保持未跟踪，没有混入产品提交。
- Chromium 官方 base 固定为 `ff37cfca210138f2a40b843b4a8195ab7e4fc7ff`，当前 checkout HEAD 为 `cf0f5f3bfbb289520dcc6e9a39f648d5da115f46`。
- 当前 `series` 包含 49 个补丁，SHA-256 为 `43db8760d13a9dc2d7ee24fd13167bcc6e7d446f317899103083d22b70c456b3`。
- `browser:status` 确认 checkout 保留补丁导出时的原始 commit 身份，49/49 稳定 patch-id 匹配，117 个 overlay 文件与 checkout 一致，checkout 干净。

### 2. 本轮安全、生命周期与性能修复

- `ip.gcsa.org` 会加载被 EasyPrivacy 命中的 `static.cloudflareinsights.com`；原实现从 URLLoader 后台序列直接调用绑定在 Renderer 主序列的 Mojo Remote，触发 `multiplex_router.cc:154` 序列 DCHECK，并只杀死当前标签页 Renderer。
- `BlockReporter` 现将阻拦、CNAME、Referer 和参数事件按值复制，并统一 `BindPostTask` 到注册方序列；Browser 与 Renderer 都使用 WeakPtr 保护重绑、Profile Shutdown 和析构后已排队任务。
- 新增跨线程投递、Cloudflare/CNAME payload 与目标销毁回归；锁外旧回调最多投递到已失效 WeakPtr，不再访问已 reset 的 Remote。
- Ollama 桌面摘要已增加最终 POST 请求体回归，验证结构化提示词与 browser 边界再次 fail-closed 校验后不再携带原始测试 PII。
- Omnibox AIM eligibility 的生产服务端请求默认 fail-closed；测试 factory 仍单独保留正向覆盖，不能扩大表述为 Chromium 全部 Google 出站已关闭。
- `UserFmRegistrationTokenUploader` 只在 Profile 初始化、Core 连接且企业 policy client 已注册后创建 listener；断连重连保持一次性启动语义，Shutdown 会解除观察并清空内部 uploader 集合，其析构会停止共享 listener。
- Release profile 生命周期在退出前显式释放，最终 App 的受控 SIGINT 运行返回 0。
- 原 Release 使用 `is_official_build=false`，使 `DUMP_WILL_BE_CHECK` 在合成器 damage invariant 上变成 FATAL；现场 5 次 GPU 连续崩溃后回退到软件合成。当前 Release 改为 official 构建语义，并保留上游诊断；这关闭致死放大链，不代表底层 invariant 已从 Chromium 上游修复。
- Filter List path fallback 从全锁扫描 5,740 条规则改为按 host 后缀索引，并在锁外构建不可变候选表；Canvas farbling 去掉同尺寸临时 vector 与整图拷入/拷回。
- 钓鱼检测已新增品牌数字替换/编辑距离、路径与短链证据、全 HTTP(S) 有界凭据检查、跨注册域 form action 和中英文可解释拦截。
- 本地情报链已新增 PhishTank/URLhaus/CERT.PL adapter、`AEGISTI1` SHA-256 索引、新鲜度降级、原子持久化和 CERT.PL 后台更新；导航期不向情报源发送完整 URL。

### 3. macOS 构建与产物证据

- `out/AegisLocalDev/Chromium.app` 的 component 开发构建和 `out/AegisRelease/Chromium.app` 的 non-component official 语义 Release build-tree 构建均已按当前 HEAD 完成。
- 本轮 Release 完整重建共 54,505 个本地步骤，3 小时 28 分 39 秒成功；紧接着增量执行显示 `ninja: no work to do`。Chromium 自带 App 库依赖验证通过。
- 状态复核一度发现 `out/AegisRelease/Chromium.app` 打包目录缺失，但对象缓存、Framework 和测试目标仍完整；只执行 `autoninja -C out/AegisRelease chrome` 后 77 个本地复制/验证步骤、4.52 秒恢复 App，随后再次增量为 `no work to do`。没有清理构建缓存或用户 Profile。
- `chrome/installer/mac:mac` 已构建，但该 GN 目标只是 installer 支持工具组，不会生成 ZIP 或 DMG，不能作为打包完成证据。
- Release App 为 arm64、non-component，367,884 KiB（约 359 MiB）；Bundle ID 仍为 `org.chromium.Chromium`，显示名仍为 `Chromium`，版本为 `151.0.7922.77`。
- 最终干净源码重建并重新 ad-hoc 签名后的 Release launcher SHA-256 为 `6c059691547be4f8904c2975674202724337145138bf103e8254dcfbbe1bf3ca`；Framework SHA-256 为 `b2cc05770b4f6d399e3c7b42a3344be873ec3ae7d1f3ba9c71625ef5713856bd`。
- LocalDev 与 Release build-tree App 均已重新做本地 ad-hoc 签名，`codesign --verify --deep --strict` 通过；Bundle ID 仍为 `org.chromium.Chromium`、无 TeamIdentifier，因此不能视为正式签名或分发证据。
- 默认开发输出为 `out/AegisLocalDev`；49 补丁后 LocalDev 和 Release 均已重新构建，最终 `browser:status` 为 0 个失败、1 个 Android/Linux 未构建警告。

### 4. 本地测试结果

- `pnpm quality:fast` 通过：10 个 Vitest 文件、47/47 用例，以及 lint、typecheck、合同、Browser 脚本和生成物检查全部通过。
- Release `aegis_unittests`：57/57 通过；含威胁索引往返/命中/合并、截断/乱序拒绝和单标签域名拒绝回归。
- `autoninja -C out/AegisLocalDev chrome` 的历史 component 门与本轮 non-component official 语义 `out/AegisRelease` Browser 完整重建均通过。
- `aegis_browser_unittests --single-process-tests`：37/37 通过，包含页面信号文档生命周期和有界采集回归。
- `AimEligibilityServiceTest.*`：30/30 通过，包含生产禁用路径；测试 factory 的 server-request 正向 Browser 门：1/1 通过。
- policy FM/GCM 生命周期定向测试：10/10 通过。
- 较早的 component App 所选 CDP 运行场景 4/4 通过，只作开发证据。
- 0049 后的当前 Release App 已重跑 CDP 4/4 场景并通过，覆盖单次初始文档授权、失败握手消费、公开页并发和跨文档失效。
- CDP 运行门使用测试专用 mock Keychain，只能证明所选本地场景；不覆盖真实 Keychain、产品签名、全部 CDP 能力或 Android。
- 新增启动前脚本门与 fixture：错误 GN 类型、早于 checkout HEAD 的产物和活跃 Profile `SingletonLock` 都会硬失败；`test:scripts` 同时执行 status/run fixture 与两个 Node 运行门语法检查。
- Release 默认全开和 `AegisEnabled` 全关各完成 6 个真实站点，均为 6/6；Tracker、Filter List updater、Link Sanitize 单关和三者组合关闭各完成 3/3。合计 24 次页面导航全部正文可读，0 临时/全局新增 dump、0 FATAL。该矩阵只证明生命周期稳定，不证明各开关的功能行为。
- 多站点门收紧为“受控退出后再读取 dump/日志”时曾捕获 1 个测试工具诱发的 nonfatal dump：`7b1d432b-05eb-4db3-98c0-09717955865f.dmp`，SHA-256 `ecc81fd9bdfee556fae3aa9d7dedd9ab4dd0648fbe0205e4f828436be112b669`。Minidump 与日志均指向 `browser_tabstrip.cc:124` 的 `CloseWebContents called for tab not in our strip`；原因是工具对已跨文档导航的 target 调用 `/json/close` 后立刻退出。工具改为只关闭 CDP socket、由 Browser 统一关闭标签页后，默认 6/6、全关 6/6、四组 3/3 和三组出站门均在退出后为 0 新 dump、0 FATAL；失败 dump 保留在全局 Crashpad，未删除。

### 5. 运行与界面证据

- 修复后的 Release App 使用独立临时 Profile 实际访问 `https://ip.gcsa.org/`；过滤列表编译后，原页面和另外 5 个并发目标页均保持 `GCSA | IP 信息檢測工具`，Renderer 存活且日志没有 Mojo DCHECK/FATAL。
- 修复后的 LocalDev App 已用 Computer Use 做真实界面验收并连续刷新 5 次；每次都保留完整网页、IP 信息和连通性区域，没有出现“喔唷，崩溃啦！”或错误代码 6。
- 当前 official 语义 Release 以 Aegis ON/OFF 各 5 次、每次预热 30 秒后采样 60 秒。ON/OFF 总 CPU 中位数为 21.10%/26.72%，配对 `OFF - ON` 中位数为 3.12 个单核百分点；没有稳定额外 Aegis 开销。10 次共 600 秒均为 0 GPU 重启、0 软件合成回退、0 新 dump 和 0 合成器/FATAL 信号。
- 0049 新页面扫描后另执行 3×15 秒 `ip.gcsa.org` 回归烟测：Aegis ON/OFF 中位数 24.60%/23.47% 单核等价，差 1.13 个百分点；6/6 均0 dump、0 FATAL。该烟测只排除明显回归，不取代上述 5×60 秒正式协议。
- 三源代表索引已注入当前 Release 的临时 `Default` Profile；Browser 日志确认加载 4 条，PhishTank 精确 URL 显示中文 Aegis 拦截页和来源，0 dump、0 FATAL。公开 CERT.PL 另实际编译为 138,767 条、4.8 MiB。
- URL 本身低于阻断阈值的本地密码表单，提交目标切到其他注册域后在当前 Release 显示中文 Aegis 拦截页和跨站凭据原因，1/1、0 dump、0 FATAL；根仓库标准安装命令也已验证 Default Profile 路径与 `600` 权限。
- 本轮 CPU 门前后全局 Crashpad pending dump 数量均为 34，全部临时 Profile 新增 dump 为 0；测试实例已受控退出，CPU Profile 已删除，Release UI Profile 已移到废纸篓以保留可恢复性。
- 0042 阶段的 Release App 曾使用干净临时 Profile、mock Keychain 和外部域名 fail-to-resolve 映射启动；SIGINT 正常退出，日志未发现 fatal、crash、dangling、AIM 或 policy FM/GCM 关键字。该历史运行只映射到当时相同 launcher 字节，不等同安装 App 证据。
- 同一启动日志仍出现 on-device model、SODA、FACS 和过滤列表相关的更新或请求失败。因此只能证明本次受控生命周期，没有证明“零遥测”或“全部出站关闭”。证据保存在 `.artifacts/runtime-2026-08-25/release-startup.log`。
- 本地产品页已用 Browser 实测：简中、繁中、英文切换正常；1280、768、390 px 三种视口均无横向溢出，控制台 0 错误，No-Go 和非 Extension 边界可见。
- 最终 non-component Release build-tree App 已用 Computer Use 完成可视验收：本轮按完整 App 路径确认命令行来自 `out/AegisRelease`；`ip.gcsa.org` 完整渲染，`chrome://gpu` 的 Canvas/Compositing/WebGL/WebGPU 均为硬件加速且 GPU crash count 为 0，`chrome://aegis` 的 8 个隐私模块默认开启、AI Control 默认关闭。此前 1318/922/约 742 px 布局门也已通过；这些结果不替代签名安装 App 验收。
- 新增 Release 多站点门后，默认全开实际通过 `ip.gcsa.org`、Example、Wikipedia、BrowserLeaks Canvas、Cloudflare 和 YouTube 6/6；Aegis 全关同样 6/6。每次使用 `mkdtemp` Profile、完整 Release 路径、mock Keychain 与受控退出，不会关闭未知或用户已有进程。
- 出站观察固定从 `about:blank` 启动 20 秒，以 NetLog `REQUEST_ALIVE` begin 事件统计 URL 请求。默认组出现 5 个请求主机：`accounts.google.com`、`clients2.google.com`、`easylist.to`、`edgedl.me.gvt1.com`、`update.googleapis.com`；background-quiet 诊断组仍是同 5 个主机，仅部分请求次数下降。因此“全部后台出站关闭/无遥测”明确未通过。
- `ip.gcsa.org` + Example 的混合浏览观察本轮出现 28 个 URL 请求主机；该数量会随页面依赖和网络时序变化。页面本身会探测 GitHub、流媒体、字体、STUN 等服务，不能与 Chromium 后台请求混为一谈。机器可读证据为 `.artifacts/runtime-2026-08-25/outbound-startup-only.json`、`outbound-startup-quiet.json` 和 `outbound-observed.json`；报告只保留主机汇总与原始 NetLog SHA，成功后的原始 NetLog 已删除。
- 更新启动门后再次用 Computer Use 验收：`chrome://version` 的命令行与可执行文件路径精确指向 `out/AegisRelease/Chromium.app`，Profile 为独立 `AegisReleaseAcceptance`；`ip.gcsa.org` 与本地产品状态页可打开，简中、繁中、英文的新证据口径均可读。验收实例通过应用菜单退出，随后该 Profile 的进程数为 0。

## 当前 No-Go 原因

- Release App 仍是 stock Chromium 身份且只有本地 ad-hoc 签名；严格签名结构校验虽已通过，但没有产品 Bundle ID、TeamIdentifier、公证或渠道信任链。
- 尚无产品 Bundle ID、正式嵌套签名、公证、ZIP、DMG、安装后 10 次独立启动和升级/设置保留证据。build-tree App 不是 RC。
- Chromium 完整出站/遥测审计仍未完成；AIM 与 policy FM/GCM 只是精确局部门禁，不能推导为全部 Google/GCM 或全部 Chromium 出站关闭。
- Tracker、Filter List、Link Sanitize、Cookie、摘要与指纹等仍缺功能行为组合矩阵和启动压力验证；当前 24 次导航只关闭了生命周期稳定性子门。
- Android 没有可复现的 x86-64 Linux 当前源码构建、当前 APK、普通网页摘要修复和 Pixel 真机验收；历史 APK/ADB 结果只能作为历史证据。

## Android 只读前置结论

- Pixel 9 Pro Fold 历史 ADB 门禁通过，设备为 Android 17/API 37、`arm64-v8a`。
- `$HOME/Desktop/GCSA-aegis.apk` 是历史 APK，SHA-256 为 `44882b2b26dc74d65ef03a2f8986e7a43d055a8b7d90a5e356f90f081f8bc3f1`；它不能映射到当前开发分支。
- 当前 macOS、Docker 与 UTM 条件不能替代计划规定的干净 x86-64 Linux 构建门。M5 在获得当前源码 APK 并修复 Android 普通网页摘要前保持阻塞。

## 下一退出条件

1. 完成产品身份、正式签名或明确的内部签名方案、ZIP/DMG、安装后界面与 10 次独立启动门。
2. 完成 Chromium 出站/遥测清单、受控流量证据、代表性站点组合回归与启动压力验证。
3. 在干净 x86-64 Linux 环境生成当前源码 APK，修复普通网页摘要，并完成 Pixel 真机验收。
4. 生成 App、ZIP、DMG、APK 的 SHA-256 与根 SHA、Chromium SHA、series SHA、GN 参数映射。
5. 上述本地 M2–M6 门全部通过并再次获得用户确认前，继续只使用本地 Git，不启用或访问 GitHub。
