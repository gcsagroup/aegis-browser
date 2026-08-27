# GCSA-aegis

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

GCSA-aegis 是一個本機優先的隱私安全瀏覽器，產品形態為 Chromium fork。隱私、反釣魚、反追蹤、下載和可選 AI 能力直接整合在瀏覽器內，不以 Electron 套殼或獨立擴充功能作為產品。

> **狀態 — 2026-08-28：**目前原始碼已同步到 56 個頂層 Chromium 補丁，另含 2 個巢狀 V8 補丁。最新帶身分清單的本機 build-tree 產物只綁定 54 個頂層補丁及這 2 個 V8 補丁；0055、0056 尚未被該產物證據涵蓋。專案整體仍為**發行 No-Go**：沒有受信任構建證明、正式產品簽名和公證的 macOS 安裝包、安裝 App 驗收，也沒有目前原始碼的 Android 套件。

## 產品形態

- **唯一產品：**[`apps/browser`](apps/browser/README.zh-TW.md) 下的 Chromium fork。
- **策略來源：**[`packages/core`](packages/core) 提供可測試的策略、偵測器和瀏覽器生成資產。
- **瀏覽器整合：**網路、儲存、指紋、釣魚、下載、WebUI 和本機自動化控制均接入 Chromium。
- **隱私 AI：**桌面端支援本機啟發式，以及使用者設定的 OpenAI、Claude（Anthropic）或 Gemini 相容 API。遠端使用必須明確目標並確認；這不等於已完成「無遙測」證明。

## 證據邊界

原始碼同步和乾淨的 Chromium checkout 證明補丁堆疊可重播，但不證明目前原始碼已通過全部構建、執行、簽名、安裝、Android、隱私和發行門禁。

最新帶身分綁定的 build-tree 證據僅限本機，資格為 `diagnostic-only`。歷史測試數量和產物雜湊保留在帶日期的稽核記錄中；不同補丁 HEAD 的結果不能相加，也不能寫成目前發行證據。

## 快速開始

JavaScript 工具鏈固定為 Node.js `24.14.0` 和 pnpm `9.15.0`。

```bash
pnpm install --frozen-lockfile
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser status
```

準備和構建 Chromium 需要大型外部 checkout。執行網路、構建、封裝或執行階段命令前，請先閱讀 [Browser 指南](apps/browser/README.zh-TW.md)。

## 儲存庫結構

```text
apps/browser       Chromium 釘選、overlay、補丁、構建與驗證腳本
packages/core      策略、偵測器、生成器與研究性質評測程式碼
docs/              架構、路線圖、研究映射、產品頁與稽核記錄
```

## 文件

- [文件索引](docs/README.zh-TW.md)
- [架構](docs/architecture.zh-TW.md)
- [路線圖與發行門禁](docs/roadmap.zh-TW.md)
- [研究與實作映射](docs/research-map.zh-TW.md)
- [三語產品頁](docs/product.html)
- [變更日誌](CHANGELOG.zh-TW.md)

## GitHub 同步邊界

2026-08-28 已授權透過 SSH 將原始碼儲存庫同步到 `git@github.com:gcsagroup/aegis-browser.git`。該授權只涵蓋原始碼分支同步，**不**授權建立或發布 Git tag、GitHub Release、二進位檔、安裝套件、簽名憑證、公證提交、Play 上傳或正式環境部署。

## 授權

Apache-2.0，見 [LICENSE](LICENSE)。

## 測試

```bash
pnpm run quality:fast
```

該命令涵蓋儲存庫的快速 JavaScript 和腳本門禁。Chromium 原生構建、瀏覽器測試、執行矩陣、簽名、安裝 App 檢查和 Android 實機驗收是獨立門禁。
