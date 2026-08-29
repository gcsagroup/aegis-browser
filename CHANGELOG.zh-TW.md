# 變更日誌

[English](CHANGELOG.md) | [简体中文](CHANGELOG.zh-CN.md) | **繁體中文**

本文件記錄專案的重要變更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，專案計畫採用[語意化版本](https://semver.org/lang/zh-TW/)。

軟體套件版本仍為 `0.1.0`，但尚未發布 `0.1.0` Release、Git tag 或二進位分發物。以下內容全部仍屬**未發布**。

## [未發布]

### 發行狀態

- 目前整合原始碼已同步到 67 個頂層 Chromium 補丁，另含 2 個巢狀 V8 補丁。
- 先前的 57 補丁診斷清單和 65 補丁 Agent 驗收僅為歷史證據，均不綁定目前 67 補丁 HEAD，也不能為它授予資格。
- 專案整體仍為發行 No-Go。原始碼同步不授權 tag、GitHub Release、二進位檔、簽名、公證、Play 上傳或正式環境部署。

### 新增

- 瀏覽器級 Agent 任務啟動：從空白頁或內部頁面輸入目標時，明確 URL 會直接開啟，一般目標會使用使用者預設搜尋引擎自動查找；純書籤管家任務不再要求先開啟網頁。
- Chromium 原生隱私安全控制、網站保護介面、釣魚解釋和有界工作階段活動記錄。
- 本機威脅情報索引、有界釣魚頁面訊號和憑證意圖檢查。
- HTTP(S) 平行下載控制、Metalink 支援，以及帶有界預設值的 BT/Magnet 整合。
- Canvas、OffscreenCanvas、Audio、WebGL 和部分 WebGPU 表面的反指紋措施。
- 僅觀察 MinerGuard 訊號，以及研究性質的 AST、來源流、聯邦模擬和 V8 bytecode shadow 原型。
- 使用者設定的 OpenAI、Claude（Anthropic）和 Gemini 相容模型 API，以及綁定精確文件工作階段的頁內摘要入口。
- 瀏覽器掌控的 Agent：包含 Observe/Ask/Act 模式、書籤與 URL 維護、有界瀏覽/下載/工作流程/監控工具、審批回執、取消、稽核歷史，以及最終購買前的使用者接管。
- 英文、簡體中文和繁體中文公開文件。

### 變更

- 產品收斂為 Chromium fork；歷史 Extension 和 Electron 方向不再屬於交付物。
- 公開狀態文案明確分開原始碼整合、自動化測試、build-tree 產物、執行證據和發行資格。
- 可選遠端摘要服務採用相容格式，不把行為綁定到特定產品名稱。

### 修正

- Chromium 背景抓取日誌與 vpython wheel/proxy 快取現在跟隨 `CHROMIUM_ROOT` 或 `.chromium-root` 選取的 checkout，不再靜默寫入已停用的舊 checkout 路徑。
- 修正正常啟動看不到 Browser Agent 工具列/側欄入口的問題，並為既有 Profile 增加一次性固定遷移。
- 修正 Agent WebUI 未送出側欄就緒通知、導致工具列和設定入口點擊後持續等待且介面不出現的問題；新增不繞過正式等待路徑的迴歸測試。
- Profile 執行仍需明確開啟，實驗性 WebMCP 與交易能力繼續預設關閉。

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
- 在模型層以下強制執行 Browser Agent scope、文件綁定、Profile 隔離、秘密脫敏、SSRF 控制、精確審批、瀏覽器側結果驗證和 fail-closed 恢復。

### 已知限制

- 沒有受信任構建證明、正式產品 Developer ID 簽名、hardened runtime 公證、stapling 或安裝 App 驗收。
- 沒有目前原始碼 Android APK/AAB，也沒有合格的 Linux Android 構建環境。
- Chromium 出站、遙測、更新、崩潰報告和代表性功能行為稽核仍未完成。
- Phase 2 研究使用 synthetic formal fixture。Phase 3 是獨立的 13 樣本 operator-blinded public pilot，召回率為 `1/3`；兩者都不能泛化為正式環境準確率、誤報率或安全證明。
