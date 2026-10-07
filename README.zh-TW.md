# Aegis browser

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/final/svg/gcsa-aegis-logo-reversed.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/brand/final/svg/gcsa-aegis-logo-color.svg">
    <img src="assets/brand/final/svg/gcsa-aegis-logo-color.svg" alt="Aegis 標誌" width="112">
  </picture>
</p>

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![C++ 單元測試](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/7b3008e649154ca0a7d5906c514488cc?branch=main)](https://app.codacy.com/gh/gcsagroup/aegis-browser/dashboard?branch=main) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![目前平台：macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**一個本機優先的隱私與安全瀏覽器，內建可控的 AI Agent。macOS 優先，接著推進 iPhone 與 iPad。**

[開始參與](#開始參與) · [平台進度](#平台進度) · [路線圖](docs/roadmap.zh-TW.md) · [文件](docs/README.zh-TW.md)

Aegis 正在開發中，尚無通過發布驗收的可散布版本。

> **2026-10-03 · iOS 2.2.0 原始碼預發布：** 網頁助手、過濾、下載、工作區、分頁分組及 iPad 獨立視窗已整合；驗證範圍及使用方式見[發布說明](docs/releases/ios-2.2.0-preview.1.zh-CN.md)。尚無可安裝的簽章 IPA。

## 核心能力

| 能力 | 用途 | 平台與目前階段 |
| --- | --- | --- |
| 隱私瀏覽 | 在 macOS 上透過連結、Cookie、網路釣魚及部分指紋保護減少追蹤與高風險導覽；原生 App 隔離一般與私密設定檔。 | macOS：原始碼已包含，執行驗收待完成。iOS/iPadOS：2.2 模擬器驗證及預發布說明見上方連結。 |
| 可控 Agent | 顯示計畫，由瀏覽器策略約束操作，並在敏感操作前請求確認。 | macOS：原始碼已包含，執行驗收待完成。iOS/iPadOS：支援確認後的網頁模型請求，操作工具尚未開放。 |
| 原生下載 | 使用 Chromium 瀏覽器下載介面及受限的下載路徑。 | macOS：原始碼已包含，執行驗收待完成。 |
| 存取策略 | 透過原生代理元件路由選定流量；必要路徑不可用時按 fail-closed 處理。 | macOS：原始碼已包含，整合與真實網路驗收待完成。 |

## 開始參與

### 準備開發環境

安裝 Git、[mise](https://mise.jdx.dev/)、ripgrep（`rg`）和 C++20 編譯器（預設 `clang++`）。macOS 可用 `xcode-select --install` 安裝 Command Line Tools，Homebrew 使用者可用 `brew install ripgrep`。信任工具鏈設定前，請先檢視 [`.mise.toml`](.mise.toml)。

```bash
git clone https://github.com/gcsagroup/aegis-browser.git
cd aegis-browser
mise trust .mise.toml
mise install
mise exec -- pnpm install --frozen-lockfile
mise exec -- pnpm run quality:fast
```

這組命令執行共用 workspace 檢查，不取得 Chromium，也不建置兩端原生 App。

### 從原始碼建置 macOS 瀏覽器

[Browser 指南](apps/browser/README.zh-TW.md)包含主機相依項目、`depot_tools`、獨立 Chromium 原始碼、補丁重放、建置與驗證步驟。

### 開啟 iOS 專案

開啟 `apps/ios/Aegis.xcodeproj`；Xcode 和 iPhone/iPad Simulator 設定見 [iOS 指南](apps/ios/README.zh-TW.md)。僅重新產生專案時需要 XcodeGen。

## 平台進度

| 平台 | 優先級 | 狀態 |
| --- | --- | --- |
| macOS | 目前 | Chromium 整合和 Access Service 持續推進；目前原始碼的執行與散布驗收仍待完成。 |
| iOS / iPadOS | 下一階段 | 原生 SwiftUI/WKWebView 2.2 提供原始碼預發布與模擬器驗證；真機及散布驗收仍待完成。 |
| Windows / Android / Linux | 後續 | 已有原始碼和評估入口；目前不承諾近期發布。 |

macOS 可獨立於 iOS 達到發布條件。完成標準見[路線圖](docs/roadmap.zh-TW.md)。

## 隱私與 AI

網頁摘要使用有界頁面快照，並由瀏覽器再次驗證和脫敏；敏感頁面會退回裝置端啟發式處理。遠端摘要請求可能將經過裁剪和脫敏的頁面內容傳送給使用者選擇的相容模型端點；使用非 loopback 目的地前，需要明確選擇並確認。Browser Agent 的操作受瀏覽器策略約束，敏感操作還需要單獨確認。iOS 網頁助手可在預覽脫敏內容並確認目的地後請求使用者設定的模型；合成模型驗收不代表外部服務品質，模型無法呼叫網頁操作工具。這些控制不構成通用的資料外洩防護邊界，詳見[架構與隱私邊界](docs/architecture.zh-TW.md)。

## 架構

| 目錄 | 職責 |
| --- | --- |
| [`packages/core`](packages/core) | 共用 TypeScript 策略、產生的資源和 Agent 契約。 |
| [`apps/browser`](apps/browser) | Chromium fork、原生服務、建置和桌面封裝。 |
| [`apps/ios`](apps/ios) | 原生 SwiftUI/WKWebView App 與內嵌擴充功能。 |

## 貢獻與文件

### 參與貢獻

Fork [`gcsagroup/aegis-browser`](https://github.com/gcsagroup/aegis-browser)，向上游 `main` 提交範圍聚焦的 PR，附上驗證結果和已知限制。

### 文件導覽

[文件索引](docs/README.zh-TW.md) · [架構](docs/architecture.zh-TW.md) · [研究](docs/research-map.zh-TW.md) · [歷史稽核](docs/audit/README.zh-TW.md) · [變更紀錄](CHANGELOG.zh-TW.md)

### 授權與致謝

GCSA 原創原始碼採用 [Apache-2.0](LICENSE)。第三方元件保留各自授權，見[第三方聲明](THIRD_PARTY_NOTICES.md)。

<details>
<summary>徽章說明</summary>

- **CI：**公開 `main` 分支的品質檢查。
- **C++ 單元測試：**standalone Access 測試、Chromium GoogleTest 接線與補丁檢查。
- **Codacy Grade：**上游 `main` 的靜態分析，不是測試覆蓋率。

這些徽章不代表瀏覽器執行或發布驗收通過。

</details>
