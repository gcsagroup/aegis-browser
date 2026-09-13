# GCSA Aegis 设置与内置页面文案检查

检查日期：2026-09-13。本文保留初始 003 版本审计事实；整改进度及最新结果见[实施验收记录](ui-copy-acceptance.zh-CN.md)。

结论：问题并不限于关于页。需要先修正版本、模型连接和数据发送的说明，再统一品牌名称、功能用语和三语文案。不能用全局替换 Chrome / Chromium 的方式处理。

## 检查范围与证据

实机对象为 `/Users/lazy/Applications/GCSA Aegis Test.app`，进程路径已核对；关于页显示 `Ver 1.1 (003)`、`Chromium 151.0.7922.77 (arm64)`。通过 Computer Use 操作原生浏览器，读取页面和无障碍文本，并检查下载设置、防护中心的实际截图。

| 范围 | 本轮检查情况 |
| --- | --- |
| 设置全部 13 个主页面 | 自动填充和密码、隐私与安全、性能、外观、搜索引擎、默认浏览器、起始页面、语言、下载内容、无障碍、系统、重置设置、关于页均已打开 |
| 设置子页及展开状态 | 搜索引擎管理、安全、安全检查、网站设置、第三方 Cookie、自动填充设置展开区、隐私指南欢迎页及第一步、重置确认弹窗已查看 |
| 常用内置页 | 新标签页、历史记录、书签、扩展程序、下载记录及新建下载表单已查看 |
| GCSA 自有页面 | 防护中心、AI 助手任务页、模型配置展开区、自动化页已查看 |
| 源码补查 | 自有页面文案、工具栏防护弹窗文案、Chromium 品牌资源、更新状态、模型配置状态、重置报告发送路径、简繁体分流方式 |

边界：本轮完成主入口覆盖及重点子页检查，不能视为每个权限子页、每个错误弹窗和所有语言的穷尽验收。密码管理独立页面、导入弹窗、无痕页、证书错误及钓鱼拦截页未完成实机补查。后段窗口读取仅返回设置导航菜单，重新获取窗口及重置控制会话后仍未恢复完整页面读取，故这些页面保留为待验收；不会用源码检查冒充实机检查。繁体、英文为源码检查，未切换系统或浏览器语言。

未执行重置、清除数据、修改防护开关、提交 AI 任务、创建自动化或发送诊断报告。导航输入过程中一次冒号未被键入，产生了一次普通 Google 搜索，随后已改用地址栏赋值并验证目的页面；因此本轮会留下浏览导航记录。

## 优先修正：状态和数据说明

### UI-01 安全检查与关于页的更新结论冲突（高）

- 实机：关于页提示 GitHub 尚无正式版；安全检查却显示“Chromium 已是最新版本”，下方为“版本 151.0.7922.77（正式版本）”。
- 源码：安全检查的版本卡片把 `BuildState::UpdateType::kNone` 直接映射为已更新、安全状态；它没有读取 GCSA GitHub 更新检查结果。
- 建议：优先显示产品版本，内核版本作为次要信息。检查尚未完成时显示“尚未检查更新”；无正式版显示“暂无可用的正式版更新”；安装包就绪仍须显示“待手动安装”。关于页与安全检查复用相同的产品更新状态。
- 验收：未检查、无正式版、请求失败、有新版、下载中、校验失败、安装包就绪逐项比对，两个页面不得给出矛盾结论。

### UI-02 “AI 已连接”实际只代表配置有效（高）

- 实机：模型卡片显示“AI 已连接”。
- 源码：`modelConfigured` 只检查是否保存了服务格式、地址、模型名，以及它们是否符合格式要求；页面据此显示“AI 已连接”，没有以本次连接请求结果为条件。
- 建议：现有状态直接改成“已配置模型”。只有真实检测成功才显示“连接测试通过”，并显示检测时间；失败提示具体原因。
- 验收：保存合法但不可达的服务地址，不能出现“已连接”；已有配置也不能在重启后自动当成刚刚检测成功。

### UI-03 重置弹窗的报告对象不明确（高）

