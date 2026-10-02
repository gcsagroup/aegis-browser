[English](./README.md) | [**简体中文**](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA Aegis · iPhone 与 iPad

SwiftUI + 系统 WebKit 的原生浏览器，最低系统版本 iOS 18.4。开发目标是符合全球 App Store（含中国大陆）的上架技术要求。当前先完成功能和测试，提审材料由用户后续提供；模拟器通过不等于已具备正式发布资格。

## 当前能力

- 标签与窗口：普通和私密标签分组、重命名、移动标签、取消分组保留页面；普通分组跨重启恢复，私密分组仅在内存。iPad 支持独立窗口、新建、重命名、关闭与恢复；窗口分别保存标签和分组，共享收藏、下载和设置。
- 浏览与资料：搜索、标签、普通会话恢复、私密浏览、收藏和历史、页内查找、系统分享与打印、工作区保存、追加恢复、重命名、删除、JSON 导入预览和导出。
- 网页助手：明确选择最多 5 个页面，读取可见正文，预览脱敏内容，再确认模型目的地。支持摘要、翻译、问答、来源比较与商品比较；结果可回到原文并导出文本。任务目标与来源加密持久化，重启后主动恢复并重新确认；研究结果仅在用户选择保存后加密保留。
- 模型服务：OpenAI 兼容接口、Anthropic、Gemini；模型列表检测和手动输入。密钥按服务与接口类型隔离存入 Keychain，不跟随模型请求重定向。
- 浏览器管理：收藏去重预览、独立确认、撤销和跨重启恢复；手动检查收藏链接，保留“访问受限”和“无法判断”，不自动删除。
- 下载：HTTP(S) 文件、进度、暂停、可用时续传、取消、重试、系统后台传输、最多 16 个镜像顺序重试、Metalink 导入确认、SHA-256／SHA-512 与文件大小校验，以及分享至“文件”。单文件上限 1 GB。支持 HTTPS 与本机 HTTP；远端明文 HTTP 仍受系统传输策略限制。
- 保护：内置 EasyList／EasyPrivacy、手动更新、网络广告与元素隐藏规则、总开关、站点例外、链接参数清理、高风险网址检查、历史和网站数据清除。私密浏览禁用助手、资料管理和持久下载。
- 界面：简体中文、繁体中文、英文；iPhone 与 iPad 均使用整窗网页和工具栏，无常驻侧栏，浅深色、大字体、横屏。
- 系统入口：分享扩展只交接短期有效的 HTTP(S) 链接；Safari 扩展使用原有短期授权读取页面身份，之后交接网址，由主 App 再确认打开。

## 在固定路径构建与验收

依赖 Xcode、可用 iOS Simulator runtime、XcodeGen、Node.js、Python 3。本轮环境为 Xcode 27.0 / iOS Simulator 26.5。保留模拟器默认临时签名，**不要设置 `CODE_SIGNING_ALLOWED=NO`**，否则 Keychain 测试可能失败。

```bash
# 只读预检；包含隔离的本机 HTTP 服务自测，不运行模拟器。
bash apps/ios/scripts/run-simulator-tests.sh --dry-run

# 构建一次，使用同一产物依次运行 iPhone 和 iPad 的全部原生/UI 测试。
bash apps/ios/scripts/run-simulator-tests.sh \
  --execute --output-dir /tmp/aegis-ios-YOUR-UNIQUE-RUN
```

执行时自动递增 `project.yml` 中的构建号并重新生成工程。版本展示采用 `Ver 2.2 (构建号)`。构建目录固定为仓库同级的 `GCSA-aegis-build/ios/DerivedData`，App 固定为该目录下 `Build/Products/Debug-iphonesimulator/Aegis.app`。每次日志与 `.xcresult` 使用新的证据目录；不覆盖旧证据，不擦除或删除模拟设备。

脚本复用 `Aegis QA iPhone 17` 和 `Aegis QA iPad Air 11-inch (M4)`。本机验收服务仅监听 `127.0.0.1:8768`，网页、文件和模型回答都是明确的合成资料。真实 HTTP、WebKit 和文件操作用于验证链路；合成模型通过不代表远端模型质量通过。脚本自动启动并关闭自己创建的服务，已有的同类服务会复用。

手动体验合成网页与模型链路：

```bash
python3 apps/ios/scripts/simulator-fixture-server.py --port 8768
```

在 App 打开 `http://127.0.0.1:8768/article`；模型接口选择兼容接口，地址填 `http://127.0.0.1:8768/v1`，检测后选择 `aegis-simulator-fixture` 并保存。不要把此设置用作日常模型服务。

## 实现与边界

- `BrowserKit`：WebKit、会话与工作区、页面快照、跟踪规则、下载和链接检查。
- `AgentKit`：原有收藏授权/撤销机制，以及新的只读模型客户端。旧研究、购物和下载的确定性样例留给回归测试，正常助手入口使用真实页面与网络。
- `AegisApp/Localizable.xcstrings`：三语界面资源真源。
- `Shared`、`ShareExtension`、`SafariWebExtension`：网址交接和只读扩展授权。
- `Tests`、`scripts`：安全回归、真实本机网络测试、模拟器 UI 测试和规则生成。

页面最多读取 24,000 个字符，超出会提示；不读取跨域框架、输入值、密码或 Cookie。检测到登录/支付表单或秘密时拒绝发送。模型只产生文字，不能付款、登录、修改页面或调用操作工具。引用编号会核对范围，结论仍需阅读原文确认。

助手离开前台或关闭后停止，重新运行需要重新读取与确认。下载后台调度由 iOS 决定；强制退出、系统终止、断网和服务器不支持续传时不能保证继续。下载不复用网页登录 Cookie；后台传输的中间重定向由系统处理，应用检查起始和最终地址，不承诺后台逐跳拦截。

BT/磁力、多连接加速、跨设备同步、自动全网检索、Chromium 内核防护和任意网站自动操作尚未实现。Safari 宿主交接、外部模型联网质量、长时间后台/重启、VoiceOver 全流程应分别验收，不能以单元测试替代。

上一轮（2026-09-30）记录见 [模拟器实施与验收](../../docs/audit/ios-simulator-implementation-2026-09-30.zh-CN.md)。历史 2026-08-28 的模拟器硬化结论只对应当时版本，不作为本版通过依据。

## 本轮功能对齐

广告订阅只转换能够准确表达的语法，界面显示网络、元素隐藏和跳过的规则数量；不宣称完整支持所有 EasyList 高级语法。规则文本保留上游许可与来源，更新成功后才替换当前规则。详细验证见[本轮记录](../../docs/audit/ios-feature-parity-2026-10-01.zh-CN.md)。

本轮标签分组、多窗口和 iPad 界面调整见[验收记录](../../docs/audit/ios-windows-and-tab-groups-2026-10-01.zh-CN.md)。

## 版本发布

[iOS 2.2.0 预发布版](https://github.com/gcsagroup/aegis-browser/releases/tag/ios-v2.2.0-preview.1) 提供源码及验证摘要；尚无签名 IPA，不能直接安装或提交 App Store。版本记录见[变更日志](../../CHANGELOG.zh-CN.md)。独立工作树运行测试时，可用 `AEGIS_IOS_DERIVED_DATA` 指向已有固定构建目录；测试同时输出 Swift 覆盖率和输入稳定性记录。
