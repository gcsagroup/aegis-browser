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

## 核心能力

| 能力 | 範圍 |
| --- | --- |
| 隱私瀏覽 | macOS 上的連結、Cookie、網路釣魚及部分指紋保護；iOS 一般與私密設定檔隔離。 |
| 可控 Agent | 可見計畫、瀏覽器策略約束和敏感操作確認；iOS 提供四條離線工作流程。 |
| 原生下載 | macOS 上的 Chromium 下載介面與受限下載路徑。 |
| 存取策略 | macOS 上的選定流量代理路由；必要路徑不可用時按 fail-closed 處理。 |

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
| macOS | 目前 | Chromium 與 Access 整合推進中；目前原始碼的執行、真實網路和散布驗收待完成。 |
| iOS / iPadOS | 下一階段 | 已有記錄的 Simulator 基線；目前原始碼、實機和散布驗收待完成。 |
| Windows / Android / Linux | 後續 | 保留原始碼和評估工具，暫不承諾近期發布。 |

macOS 可獨立於 iOS 達到發布條件。完成標準見[路線圖](docs/roadmap.zh-TW.md)。

## 隱私與 AI

遠端摘要會將經過瀏覽器驗證、裁剪和脫敏的頁面內容傳送至所選模型端點；非 loopback 目的地需要明確選擇並確認。敏感頁面使用裝置端啟發式處理。Agent 操作受瀏覽器策略約束，敏感操作需單獨確認；iOS Agent 離線執行。這些控制不構成通用的資料外洩防護系統，詳見[隱私邊界](docs/architecture.zh-TW.md)。

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