- 实机：默认勾选“报告当前设置，协助我们改进 Chromium”。
- 源码：重置完成且允许反馈时存在报告发送路径；目标配置为 `https://sb-ssl.google.com/safebrowsing/clientreport/chrome-reset`。
- 证据边界：本轮未执行重置、未发送报告，也未验证该端点实际接收成功。
- 建议：GCSA 版本移除这项上游报告入口及对应发送路径。如果决定保留，则必须明示接收方为 Google、列出发送项目，并采用明确的主动选择，不能只把“Chromium”改为“GCSA”。
- 验收：检查对话框和实际发送条件，确保普通重置行为与报告选项一致。

### UI-04 “本地隐私摘要”与远程模型配置不一致（高）

- 实机及源码：隐私设置入口写“跟踪器拦截、指纹防护与本地隐私摘要”；防护中心允许用户设置远程模型服务，并有发送前确认流程。
- 建议：入口改成“跟踪防护、指纹防护与网页摘要”。摘要前动态显示“在本机处理”或“发送至所选模型服务”，保留目标服务地址、数据范围和确认说明。
- 验收：分别覆盖本机与远程服务，入口和处理说明不得将远程处理描述为本地处理。

### UI-05 上游云端功能入口需要按可用性整理（高）

- 实机：自动填充设置展示禁用的“增强型自动填充功能”，并说明网页网址和内容会分享给 Google。隐私指南仍介绍 Google 账号书签及商品降价提醒。安全页保留 Google 安全浏览、高级保护计划等说明。
- 建议：逐项核对当前构建是否支持、服务由谁提供、数据发送到哪里。不可用功能移除或说明不可用原因；实际使用的第三方服务保留供应商名称和数据说明。
- 不应仅因出现 Google 就删除文字：Google 搜索、Google 翻译、Chrome 应用商店是服务名称，不能冒充 GCSA 自有服务。
- 验收：页面可见性与实际能力一致；禁用功能不再无解释地占据主要设置区。

## 品牌与常用页面

| 编号 | 已确认的位置或原文 | 建议 |
| --- | --- | --- |
| UI-06 | 关于页、防护中心、设置入口为 `GCSA-aegis`；窗口和部分菜单为 `GCSA Aegis` | 用户界面统一 `GCSA Aegis`；代码标识、下载资产命名、内部地址另行保留 |
| UI-07 | 默认浏览器：“将 Chromium 设置为默认浏览器” | “将 GCSA Aegis 设为默认浏览器”；按钮“设为默认浏览器” |
| UI-08 | 新标签页：“自定义 Chromium” | “自定义此页”；Gmail、Google 应用等快捷入口是否保留按产品范围决定，不伪装服务来源 |
| UI-09 | 历史侧栏：“Chromium 历史记录” | “浏览历史”；“从其他设备打开的标签页”须核对同步能力再决定可见性 |
| UI-10 | 性能页省内存、节能、预加载多次提及 Chromium | 优先用“浏览器”，必要时用 GCSA Aegis；例如“释放闲置标签页的内存。再次打开时会重新加载。” |
| UI-11 | 外观页无障碍名称“Chrome 面板”；搜索管理正文“Chrome 的某个部分” | 分别改为“侧边栏位置”“浏览器中的书签、历史记录或标签页”等准确称呼 |
| UI-12 | Cookie、安全、隐私指南和安全检查多处 Chromium 残留 | 产品身份统一；V8 引擎、Chromium 内核和上游版权等真实技术归属保留 |
| UI-13 | 关于页版权段落直接沿用 Chromium 的产品介绍 | 改为“开源与致谢”；保留上游版权与许可证，GCSA 自有部分署名依据项目声明填写 |
| UI-14 | 性能、搜索、安全检查等链接跳转 Google 帮助；安全检查“Chromium 中的工具”指向 Chrome 宣传页 | 保留有用的第三方帮助并标明来源；产品专属说明指向已存在的 GCSA 文档，移除不适用的宣传入口 |

