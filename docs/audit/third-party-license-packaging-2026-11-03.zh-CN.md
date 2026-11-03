# 第三方许可补齐与发行包核验（2026-11-03）

保留 Apache-2.0 作为 Aegis 原创代码许可。第三方组件和数据保留各自条款。
本次从 develop `c7f45b21972bfc33c53c0c90bc0a48e9e517103e` 准备修补，
不把源码、离线打包测试、编译、实际安装包和商店状态互相替代。

## 已核实的实物与来源

| 对象 | 身份和证据 | 范围 |
| --- | --- | --- |
| 历史 macOS 测试 ZIP | SHA-256 `df679ccffe50f47f7626fde5c7c9ff8ac59cc159f7141678c24e04aa5249df45`；168,458,973 bytes；Chromium 151.0.7922.77 | 包内 Credits 有 761 项。主 Framework 含 `Aegis/0.1 libtorrent/2.1.1`、`libtorrent/2.1.1.0`、`-LT2110-` 与对应 C++ 类型。已扫描包内 334 个文件和 223 个 PAK 的资源，未检出 libtorrent 具名条目或 Arvid Norberg 署名；未核对当时包外交付材料，未绑定到确切 Aegis 产品提交。 |
| iOS 1.0.0 (38) 原始导出 IPA | SHA-256 `eb2a487d1a567220473c484310edba5554a82861687337437154b140a2bb1ec3`；11,417,185 bytes；source `c7e9a5dded0254ccc8185fa9c8bd445763a65903`；[run 41484271795](https://github.com/gcsagroup/aegis-browser/actions/runs/41484271795) | GitHub 外层归档 SHA-256 `cf8a682c654fbfdbe282d173ce5c73c471929464fa75cc9bc9c2c21e4ddca52c`。五个 JS 库及其五份许可的哈希与包内 manifest 全部一致；包内有规则许可和 PSL 头部。旧钓鱼声明只有 Unlicense，缺少文件头 MIT 声明及其条款。 |
| App Store | 用户确认 iOS 已上架；[公开商店](https://apps.apple.com/cn/app/gcsa-aegis/id6827988433) 为 1.0.0 | 公开商店页面不提供内部 build 号；以上原始 IPA 证据不自动证明商店重签后的实际安装字节。补齐通过后续更新交付，不改写旧包。 |
| Windows / Android | 有历史文档回执，未取得当前正式安装包 | 不能根据源码或历史回执判定包内鸣谢完整。 |

## 修补

- macOS 打包在复制 App 后、签名前写入 `Contents/Resources/AegisThirdPartyNotices.txt`。
  因声明位于 App 内，仅含 App 的 ZIP、DMG 及单独拷贝 App 均保留它；不修改原始构建 App。
  声明包含 libtorrent 原始版权、BSD 三项条款和免责声明，并补入 Boost、
  同一固定归档内实际编译的 try_signal 和 ed25519 许可。
  同时保留上游完整 LICENSE 中的 Apple/APSL 与 UC Berkeley 路由头声明，
  附 APSL 全文，并把原始 `route.h` 作为 `AegisLibtorrentRouteSource.txt` 随 App 提供。
- Chromium 的 libtorrent 目录增加 `README.chromium`；通过 GN 可达的资源许可 group
  登记九个 Aegis WebUI/本地推理组件，保留 `chrome://credits` 原机制。
  新补丁与 overlay 一起交付；实际 Chromium credits 仍需在新的确切构建中验证。
- iOS 钓鱼来源固定到 `dbf845d69d21765c2cffc1d190ed62660f08a070`。
  取回的原始 `phishing.txt` SHA-256 与已有记录一致，原数据与签名不变。
  同一提交的文件头写 MIT，仓库 LICENSE 为 Unlicense（SHA-256
  `6b0382b16279f26ff69014300541967a356a666eb0b91b422f6862f6b7dad17e`）。
  补齐作者、原文件头、MIT 条款、转换说明并保留 Unlicense，不推断上游明确双许可。
- iOS 设置的「关于」提供离线鸣谢，包含规则、JS 库、PSL 及当前 SwiftPM 解析图的仓库许可。
  SDK 的解析图与实际链接不同；Google Analytics 预编译部分不因仓库 LICENSE 而被视为开源。
  FirebaseCrashlytics 另附组件级 LICENSE，保留其 libunwind 的 Hewlett-Packard 版权和 MIT 条款。
  桌面 ONNX Runtime 1.20.1 另附上游 ThirdPartyNotices，补齐根 MIT 许可证以外的声明；
  上游汇总也涵盖可选后端，不表示所有条目都进入每个平台。
- 离线生成器绑定源文件和 SwiftPM pins。IPA 导出校验检查声明及原始许可资源，缺失、变动或重复成员时拒绝。

## 验证方法与尚待完成的门

```sh
python3 -B scripts/licenses/third_party_notices.py check
python3 -B -m unittest discover -s scripts/licenses -p 'test_*.py' -v
python3 -B -m unittest discover -s scripts/release -p 'test_verify_ipa.py' -v
python3 -B scripts/licenses/third_party_notices.py verify-ipa /absolute/path/to/new.ipa
```

SDK 许可文本的来源 URL、revision 和 SHA-256 记录在
`scripts/licenses/sdk-licenses/manifest.json`。该清单保留解析图中可能依赖的仓库许可，
不是完整二进制 SBOM；Apple 平台 SDK、编译工具链和下载模型按各自条款另行核验。

真实 macOS/Windows/Android Chromium 构建、生成后的 Credits、安装运行、签名、商店更新仍是独立证据。
libtorrent 的镜像来源、HTTPS tracker 和宿主 Boost 版本固定问题保持原状态；补充声明不解除这些发行门禁。
当前变更不对已发布 iOS 版本或历史测试包作出已修复的声明。
