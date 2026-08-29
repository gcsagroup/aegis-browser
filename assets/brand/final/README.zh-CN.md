[English](./README.md) | [**简体中文**](./README.zh-CN.md) | [繁體中文](./README.zh-TW.md)

# GCSA-aegis 品牌资产

本目录是 GCSA-aegis 当前正式品牌交付包。Logo 的可编辑源文件以 SVG 为准；PNG、ICNS、Asset Catalog 和 Icon Composer 文件是平台交付物或派生物，不应反向作为 Logo 母版编辑。

所有颜色按 sRGB 使用。当前 PNG 未嵌入 ICC Profile，导入设计或构建工具时不要转换到 Display P3、CMYK 或其他色域。

## Logo 母版

三套 SVG 均为透明背景、真实矢量路径，没有嵌入位图。盾牌中包含清晰的字母 G，以及左、右、底恰好三个网络节点。

- `svg/gcsa-aegis-logo-color.svg`：默认彩色版，青绿到蓝色渐变 `#12CDBF → #13B9D5 → #168FEF`。用于浅色或中性背景。
- `svg/gcsa-aegis-logo-mono.svg`：深海军蓝单色版 `#0B2538`。用于单色印刷、雕刻、模板和受限色彩环境。
- `svg/gcsa-aegis-logo-reversed.svg`：纯白反白版 `#FFFFFF`。用于深色、蓝色或照片背景。

需要新尺寸时，应从对应 SVG 重新导出，不要放大低分辨率 PNG。不要改变三个节点的数量、相对位置、G 的开口或盾牌比例，也不要添加 Google、Chrome 或 Chromium 图形元素。

## PNG 资产

Logo PNG 分为 `png/logo-color/`、`png/logo-mono/` 和 `png/logo-reversed/` 三组，每组均提供以下正方形尺寸：

`16、22、24、32、48、64、128、256、512、1024 px`

这些 Logo PNG 均为 RGBA，透明区域应保留。小尺寸适用于菜单、工具栏和状态界面；品牌展示、文档或二次导出优先使用 SVG 或 1024px PNG。

macOS App 图标位于 `app-icon/macos/png/`，提供：

`16、24、32、48、64、128、192、256、512、1024 px`

macOS 图标为 RGBA，图标主体已经做成圆角方形并保留透明外角。

iOS 与 iPadOS 共用的全出血母版位于：

`app-icon/ios/gcsa-aegis-app-icon-ios-1024.png`

该文件为 `1024 × 1024`、8-bit RGB、无 Alpha、四角完全不透明的正方形母版。

## macOS 使用方式

### Xcode Asset Catalog

优先使用 `macos/Assets.xcassets/`：

1. 将该 Asset Catalog 合并到 macOS Target，或仅合并其中的 `AppIcon.appiconset`。
2. 在 Target 的 General 或 Build Settings 中将 App Icon Set 指向 `AppIcon`。
3. 由当前项目使用的 Xcode/SDK 重新编译 Asset Catalog；不要手工编辑生成后的 `Assets.car`。
4. 打包后检查 `.app/Contents/Resources/Assets.car`，并在 Finder、Dock、应用切换器和“关于”页面实际查看。

`macos/AppIcon.icon/` 是 Icon Composer 风格的可编辑包，包含 `icon.json` 和 1024px 图层资源。仅在目标 Xcode/构建链明确支持 `.icon` 时使用。

`macos/Assets.car` 是当前构建链生成的已编译验证产物，不是跨 Xcode 版本的源文件。正式构建应优先从 `Assets.xcassets` 或 `.icon` 源重新生成。

### ICNS 或非 Xcode 打包

`macos/GCSA-aegis.icns` 可用于 Chromium、脚本化打包或仍读取 `CFBundleIconFile` 的 macOS Bundle：

1. 将 ICNS 纳入构建资源，而不是直接修改已签名 App。
2. 确保 `Info.plist` 的 `CFBundleIconFile` 指向对应文件名。
3. 重新构建、签名并检查最终 Bundle 中的实际资源。

当前 ICNS 可以正常解包，包含 `16、32、128、256、512 px` 五个基础层及各自的 Retina `@2x` 层，共 10 个标准表示。现代 macOS 发布仍应优先从完整的 `Assets.xcassets` 重新编译 `Assets.car`。