起始页面、系统、书签主界面的核心操作文案，本轮未发现需要优先改写的问题。语言页“Google 翻译”和扩展页“Chrome 应用商店”不属于可以直接替换的品牌残留。

## 防护中心与下载

| 编号 | 已确认的问题 | 推荐改法 |
| --- | --- | --- |
| UI-15 | “检测两次，同一页的 Audio 读数应相同；WebGPU 的 maxBufferSize 会随开关变化”是测试步骤 | 主说明改成“减少网站通过设备特征跨站识别您的机会。”测试入口及参数放到诊断详情 |
| UI-16 | “JS 策略 worker（packages/core）”“在 chrome://aegis 运行 packages/core”暴露内部实现 | 改成用户可理解的“本地隐私处理”；核对是否需要作为独立开关，避免一个内部依赖被当作独立功能 |
| UI-17 | 活动说明包含 collect、Referer、bounce、CDP；Cookie 说明包含 `first-party / name-hit`、`c_user / datr` | 主页面用“已拦截跟踪请求、已清理跟踪参数和 Cookie”；规则命中与例外保留在可展开详情 |
| UI-18 | “钓鱼拦截页”“揭开 CNAME 伪装跟踪”“拦截跳转跟踪并立即清 Cookie”命名不一致 | 统一为“钓鱼网站防护”“伪装跟踪防护”“跳转跟踪防护”，一句话解释作用；技术名可在详情保留 |
| UI-19 | AI 设置直接使用“数值 loopback”、DevTools、`0.0.0.0`；自动控制说明过长 | 主说明明确“允许本机 AI 工具读取和操作网页”，保留网页内容不会自动脱敏的关键事实；连接协议和示例放到高级详情 |
| UI-20 | 下载设置使用 Range、“自动回落”“自动降级，不能关闭”“固定开启” | 改成“服务器支持时使用多个连接，否则使用单连接”“设备过热时自动降低下载并发”“下载完成后自动停止上传” |
| UI-21 | 下载中心“本地描述文件”“Magnet 链接”“检查内容”缺少用户语言 | 改成“种子或下载描述文件”“磁力链接”“预览下载内容”；使用“种子与磁力链接下载”作为分组名 |
| UI-22 | DHT、PEX、KiB/s、元数据上限、RFC 5854 等信息直接堆在主流程 | DHT / PEX 保留准确名称并补一句用途；单位不擅自换算。协议、限额和路径校验规则放到详情；BT 会公开 IP、完成后停止上传等使用影响继续清楚展示 |

“挖矿脚本检测（仅观察）”目前明确说明只记录提醒、不终止脚本或连接。这项边界应保留，不能为了缩短文字改成“挖矿拦截已开启”。保护概览“动作统计不代表网站可信”的说明也应保留。

## AI 助手与多语言

| 编号 | 已确认的问题 | 推荐改法 |
| --- | --- | --- |
| UI-23 | Aegis Agent、Aegis 浏览器智能体、Browser Agent、AEGIS 混用；“收藏夹”与浏览器“书签”混用 | 中文统一“AI 助手”，必要处完整称为“GCSA Aegis AI 助手”；“整理收藏夹”改成“整理书签”；“URL 有效性”改成“链接可用性” |
| UI-24 | 模型格式选项显示 `OpenAI compatible`；“本机 OpenAI 兼容服务不需要密钥”表述绝对 | 中文显示“OpenAI 兼容”；改为“是否需要 API 密钥取决于所选服务。本机服务通常可留空。” |
| UI-25 | 下载中心和工具栏用 `startsWith('zh')`，简繁体共用简体文字；更新提示直接硬编码中文 | 使用一致的英文、简体、繁体资源；按三语逐项检查状态文字、按钮、空状态、失败说明 |
| UI-26 | 读屏文本出现 `session protection totals`、`Common tasks`、`Aegis workspace`，设置返回按钮包含 `subpage`；下载开关只读出状态而缺少名称 | 同步翻译无障碍名称，绑定开关标签；朗读结果应包含功能名称和开关状态 |

自动化页已明确“浏览器关闭期间不会后台运行；重新打开后只补做一次检查”，这类影响使用预期的说明应保留。本轮没有执行任务，不能据此认定各自动化场景已完成端到端验收。

