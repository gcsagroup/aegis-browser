# Aegis

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

[![CI](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/quality.yml) [![C++ 單元測試](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main&event=push)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![目前平台：macOS](https://img.shields.io/badge/current-macOS-555?logo=apple&logoColor=white)](apps/browser)

**一個本機優先的隱私與安全瀏覽器，內建可控的 AI Agent。先做好 macOS，再推進 iPhone 與 iPad。**

Aegis 把隱私控制、安全檢查、原生瀏覽器能力和 AI Agent 直接整合到瀏覽器中。專案仍在持續開發，目前尚未達到正式發布資格。

## 平台優先級

| 平台 | 優先級 | 目前方向 |
| --- | --- | --- |
| **macOS** | **目前** | 完成 Chromium 整合、Access Service、真實執行回歸、穩定性，以及可簽署/公證的發布候選。 |
| **iOS / iPadOS** | **下一階段** | 基於現有 SwiftUI/WKWebView 程式碼與已記錄的 Simulator 基線繼續開發，補齊真機與散布鏈路。 |
| Windows / Android / Linux | 後續 | 保留現有原始碼與評估入口，目前不承諾近期發布。 |

詳細完成標準見[路線圖](docs/roadmap.zh-TW.md)。macOS 滿足自己的發布條件後可以獨立發布，不需要等待 iOS 達到散布狀態。

## Aegis 目前包含什麼

- **隱私與追蹤控制：** 追蹤規則、連結清理、Cookie 分類、網路釣魚訊號以及部分指紋表面的保護。
- **瀏覽器 Agent：** 模型設定、可見計畫、瀏覽器控制的工具執行，以及敏感動作前的明確使用者接管。
- **Access Service：** 原生策略與代理路由元件，包括 fail-closed 路由與 NetworkContext 接入。
- **原生瀏覽器整合：** 能力落在 Chromium 原生下載、設定和瀏覽器模組，而不是獨立擴充功能產品。
- **原生 iOS 產品：** SwiftUI/WKWebView、一般/私密設定檔隔離、內嵌 Safari/Share extensions 與 AgentKit。

詳細工程邊界見 [Browser 指南](apps/browser/README.zh-TW.md)、[iOS 指南](apps/ios/README.zh-TW.md)和[架構](docs/architecture.zh-TW.md)。

## 工程證據

頂部徽章代表不同範圍：

- **CI**：公共 `main` 的儲存庫級品質門檻。
- **C++ 單元測試**：執行 standalone C++20 Access 測試，以及 Chromium GoogleTest wiring / patch contract；它**不代表**完整 Chromium GoogleTest 可執行檔或全部真實瀏覽器執行情境已經通過。
- **License / 平台徽章**：描述儲存庫授權與目前產品優先級，不代表發布資格。

完整 Chromium 建置、目前瀏覽器執行行為、真實網路場景、Developer ID 簽署、公證、安裝與升級驗收仍屬於 macOS 獨立發布門檻。

## 快速開始

儲存庫固定 Node.js `22.23.1`、pnpm `9.15.0` 和 Python `3.11.9`。

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

Chromium 開發需要獨立的大型原始碼 checkout，請從 [Browser 工程指南](apps/browser/README.zh-TW.md)開始。原生 Apple 平台開發請閱讀 [iOS 工程指南](apps/ios/README.zh-TW.md)。

## Roadmap

1. **MAC-1 — 核心瀏覽器與 Access Service：** 收斂目前 Chromium 整合、路由和必要回歸缺口。
2. **MAC-2 — 穩定性與發布候選：** 目前原始碼可重現建置、代表性執行/隱私/效能檢查和安裝 App 驗收。
3. **MAC-3 — macOS 散布：** Developer ID 簽署、公證、封裝、全新安裝/升級/回復與明確發布授權。
4. **IOS-1 — 真機基線：** 在現有原生 iOS 程式碼上重新綁定目前原始碼，完成 iPhone/iPad 真機和生命週期驗證。
5. **IOS-2 — 產品完善：** 在真機上補齊內嵌擴充功能、策略、隱私與 Agent 整合。
6. **IOS-3 — 散布：** entitlement/provisioning、簽署、Archive、TestFlight 與 App Store 準備。

Windows、Android 與 Linux 保持後續評估，不阻塞 macOS → iOS 的產品路線。

## 參與貢獻

歡迎提交貢獻。每個 PR 應保持範圍聚焦，並提供與改動相關的測試或驗證證據。

1. Fork 本儲存庫。
2. 從目前 `main` 建立獨立 topic branch。
3. 完成一個聚焦的改動，並補充或更新相關測試。
4. 按受影響模組的文件執行適用的本機檢查。
5. 將分支推送到自己的 Fork，並向本儲存庫 `main` 提交 Pull Request。
6. 在 PR 描述中說明問題、改動範圍、測試證據和仍存在的限制。
7. 在同一個 PR 中處理 Review 回饋，不改寫無關歷史。

Chromium 改動請先閱讀 [Browser 指南](apps/browser/README.zh-TW.md)；iOS 改動請閱讀 [iOS 指南](apps/ios/README.zh-TW.md)。

## 文件與授權

- [路線圖](docs/roadmap.zh-TW.md) · [文件索引](docs/README.zh-TW.md) · [架構](docs/architecture.zh-TW.md)
- [Browser 工程指南](apps/browser/README.zh-TW.md) · [iOS 工程指南](apps/ios/README.zh-TW.md)
- [研究與限制](docs/research-map.zh-TW.md) · [歷史稽核紀錄](docs/audit/README.zh-TW.md)
- [變更紀錄](CHANGELOG.md) · [第三方開源致謝](THIRD_PARTY_NOTICES.md)

GCSA 原創原始碼採用 [Apache-2.0](LICENSE)。Chromium、libtorrent 與其他第三方元件保留各自授權。
