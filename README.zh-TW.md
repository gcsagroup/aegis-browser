# GCSA-aegis

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

[![品質門](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml)

CI 包含必要的 macOS 品質任務及 Linux/Windows 覆蓋率任務，不代表完整 macOS Chromium 建置。

[![iOS Swift iPhone 快照：83.57%](assets/badges/swift-iphone-snapshot.svg)](docs/audit/swift-coverage-snapshot-2026-09-14.md)
[![iOS Swift iPad 快照：84.99%](assets/badges/swift-ipad-snapshot.svg)](docs/audit/swift-coverage-snapshot-2026-09-14.md)

Swift 模擬器測試覆蓋率快照（單元 + UI 測試）：**2026-09-14**，測試 SHA `66ca5ee`（並非目前 `main` 覆蓋率）。兩個數值分別來自 iOS 模擬器產品 Swift 原始碼測量，尚無僅單元測試的獨立百分比；詳見[範圍與證據](docs/audit/swift-coverage-snapshot-2026-09-14.md)。

GCSA-aegis 是一個本機優先的隱私與安全瀏覽器專案，現有兩條產品線：[`apps/browser`](apps/browser/README.zh-TW.md) 下的 Chromium 分支，以及 [`apps/ios`](apps/ios/README.zh-TW.md) 下的原生 iOS 瀏覽器。核心能力整合在各自的瀏覽器產品內；專案不會復活已退役的獨立擴充功能產品。

> **2026-09-14 原始碼更新：介面整改與瀏覽器更新：** 目前原始碼包含 113 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁。本機 macOS 驗收為 Ver 1.1 (018)：32 項整改完成，18 項原生測試、116 項介面回歸通過，170 條改動文案及翻譯佔位符檢查通過。Windows/Android 實機及真實 Release 安裝尚未驗收；本次僅提交原始碼，不發布二進位檔或 tag。 [018 验收记录](docs/ui-copy-acceptance.zh-CN.md)

> **歷史狀態 — 2026-09-10：** Browser Agent v2 候選原始碼包含 108 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁，可精確重放到 Chromium 提交 原始碼樹 `319366182c31108e29e62d2f2199aff29a0b86e8`。57、65、67、95 和 97 補丁記錄只保留為歷史證據。原生 iOS 產品仍只在已記錄的 Simulator 範圍內為 **SIMULATOR_QUALIFIED**。專案整體仍是 **發行 No-Go**，尚需受信任證明、正式簽署、公證、已安裝分發套件驗收，以及本輪明確後置的 iOS 門禁。

[2026-09-10 main 合併與驗證](docs/audit/main-consolidation-2026-09-10.md)

一般桌面 Profile 和 Android 都會顯示 Agent 入口。第一次任務可直接設定並啟用使用者選擇的模型，不要求使用者先選工作流程或預先開啟網頁。WebMCP 與交易提交能力繼續預設關閉，最終結帳/付款必須由使用者接管。

## 產品形態

- **Chromium 產品線：** [`apps/browser`](apps/browser/README.zh-TW.md) 負責 Chromium 固定版本、補丁堆疊、瀏覽器整合、建置和平台封裝邊界。
- **原生 iOS 產品線：** [`apps/ios`](apps/ios/README.zh-TW.md) 已實作 SwiftUI/WKWebView 瀏覽器、一般與私密設定檔隔離、內嵌 Safari/Share extensions 和 Agent Broker。
- **共享策略與合約來源：** [`packages/core`](packages/core) 提供可測試策略、產生資產，以及由 TypeScript 與 Swift 共用的 Agent Contract v1 Schema 和 Golden Vectors。
- **iOS Agent 範圍：** 深度研究、瀏覽器管家、安全下載和購物助手四個受控工作流程回傳確定性結果，可離線驗證；這不構成生產遠端模型路徑的證據。
- **擴充功能邊界：** Safari 與 Share target 是 iOS App 的內嵌元件；獨立 `apps/extension` 產品仍被禁止。

## 證據邊界

原始碼同步、乾淨的外部 Chromium checkout 和 iOS Simulator 資格屬於不同證據層級，均不能證明對應目前原始碼已通過全部建置、執行、簽署、安裝、真機、隱私、商店和發布門檻。

歷史 Chromium 測試數量、清單和產物雜湊保留在附日期的稽核紀錄中，不得跨補丁 HEAD 拼接或寫成目前發行證據。研究證據也必須分開：Phase 2 是 synthetic formal fixture，Phase 3 是 13 樣本 operator-blinded public pilot，召回率為 `1/3`；兩者都不能泛化為廣義惡意 JavaScript 偵測結論。iOS 的 `SIMULATOR_QUALIFIED` 僅限具名 Simulator 路徑，不是真機、散布或 App Store 證據。

## 快速開始

JavaScript 工具鏈固定為 Node.js `22.23.1` 和 pnpm `9.15.0`。

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

準備和建置 Chromium 需要大型外部 checkout。執行網路、建置、封裝或執行命令前，請先閱讀[瀏覽器指南](apps/browser/README.zh-TW.md)。原生 App 的建置與測試說明見 [iOS 工程指南](apps/ios/README.zh-TW.md)；其安全預設測試入口是：

```bash
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

## 儲存庫結構

```text
apps/browser       Chromium 固定版本、overlay、補丁、建置與驗證腳本
apps/ios           原生 iOS App、內嵌擴充功能、AgentKit 與 Simulator 測試
packages/core      共享策略、偵測器、產生資產與 Agent Contract v1
docs/              架構、路線圖、研究映射、產品頁與稽核紀錄
```

## 文件

- [文件索引](docs/README.zh-TW.md)
- [架構](docs/architecture.zh-TW.md)
- [路線圖與發布門檻](docs/roadmap.zh-TW.md)
- [iOS 工程指南](apps/ios/README.zh-TW.md)
- [研究到實作映射](docs/research-map.zh-TW.md)
- [三語產品頁](docs/product.html)
- [更新日誌](CHANGELOG.md)

## GitHub 同步邊界

2026-08-28 已授權透過 SSH 將原始碼儲存庫同步到 `git@github.com:gcsagroup/aegis-browser.git`。該授權僅涵蓋原始碼分支同步，不授權建立或發布 Git tag、GitHub Release、二進位檔、安裝套件、簽署憑證、公證提交、Play 上傳、TestFlight 建置、App Store 提交或生產部署。

## 授權

感謝讓 Aegis 成為可能的開源專案維護者與貢獻者。[第三方開源鳴謝](THIRD_PARTY_NOTICES.md)列出了瀏覽器基礎、直接相依套件、可選實驗元件與開發工具。

GCSA 原創原始碼採用 Apache-2.0。Chromium、libtorrent 與其他第三方元件保留各自授權；詳見 [LICENSE](LICENSE) 與[第三方聲明](THIRD_PARTY_NOTICES.md)。

## 測試

```bash
pnpm run quality:fast
bash apps/ios/scripts/run-simulator-tests.sh --dry-run
```

這些命令涵蓋儲存庫快速 JavaScript/腳本門檻和不產生變更的 iOS Simulator 預檢。[CI 指南](docs/development/ci.zh-CN.md)定義各語言實際量測範圍與 Codacy 準備狀態；不同語言百分比不得合併成「全儲存庫覆蓋率」。Chromium 原生建置與目前頭執行矩陣、iOS `--execute` 結果、真機、簽署、封裝、安裝和商店驗收仍是獨立門檻。