## iOS 与 iPadOS 使用方式

1. 将 `app-icon/ios/gcsa-aegis-app-icon-ios-1024.png` 导入 iOS Target 的 `Assets.xcassets/AppIcon.appiconset`。
2. 保持原图全出血、无透明像素，不要手工裁圆角、加透明角或再套一层圆角边框。
3. 由 Xcode 和 iOS/iPadOS 在主屏幕、Spotlight、设置等位置应用各自的系统遮罩。
4. 在 iPhone 与 iPad 的实际 AppIcon 尺寸下检查盾牌、G 和三个节点，不能仅依据 1024px 预览判断清晰度。

### 为什么 iOS 和 macOS 图标不同

- iOS/iPadOS 输入必须是四角完整、全出血、完全不透明的正方形。系统随后应用平台遮罩；预先裁圆角会造成双重缩小、透明角或边缘露底。
- macOS 当前设计本身包含预先完成的圆角方形、外沿和透明外角，系统不会按 iOS 的方式替开发者修正同一张全出血图。
- 因此不要把 macOS RGBA 图标直接提交为 iOS AppIcon，也不要把 iOS 全出血母版直接当作现成 ICNS 使用。

## iOS 适配生成记录

iOS 全出血母版使用 Codex 内置 `imagegen`，以入选 V4 macOS App 图标为编辑目标进行平台适配。它不是重新设计 Logo；编辑范围仅限外层图标边界与背景延展。

<details>
<summary>展开查看最终 imagegen Prompt</summary>

```text
Use case: precise-object-edit.
Asset type: iOS and iPadOS AppIcon 1024×1024 master.
Input image: Image 1 is the approved GCSA-aegis V4 macOS app icon and is the exact visual reference and edit target.

Primary request: create the platform-adapted iOS master by changing only the outer app-tile treatment. Remove the pre-cut rounded-square boundary, transparent corners, outer rounded rim, and any checkerboard. Seamlessly extend the existing deep navy, royal blue, and cyan flowing background all the way to every edge and every square corner so the complete 1024×1024 canvas is fully opaque and full-bleed. iOS will apply its own mask later.

Invariants: preserve the central shield, the capital G, the left/right/bottom exactly three circular nodes, their positions, proportions, luminous white-cyan treatment, shadows, and overall composition as faithfully as possible. Keep exactly three nodes and no extra dots. Keep the same approved blue/cyan palette and flowing background language. The central mark must stay within the same safe area and remain readable at 29–60 px.

Output constraints: one front-facing square icon only; fully opaque RGB image with no alpha; no pre-rounded corners; no inner rounded tile outline; no transparent pixels; no checkerboard; no text; no watermark; no Google or Chrome elements; no extra nodes; no device mockup; no presentation background.
```

</details>

## 已完成验证

验证日期：2026-08-29。

- 三套 SVG 均通过 XML 解析和 `rsvg-convert` 实际渲染；每套恰好包含三个节点，且没有 `<image>` 或 `data:image` 嵌入。
- 共检查 61 个 PNG，文件名标注尺寸与实际像素尺寸全部一致，尺寸错误为 0。
- 其中 60 个 PNG 为 8-bit RGBA；唯一的 RGB 文件是 iOS/iPadOS 1024px 全出血母版，符合预期。
- Logo 和 macOS 图标母版的 Alpha 范围均为 `0–255`；iOS 母版没有 Alpha，四角均有有效颜色像素。
- `Contents.json` 与 `icon.json` 均通过 JSON 解析。
- `GCSA-aegis.icns` 可被 macOS `iconutil` 正常解包，得到 16、32、128、256、512px 的基础层与 Retina `@2x` 层，共 10 个表示。
- `Assets.car` 可被 `assetutil` 正常解析；记录的构建链为 Xcode 26.6（17F113）、平台为 macOS，共包含 9 个 AppIcon/Icon Rendition。它的文件结构基本有效，但不替代目标 Xcode 重编译、最终 App Bundle 运行与签名检查。

这些检查证明当前品牌包的文件结构、尺寸和基本格式可用，但不等同于完成 Chromium 集成、iOS 真机验证、macOS 签名、公证或正式发布。
