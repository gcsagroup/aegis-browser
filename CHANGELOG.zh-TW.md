# 變更日誌

[English](CHANGELOG.md) | [简体中文](CHANGELOG.zh-CN.md) | **繁體中文**

本文件記錄專案的重要變更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，專案計畫採用[語意化版本](https://semver.org/lang/zh-TW/)。

軟體套件版本仍為 `0.1.0`，但尚未發布 `0.1.0` Release、Git tag 或二進位分發物。以下內容全部仍屬**未發布**。

## [未發布]

### 發行狀態

- 目前原始碼整合已同步到 56 個頂層 Chromium 補丁，另含 2 個巢狀 V8 補丁。
- 最新帶身分清單的本機 build-tree 只涵蓋 54 個頂層補丁及這 2 個 V8 補丁；相對該證據，0055 和 0056 僅有原始碼同步。
- 專案整體仍為發行 No-Go。原始碼同步不授權 tag、GitHub Release、二進位檔、簽名、公證、Play 上傳或正式環境部署。

### 新增

- Chromium 原生隱私安全控制、網站保護介面、釣魚解釋和有界工作階段活動記錄。
- 本機威脅情報索引、有界釣魚頁面訊號和憑證意圖檢查。
- HTTP(S) 平行下載控制、Metalink 支援，以及帶有界預設值的 BT/Magnet 整合。
- Canvas、OffscreenCanvas、Audio、WebGL 和部分 WebGPU 表面的反指紋措施。
- 僅觀察 MinerGuard 訊號，以及研究性質的 AST、來源流、聯邦模擬和 V8 bytecode shadow 原型。
- 使用者設定的 OpenAI、Claude（Anthropic）和 Gemini 相容模型 API，以及綁定精確文件工作階段的頁內摘要入口。
- 英文、簡體中文和繁體中文公開文件。

### 變更

- 產品收斂為 Chromium fork；歷史 Extension 和 Electron 方向不再屬於交付物。
- 公開狀態文案明確分開原始碼整合、自動化測試、build-tree 產物、執行證據和發行資格。
- 可選遠端摘要服務採用相容格式，不把行為綁定到特定產品名稱。

### 修正

- 加固 Profile 結束、跨序列報告投遞、補丁重播、構建身分、封裝保護和本機簽名檢查。
- 將摘要、WebUI 和工具列存取嚴格綁定到所屬一般 Profile；其他 Profile 與無痕 Profile 現在會 fail closed。
- 把本機 ad-hoc 簽名移到構建身分 finalize 之前，啟動已驗證 App 時不再修改已綁定位元組。
- Android 封裝現在拒絕符號連結和路徑逸出，並以不覆寫既有產物的原子方式發布輸出。
- 降低部分過濾列表與 Canvas 熱路徑開銷，並修正若干瀏覽器生命週期和 WebUI 問題。

### 安全

- 對所選本機 CDP 路徑套用精確文件授權和遠端來源傳播。
- 增加 fail-closed 摘要脫敏、敏感頁面回退、遠端目標明確確認，以及不回顯、由系統加密的 API 憑證。
- Release 驗證現在檢查密封 schema、目前原始碼與依賴狀態、構建圖和完整產物樹；只明確排除本機 `.DS_Store` 中繼資料。
- MinerGuard 和 V8 bytecode shadow 保持僅觀察；兩者都不能授權腳本阻斷或「通用惡意 JavaScript 防護」聲明。

### 已知限制

- 沒有受信任構建證明、正式產品 Developer ID 簽名、hardened runtime 公證、stapling 或安裝 App 驗收。
- 沒有目前原始碼 Android APK/AAB，也沒有合格的 Linux Android 構建環境。
- Chromium 出站、遙測、更新、崩潰報告和代表性功能行為稽核仍未完成。
- 研究評測使用合成 fixture，不能作為正式環境準確率、誤報率或安全證明。
