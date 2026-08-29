[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# GCSA-aegis 品牌資產

本目錄是 GCSA-aegis 目前正式品牌交付套件。Logo 的可編輯原始檔以 SVG 為準；PNG、ICNS、Asset Catalog 和 Icon Composer 檔案是平台交付物或衍生成品，不應反向作為 Logo 母版編輯。

所有色彩皆按 sRGB 使用。目前 PNG 未嵌入 ICC Profile，匯入設計或建置工具時不要轉換到 Display P3、CMYK 或其他色域。

## Logo 母版

三套 SVG 均為透明背景、真實向量路徑，沒有嵌入點陣圖。盾牌中包含清晰的字母 G，以及左、右、底恰好三個網路節點。

- `svg/gcsa-aegis-logo-color.svg`：預設彩色版，青綠到藍色漸層 `#12CDBF → #13B9D5 → #168FEF`。用於淺色或中性背景。
- `svg/gcsa-aegis-logo-mono.svg`：深海軍藍單色版 `#0B2538`。用於單色印刷、雕刻、模板和受限色彩環境。
- `svg/gcsa-aegis-logo-reversed.svg`：純白反白版 `#FFFFFF`。用於深色、藍色或照片背景。

需要新尺寸時，應從對應 SVG 重新匯出，不要放大低解析度 PNG。不要改變三個節點的數量、相對位置、G 的開口或盾牌比例，也不要加入 Google、Chrome 或 Chromium 圖形元素。

## PNG 資產

Logo PNG 分為 `png/logo-color/`、`png/logo-mono/` 和 `png/logo-reversed/` 三組，每組均提供以下正方形尺寸：

`16、22、24、32、48、64、128、256、512、1024 px`

這些 Logo PNG 均為 RGBA，透明區域應保留。小尺寸適用於選單、工具列和狀態介面；品牌展示、文件或二次匯出優先使用 SVG 或 1024px PNG。

macOS App 圖示位於 `app-icon/macos/png/`，提供：

`16、24、32、48、64、128、192、256、512、1024 px`

macOS 圖示為 RGBA，圖示主體已經做成圓角方形並保留透明外角。

iOS 與 iPadOS 共用的滿版母版位於：

`app-icon/ios/gcsa-aegis-app-icon-ios-1024.png`

該檔案為 `1024 × 1024`、8-bit RGB、無 Alpha、四角完全不透明的正方形母版。

## macOS 使用方式

### Xcode Asset Catalog

優先使用 `macos/Assets.xcassets/`：

1. 將該 Asset Catalog 合併到 macOS Target，或僅合併其中的 `AppIcon.appiconset`。
2. 在 Target 的 General 或 Build Settings 中將 App Icon Set 指向 `AppIcon`。
3. 由目前專案使用的 Xcode/SDK 重新編譯 Asset Catalog；不要手動編輯產生後的 `Assets.car`。
4. 封裝後檢查 `.app/Contents/Resources/Assets.car`，並在 Finder、Dock、App 切換器和「關於」頁面實際查看。

`macos/AppIcon.icon/` 是 Icon Composer 風格的可編輯套件，包含 `icon.json` 和 1024px 圖層資源。僅在目標 Xcode/建置鏈明確支援 `.icon` 時使用。

`macos/Assets.car` 是目前建置鏈產生的已編譯驗證成品，不是跨 Xcode 版本的原始檔。正式建置應優先從 `Assets.xcassets` 或 `.icon` 來源重新產生。

### ICNS 或非 Xcode 封裝

`macos/GCSA-aegis.icns` 可用於 Chromium、指令碼封裝或仍讀取 `CFBundleIconFile` 的 macOS Bundle：

1. 將 ICNS 納入建置資源，而不是直接修改已簽署 App。
2. 確保 `Info.plist` 的 `CFBundleIconFile` 指向對應檔名。
3. 重新建置、簽署並檢查最終 Bundle 中的實際資源。

目前 ICNS 可以正常解開，包含 `16、32、128、256、512 px` 五個基礎層及各自的 Retina `@2x` 層，共 10 個標準表示。現代 macOS 發布仍應優先從完整的 `Assets.xcassets` 重新編譯 `Assets.car`。

## iOS 與 iPadOS 使用方式

1. 將 `app-icon/ios/gcsa-aegis-app-icon-ios-1024.png` 匯入 iOS Target 的 `Assets.xcassets/AppIcon.appiconset`。
2. 保持原圖滿版、無透明像素，不要手動裁圓角、加入透明角或再套一層圓角邊框。
3. 由 Xcode 和 iOS/iPadOS 在主畫面、Spotlight、設定等位置套用各自的系統遮罩。
4. 在 iPhone 與 iPad 的實際 AppIcon 尺寸下檢查盾牌、G 和三個節點，不能僅依據 1024px 預覽判斷清晰度。

### 為什麼 iOS 和 macOS 圖示不同

- iOS/iPadOS 輸入必須是四角完整、滿版、完全不透明的正方形。系統隨後套用平台遮罩；預先裁圓角會造成雙重縮小、透明角或邊緣露底。
- macOS 目前設計本身包含預先完成的圓角方形、外框和透明外角，系統不會按 iOS 的方式替開發者修正同一張滿版圖。
- 因此不要把 macOS RGBA 圖示直接提交為 iOS AppIcon，也不要把 iOS 滿版母版直接當作現成 ICNS 使用。

## iOS 適配產生記錄

iOS 滿版母版使用 Codex 內建 `imagegen`，以入選 V4 macOS App 圖示為編輯目標進行平台適配。它不是重新設計 Logo；編輯範圍僅限外層圖示邊界與背景延展。

<details>
<summary>展開查看最終 imagegen Prompt</summary>

```text
Use case: precise-object-edit.
Asset type: iOS and iPadOS AppIcon 1024×1024 master.
Input image: Image 1 is the approved GCSA-aegis V4 macOS app icon and is the exact visual reference and edit target.

Primary request: create the platform-adapted iOS master by changing only the outer app-tile treatment. Remove the pre-cut rounded-square boundary, transparent corners, outer rounded rim, and any checkerboard. Seamlessly extend the existing deep navy, royal blue, and cyan flowing background all the way to every edge and every square corner so the complete 1024×1024 canvas is fully opaque and full-bleed. iOS will apply its own mask later.

Invariants: preserve the central shield, the capital G, the left/right/bottom exactly three circular nodes, their positions, proportions, luminous white-cyan treatment, shadows, and overall composition as faithfully as possible. Keep exactly three nodes and no extra dots. Keep the same approved blue/cyan palette and flowing background language. The central mark must stay within the same safe area and remain readable at 29–60 px.

Output constraints: one front-facing square icon only; fully opaque RGB image with no alpha; no pre-rounded corners; no inner rounded tile outline; no transparent pixels; no checkerboard; no text; no watermark; no Google or Chrome elements; no extra nodes; no device mockup; no presentation background.
```

</details>

## 已完成驗證

驗證日期：2026-08-29。

- 三套 SVG 均通過 XML 解析和 `rsvg-convert` 實際渲染；每套恰好包含三個節點，且沒有 `<image>` 或 `data:image` 嵌入。
- 共檢查 61 個 PNG，檔名標示尺寸與實際像素尺寸全部一致，尺寸錯誤為 0。
- 其中 60 個 PNG 為 8-bit RGBA；唯一的 RGB 檔案是 iOS/iPadOS 1024px 滿版母版，符合預期。
- Logo 和 macOS 圖示母版的 Alpha 範圍均為 `0–255`；iOS 母版沒有 Alpha，四角均有有效色彩像素。
- `Contents.json` 與 `icon.json` 均通過 JSON 解析。
- `GCSA-aegis.icns` 可被 macOS `iconutil` 正常解開，得到 16、32、128、256、512px 的基礎層與 Retina `@2x` 層，共 10 個表示。
- `Assets.car` 可被 `assetutil` 正常解析；記錄的建置鏈為 Xcode 26.6（17F113）、平台為 macOS，共包含 9 個 AppIcon/Icon Rendition。它的檔案結構基本有效，但不取代目標 Xcode 重新編譯、最終 App Bundle 執行與簽署檢查。

這些檢查證明目前品牌套件的檔案結構、尺寸和基本格式可用，但不等同於完成 Chromium 整合、iOS 真機驗證、macOS 簽署、公證或正式發布。
