# GCSA-aegis

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

## 專案簡介

GCSA-aegis 是一個以 Chromium 為基礎的瀏覽器專案，將隱私控制、安全檢查與 AI Agent 整合到瀏覽器中。專案採用本機優先的方式，目標是減少不必要的資料分享，讓使用者更自主地管理瀏覽與自動化任務。

## 專案檢查

[![CI](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml/badge.svg?branch=develop)](https://github.com/quinn521/aegis-browser/actions/workflows/quality.yml?query=branch%3Adevelop) [![License: Apache-2.0](assets/badges/license.svg)](LICENSE) [![Codacy Grade](https://app.codacy.com/project/badge/Grade/72c871eba82e471ebc05eaacd4d45218?branch=develop)](https://app.codacy.com/gh/quinn521/aegis-browser/dashboard) [![Current platform: macOS](https://img.shields.io/badge/platform-macOS-555?logo=apple&logoColor=white)](apps/browser)

CI 與 Codacy Grade 指向個人開發儲存庫的 `develop` 分支，分別反映不同檢查；徽章不代表發行驗收通過。

## 開發狀態

**目前優先開發 macOS，專案仍在開發中，尚未達到發行驗收標準。** 自動 CI 涵蓋儲存庫品質檢查、共享策略、指令碼與獨立原生測試。完整 Chromium 建置、目前瀏覽器執行行為、真實網路驗證、簽署、公證及安裝套件驗收仍是獨立門檻。

Linux、Windows、iOS 與 Android 工作後置。既有平台程式碼與手動驗證入口保留在相關文件中。

## 已實作的核心能力

原始碼包含以下元件，並透過單元測試或測試資料檢查驗證明確範圍內的行為：

- **隱私與追蹤控制：** [共享策略](packages/core/src/policy.ts)結合追蹤規則、連結參數清理、Cookie 分類與文字隱私檢查。
- **釣魚風險評估：** [偵測器](packages/core/src/phish/detector.ts)評估網址與頁面訊號並回傳風險原因。現有測試範圍不等於真實環境偵測準確率。
- **瀏覽器 Agent：** [桌面 Agent 介面](apps/browser/overlay/chrome/browser/resources/aegis_agent/agent.ts)提供任務狀態與模型選擇控制，並有[介面邏輯檢查](apps/browser/scripts/agent-ui-status_test.mjs)。模型設定及端到端執行驗證仍需另行完成。
- **存取規則：** [原生路由與策略元件](apps/browser/overlay/components/aegis_access)實作網站規則比對與路由規劃。獨立測試不代表正式環境網路行為已驗證。

## 在 macOS 上開始開發

使用 [.mise.toml](.mise.toml) 固定的版本，並遵循[環境與品質指南](docs/development/ci.zh-CN.md)。安裝固定工具後，先檢查環境與瀏覽器工作區：

```bash
mise exec -- node --version
mise exec -- pnpm --version
mise exec -- python3 --version
mise exec -- pnpm --filter @gcsa-aegis/browser status
```

相依套件安裝與完整品質門檻見上述 CI 指南。準備及建置 Chromium 請遵循 [Mac 本機建置流程](apps/browser/README.zh-TW.md#本機流程)及[工作區說明](WORKSPACES.zh-CN.md)。Chromium 需要獨立的大型原始碼 checkout；狀態命令不會下載或建置它。固定版本記錄於 [CHROMIUM_VERSION](apps/browser/CHROMIUM_VERSION)。

## 開發協作流程

從最新 DEV `develop` 建立功能分支，向 `develop` 提交 PR，並驗證合併提交的 CI。經過批准的公開變更隨後可獨立匯出至上游 `main`，接受上游自己的審查與 CI。個人儲存庫的 `main` 只透過明確的快轉同步鏡像上游。

完整流程見 [CI 與上游工作指南](docs/development/ci.zh-CN.md)。原始碼整合不等於發布二進位檔或發行版本。

## 文件、授權與致謝

- [文件索引](docs/README.zh-TW.md)、[架構](docs/architecture.zh-TW.md)與[路線圖](docs/roadmap.zh-TW.md)
- [研究與限制](docs/research-map.zh-TW.md)及[歷史稽核紀錄](docs/audit/README.zh-TW.md)
- 後置平台：[iOS](apps/ios/README.zh-TW.md) 與 [Android](apps/browser/docs/android.zh-TW.md)
- [變更紀錄](CHANGELOG.md)與[第三方開源致謝](THIRD_PARTY_NOTICES.md)

GCSA 原創原始碼採用 [Apache-2.0](LICENSE)。Chromium、libtorrent 與其他第三方元件保留各自授權。感謝這些開源專案的維護者與貢獻者。
