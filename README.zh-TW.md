# Aegis

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

[![CI](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=develop&event=push)](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml?query=branch%3Adevelop) [![C++ 單元測試](https://github.com/quinn521/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=develop&event=push)](https://github.com/quinn521/aegis-browser/actions/workflows/cpp-unit-tests.yml?query=branch%3Adevelop) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=develop)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![目前平台：macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**一個本機優先的隱私與安全瀏覽器，內建可控的 AI Agent。先做好 macOS，再推進 iPhone 與 iPad。**

Aegis 把隱私控制、安全檢查、原生瀏覽器能力和 AI Agent 直接整合到瀏覽器中，而不是把擴充功能當作產品本體。專案仍在持續開發，目前尚未達到正式發布資格。

## 平台優先級

| 平台 | 優先級 | 目前方向 |
| --- | --- | --- |
| **macOS** | **目前主線** | 完成 Chromium 產品、Access Service、真實執行回歸、穩定性，以及可簽署/公證的發布候選。 |
| **iOS / iPadOS** | **下一主線** | 基於現有 SwiftUI/WKWebView 程式碼與已記錄的 Simulator 基線繼續開發，補齊真機與散布鏈路。 |
| Windows / Android / Linux | 後續 | 保留現有原始碼與手動驗證入口，目前不承諾近期發布。 |

完整階段定義見[路線圖](docs/roadmap.zh-TW.md)。macOS 滿足自己的發布條件後可以獨立發布，不需要等待 iOS 達到散布狀態。

## Aegis 目前包含什麼

- **隱私與追蹤控制：** 追蹤規則、連結清理、Cookie 分類、網路釣魚訊號以及部分指紋表面的保護。
- **瀏覽器 Agent：** 模型設定、可見計畫、瀏覽器控制的工具執行，以及敏感動作前的明確使用者接管。
- **Access Service：** 原生策略與代理路由元件，包括 fail-closed 路由與 NetworkContext 接入工作。
- **原生下載與瀏覽器整合：** 能力落在 Chromium 原生下載、設定和瀏覽器模組，而不是獨立擴充功能產品。
- **原生 iOS 產品：** 已存在 SwiftUI/WKWebView 程式碼、一般/私密設定檔隔離、內嵌 Safari/Share extensions 與 AgentKit。

詳細邊界見 [Browser](apps/browser/README.zh-TW.md)、[iOS](apps/ios/README.zh-TW.md) 和[架構](docs/architecture.zh-TW.md)。

## 目前工程證據

頂部徽章刻意代表不同範圍：

- **CI**：目前開發分支的儲存庫級品質門檻。
- **C++ 單元測試**：執行 standalone C++20 Access 測試，以及 Chromium GoogleTest wiring / patch contract；它**不代表**完整 Chromium GoogleTest 可執行檔或全部真實瀏覽器網路場景已經通過。
- **Codacy Grade**：靜態分析，不等於執行驗收或發布驗收。

完整 Chromium 建置、目前瀏覽器執行行為、真實網路場景、Developer ID 簽署、公證、安裝與升級驗收仍屬於 macOS 獨立發布門檻。

## macOS 開發入口

工具鏈由 [.mise.toml](.mise.toml) 固定：

```bash
mise install
mise exec -- node --version
mise exec -- pnpm --version
mise exec -- python3 --version
mise exec -- pnpm --filter @gcsa-aegis/browser status
```

完整本機品質門檻與儲存庫流程見 [CI 與開發指南](docs/development/ci.zh-CN.md)。Chromium 需要獨立的大型原始碼 checkout；建置與執行請閱讀 [Browser 本機流程](apps/browser/README.zh-TW.md#本機流程)和[工作區說明](WORKSPACES.zh-CN.md)。

## 開發協作流程

目前 `develop` 是維護與整合主線，日常改動遵循：

```text
最新 develop → 功能分支 → 本機驗證 → PR → Review / CI → 合併 → develop push CI
```

向預設 `main` 以及上游公開晉升屬於獨立的受審步驟。精確分支、Review、CI 與上游匯出規則統一維護在 [docs/development/ci.zh-CN.md](docs/development/ci.zh-CN.md)。

## Roadmap

1. **MAC-1 — 核心瀏覽器與 Access Service：** 收斂目前 Chromium 整合、路由和必要回歸缺口。
2. **MAC-2 — 穩定性與發布候選：** 目前原始碼可重現建置、代表性執行/隱私/效能檢查和安裝 App 驗收。
3. **MAC-3 — macOS 散布：** Developer ID 簽署、公證、封裝、全新安裝/升級/回復與明確發布授權。
4. **IOS-1 — 真機基線：** 在現有原生 iOS 程式碼上重新綁定目前原始碼，完成 iPhone/iPad 真機和生命週期驗證。
5. **IOS-2 — 產品完善：** 在真機上補齊內嵌擴充功能、策略、隱私與 Agent 整合。
6. **IOS-3 — 散布：** entitlement/provisioning、簽署、Archive、TestFlight 與 App Store 準備。

Windows 與 Android 保持後續評估，不阻塞 macOS → iOS 的產品路線。

## 文件與授權

- [路線圖](docs/roadmap.zh-TW.md) · [文件索引](docs/README.zh-TW.md) · [架構](docs/architecture.zh-TW.md)
- [Browser 工程指南](apps/browser/README.zh-TW.md) · [iOS 工程指南](apps/ios/README.zh-TW.md)
- [研究與限制](docs/research-map.zh-TW.md) · [歷史稽核紀錄](docs/audit/README.zh-TW.md)
- [變更紀錄](CHANGELOG.md) · [第三方開源致謝](THIRD_PARTY_NOTICES.md)

GCSA 原創原始碼採用 [Apache-2.0](LICENSE)。Chromium、libtorrent 與其他第三方元件保留各自授權。
