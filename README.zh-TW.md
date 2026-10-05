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

[開始參與](#開始參與) · [平台進度](#平台進度) · [路線圖](docs/roadmap.zh-TW.md) · [Browser 指南](apps/browser/README.zh-TW.md) · [iOS 指南](apps/ios/README.zh-TW.md) · [文件](docs/README.zh-TW.md)

---

Aegis 正在持續開發。**發布 No-Go：**macOS 瀏覽器和原生 iOS/iPadOS App 均尚無完成發布驗收的可散布版本。

> **2026-10-05 · iOS Ver 3.2 (63) 開發候選：** iPhone/iPad 精簡工具列與私密模式功能已完成模擬器驗證。私密瀏覽不自動記錄歷史、工作階段或 AI 任務；主動儲存、下載和模型傳送需確認。見[工程指南](apps/ios/README.zh-TW.md)與[驗證記錄](docs/audit/ios-private-mode-2026-10-05.zh-CN.md)。已發布原始碼預覽仍為 2.2。

> **2026-10-03 · iOS 2.2.0 原始碼預發布：** 網頁助手、過濾、下載、工作區、分頁分組及 iPad 獨立視窗已整合；驗證範圍及使用方式見[發布說明](docs/releases/ios-2.2.0-preview.1.zh-CN.md)。尚無可安裝的簽章 IPA。

## 核心能力

| 能力 | 用途 | 平台與目前階段 |
| --- | --- | --- |
| 隱私瀏覽 | 在 macOS 上透過連結、Cookie、網路釣魚及部分指紋保護減少追蹤與高風險導覽；原生 App 隔離一般與私密設定檔。 | macOS：原始碼已包含，執行驗收待完成。iOS/iPadOS：3.2 私密模式驗證及 2.2 原始碼預發布說明見上方連結。 |
| 可控 Agent | 顯示計畫，由瀏覽器策略約束操作，並在敏感操作前請求確認。 | macOS：原始碼已包含，執行驗收待完成。iOS/iPadOS：支援確認後的網頁模型請求，操作工具尚未開放。 |
| 原生下載 | 使用 Chromium 瀏覽器下載介面及受限的下載路徑。 | macOS：原始碼已包含，執行驗收待完成。 |
| 存取策略 | 透過原生代理元件路由選定流量；必要路徑不可用時按 fail-closed 處理。 | macOS：原始碼已包含，整合與真實網路驗收待完成。 |

## 開始參與

### 準備開發環境

儲存庫透過 [`.mise.toml`](.mise.toml) 固定 Node.js `22.23.1`、pnpm `9.15.0` 和 Python `3.11.9`。請安裝 Git、[mise](https://mise.jdx.dev/)、ripgrep（`rg`）和支援 C++20 的編譯器（預設使用 `clang++`）。在 macOS 上，可執行 `xcode-select --install` 安裝 Xcode Command Line Tools；使用 Homebrew 時可執行 `brew install ripgrep`。

```bash
git clone https://github.com/gcsagroup/aegis-browser.git
cd aegis-browser
mise install
mise exec -- pnpm install --frozen-lockfile
mise exec -- pnpm run quality:fast
```

這組命令執行共用 workspace 檢查；不會取得或建置 Chromium，也不驗證原生 iOS App。

### 從原始碼建置 macOS 瀏覽器

按照 [Browser 工程指南](apps/browser/README.zh-TW.md)準備 `depot_tools`、取得獨立的大型 Chromium 固定版本原始碼、重播修補序列，以及建置並執行瀏覽器。Chromium 還需要額外的主機相依項目；該指南提供建置和驗證命令。

### 開啟 iOS 專案

[iOS 工程指南](apps/ios/README.zh-TW.md)說明 Xcode 與 Simulator 前提、儲存庫中的 `apps/ios/Aegis.xcodeproj`，以及 iPhone/iPad Simulator 流程。僅在需要重新產生專案時才使用 XcodeGen。

## 平台進度

| 平台 | 優先級 | 目前狀態 |
| --- | --- | --- |
| macOS | 目前 | Chromium 整合和 Access Service 持續推進；目前原始碼的執行與散布驗收仍待完成。 |
| iOS / iPadOS | 下一階段 | 原生 SwiftUI/WKWebView 3.2 完成模擬器功能檢查；原始碼預發布仍為 2.2，真機及散布驗收待完成。 |
| Windows / Android / Linux | 後續 | 已有原始碼和評估入口；目前不承諾近期發布。 |

macOS 可以獨立達到發布條件，不需要等待 iOS。各里程碑的完成標準見[路線圖](docs/roadmap.zh-TW.md)。完整瀏覽器建置、真實網路場景、真機驗收、簽署、公證、安裝與升級分別屬於發布門檻。

## 隱私與 AI

網頁摘要使用有界頁面快照，並由瀏覽器再次驗證和脫敏；敏感頁面會退回裝置端啟發式處理。遠端摘要請求可能將經過裁剪和脫敏的頁面內容傳送給使用者選擇的相容模型端點；使用非 loopback 目的地前，需要明確選擇並確認。Browser Agent 的操作受瀏覽器策略約束，敏感操作還需要單獨確認。iOS 網頁助手可在預覽脫敏內容並確認目的地後請求使用者設定的模型；合成模型驗收不代表外部服務品質，模型無法呼叫網頁操作工具。這些控制不構成通用的資料外洩防護邊界，詳見[架構與隱私邊界](docs/architecture.zh-TW.md)。

## 架構

| 目錄 | 職責 |
| --- | --- |
| [`packages/core`](packages/core) | 共用 TypeScript 策略邏輯、產生的資源和 Agent 契約。 |
| [`apps/browser`](apps/browser) | Chromium 整合、原生瀏覽器服務、建置指令碼和桌面封裝。 |
| [`apps/ios`](apps/ios) | 原生 SwiftUI/WKWebView App、策略與 Agent 模組、內嵌擴充功能。 |

桌面瀏覽器基於 Chromium fork；iOS 是獨立的原生實作。具體實作見[架構文件](docs/architecture.zh-TW.md)和各平台工程指南。

## 貢獻與文件

### 參與貢獻

公開貢獻請 Fork [`gcsagroup/aegis-browser`](https://github.com/gcsagroup/aegis-browser)，提交範圍聚焦的改動，執行相關檢查，並向上游 `main` 分支提交 Pull Request。請說明改動範圍、驗證證據和已知限制。

### 文件導覽

- **專案：** [文件索引](docs/README.zh-TW.md) · [路線圖](docs/roadmap.zh-TW.md) · [架構](docs/architecture.zh-TW.md)
- **工程：** [Browser 工程指南](apps/browser/README.zh-TW.md) · [iOS 工程指南](apps/ios/README.zh-TW.md)
- **參考：** [研究與限制](docs/research-map.zh-TW.md) · [歷史稽核紀錄](docs/audit/README.zh-TW.md) · [變更紀錄](CHANGELOG.md)

### 授權與致謝

GCSA 原創原始碼採用 [Apache-2.0](LICENSE)。Chromium、libtorrent 與其他第三方元件保留各自授權。

另見[第三方開源致謝](THIRD_PARTY_NOTICES.md)。

<details>
<summary>徽章說明</summary>

- **CI**：顯示公開 `main` 分支的品質工作流程結果，不代表 Chromium 執行或散布驗收。
- **C++ 單元測試**：涵蓋 standalone C++20 Access 測試，以及 Chromium GoogleTest wiring 和修補檢查，不代表完整 Chromium GoogleTest 或瀏覽器執行覆蓋。
- **Codacy Grade**：顯示上游 `gcsagroup/aegis-browser` 的 `main` 分支靜態分析結果，不代表測試覆蓋率或執行階段驗收。
- **License**：標示儲存庫授權。平台徽章表示產品優先級，不代表發布狀態。

</details>