## 实施顺序与完成标准

1. 状态与数据说明：先处理 UI-01 至 UI-05，验证状态来源、发送条件和用户可见说明一致。
2. 全局词汇统一：统一产品名、AI 助手、书签、下载、保护/防护等称呼，覆盖页面标题、菜单、按钮、占位文字和读屏标签。
3. 自有页面精简：主页面采用“功能名称 + 一句作用说明”；诊断参数、协议和内部实现移到详情。保持重要数据去向和能力边界可见。
4. 三语与布局复验：简体、繁体、英文逐页检查；覆盖窄窗口、长模型名、下载进度、空列表和失败状态。
5. 本地构建验收：仍使用固定测试 App 路径。下一次仅文案及小范围修复构建递增为 `Ver 1.1 (004)`；若期间已有其他构建，继续递增，不能覆盖更高版本。用实际页面核对修改结果。

品牌修改应落在补丁序列和对应覆盖文件中。不能只改临时 Chromium 构建树，也不能批量改掉第三方署名、内部 URL、持久化键名或 GitHub 安装包匹配规则。

## 本轮验证

- `node apps/browser/scripts/agent-ui-status_test.mjs`：通过，8 组共 74 项断言，覆盖任务状态、部分完成、模型表单、自动化入口等。
- `node apps/browser/scripts/agent-model-selection_test.mjs`：通过，11 项模型选择回归，另含 HTML 结构检查。
- 已实际查看上述主页面、重点子页和展开状态；已核对下载设置、防护中心截图。
- 这些测试不覆盖所有文案准确性，本报告发现的问题没有被现有测试阻止。
- 未修改产品代码，未编译、打包、升级、发布；本轮新增的是检查报告。

## 关键代码位置

- [关于页模板](../apps/browser/overlay/chrome/browser/resources/settings/about_page/about_page.html.ts)
- [GitHub 更新状态文案](../apps/browser/overlay/chrome/browser/ui/webui/help/aegis_github_update.cc)
- 安全检查版本状态（当前构建树）：`/Users/lazy/Projects/GCSA-aegis-build/macos/src/chrome/browser/ui/safety_hub/safety_hub_util.cc`
- [模型状态显示](../apps/browser/overlay/chrome/browser/resources/aegis_agent/agent.ts)
- [模型配置判定](../apps/browser/overlay/chrome/browser/ui/webui/aegis_agent/aegis_agent_page_handler.cc)
- [AI 助手文案](../apps/browser/overlay/chrome/browser/ui/webui/aegis_agent/aegis_agent_ui.cc)
- [防护中心中文文案](../apps/browser/overlay/chrome/browser/ui/webui/aegis/aegis_ui.cc)
- 隐私设置入口说明（当前构建树）：`/Users/lazy/Projects/GCSA-aegis-build/macos/src/chrome/browser/ui/webui/settings/settings_localized_strings_provider.cc`
- [下载中心文案](../apps/browser/overlay/chrome/browser/resources/downloads/aegis_download_panel.html.ts)
- [下载中心语言分流](../apps/browser/overlay/chrome/browser/resources/downloads/aegis_download_panel.ts)
- [工具栏语言分流](../apps/browser/overlay/chrome/browser/ui/views/toolbar/aegis_toolbar_button.cc)
- 重置反馈条件（当前构建树）：`/Users/lazy/Projects/GCSA-aegis-build/macos/src/chrome/browser/ui/webui/settings/reset_settings_handler.cc`
- 重置报告目标地址（当前构建树）：`/Users/lazy/Projects/GCSA-aegis-build/macos/src/chrome/browser/profile_resetter/reset_report_uploader.cc`
- 设置品牌资源（当前构建树）：`/Users/lazy/Projects/GCSA-aegis-build/macos/src/chrome/app/settings_chromium_strings.grdp`
- 浏览器品牌资源（当前构建树）：`/Users/lazy/Projects/GCSA-aegis-build/macos/src/chrome/app/chromium_strings.grd`
