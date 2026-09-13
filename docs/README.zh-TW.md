# 文件

[English](README.md) | [简体中文](README.zh-CN.md) | **繁體中文**

本目錄保存 GCSA-aegis 的公開產品架構、路線圖、研究邊界、產品頁，以及帶日期的本機稽核記錄。

> **2026-09-14 原始碼更新：介面整改與瀏覽器更新：** 目前原始碼包含 113 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁。本機 macOS 驗收為 Ver 1.1 (018)：32 項整改完成，18 項原生測試、116 項介面回歸通過，170 條改動文案及翻譯佔位符檢查通過。Windows/Android 實機及真實 Release 安裝尚未驗收；本次僅提交原始碼，不發布二進位檔或 tag。 [018 验收记录](ui-copy-acceptance.zh-CN.md)

> **歷史邊界 — 2026-09-10：** Browser Agent v2 候選原始碼包含 108 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁，可精確重放到 Chromium 提交 原始碼樹 `319366182c31108e29e62d2f2199aff29a0b86e8`。平台建置和驗收仍是獨立門禁，這個原始碼身分不代表公開發行合格。Phase 2 仍是 synthetic formal fixture，Phase 3 是 13 樣本 operator-blinded public pilot，召回率為 `1/3`；兩者都不能泛化為廣義惡意 JavaScript 偵測結論。專案整體仍為發行 No-Go。

[2026-09-10 main 合併與驗證](audit/main-consolidation-2026-09-10.md)

## 從這裡開始

- [專案概覽](../README.zh-TW.md)
- [架構](architecture.zh-TW.md)
- [路線圖與發行門禁](roadmap.zh-TW.md)
- [研究與實作映射](research-map.zh-TW.md)
- [變更日誌](../CHANGELOG.zh-TW.md)
- [三語產品頁](product.html)
- [Browser 構建與驗證指南](../apps/browser/README.zh-TW.md)
- [原生 iOS 工程指南](../apps/ios/README.zh-TW.md)
- [Browser Agent v2 使用者指南](aegis-browser-agent-v2-user-guide.zh-TW.md)
- [Browser Agent v1 歷史使用者指南](aegis-browser-agent-v1-user-guide.zh-TW.md)
- [Browser Agent 架構](aegis-browser-agent-v1-architecture.zh-TW.md)
- [Browser Agent v2 架構與原型決策](aegis-browser-agent-v2-architecture.zh-TW.md)

## 狀態用語

- **已進原始碼：**程式碼或補丁存在，不等於構建或執行證明。
- **原始碼已同步：**儲存庫 overlay、補丁堆疊與外部 Chromium checkout 一致。
- **本機已驗證：**明確命名的原始碼、產物、測試和執行範圍通過了記錄中的本機門禁。
- **發行合格：**同一產物的身分、信任、簽名、安裝、平台、隱私和分發門禁全部通過。GCSA-aegis 尚未達到該狀態。

不同補丁 HEAD 的結果不能相加。歷史 App、APK、測試數量或雜湊只證明記錄中命名的快照。

## 帶日期的計畫與稽核

檔名中帶日期的文件屬於證據快照、計畫或實作記錄。其「目前」只指記錄日期，不一定指目前儲存庫 HEAD。公開現況以[路線圖](roadmap.zh-TW.md)為準；帶日期文件應作為歷史證據保留，不應靜默改寫其中的測量結果。

## 語言約定

- 英文使用無後綴主文件，由 GitHub 預設展示。
- 簡體中文使用 `.zh-CN.md`。
- 繁體中文使用 `.zh-TW.md`。
- 每份公開文件開頭提供三個語言版本的互鏈。
- 三種翻譯中的版本號、日期、識別碼、雜湊、命令和證據邊界必須等價。

`product.html` 特意保留為一個檔案，內建英文、簡體中文和繁體中文切換。

## 原始碼同步不等於發行

2026-08-28 的授權允許透過 SSH 將原始碼同步到 `git@github.com:gcsagroup/aegis-browser.git`，但不授權 tag、GitHub Release、二進位檔、安裝套件、簽名或公證操作、Play 上傳或正式環境部署。
