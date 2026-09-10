# 變更日誌

[English](CHANGELOG.md) | [简体中文](CHANGELOG.zh-CN.md) | **繁體中文**

本文件記錄專案的重要變更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，專案計畫採用[語意化版本](https://semver.org/lang/zh-TW/)。

軟體套件版本仍為 `0.1.0`，但尚未發布 `0.1.0` Release、Git tag 或二進位分發物。以下內容全部仍屬**未發布**。

## [未發布]

### 發行狀態

- Browser Agent v2 已同步到 106 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁，並精確重放到 `383d157c6f3601101038aef6ff964e61b6af7b4f`（tree `2c509e07ec25fa8811adae17f9826e967c9bcee1`）。
- 補丁 0106 修復 Windows 介面執行緒讀取語言資源造成的崩潰，保留遠端控制安全提示；新成品的跨平台回歸驗收仍待完成。
- 57、65、67、95 和 97 補丁記錄只保留為歷史證據，不能為目前 v2 成品授予資格。
- 專案整體仍為發行 No-Go。原始碼同步不授權 tag、GitHub Release、二進位檔、簽名、公證、Play 上傳或正式環境部署。

### 新增

- 開發版新增 ASCII 走私防護：反釣魚檢測及模型請求前清理隱藏 Unicode，拒絕帶隱藏載體的操作參數，保留合法 emoji。macOS 原生、介面及本地 Qwen 驗證通過；Windows/Android 新成品仍待驗收。
- Browser Agent v2 原生混合 Runtime：模型優先理解/規劃，瀏覽器掌控執行/觀察/驗證，確定性點名網站目標，以及一次有界模型格式修復後的安全 R0 唯讀恢復。
- 桌面和 Android 新手入口、目前頁面綁定、頁面摘要/商品比較/書籤/URL 檢查/官方下載/研究等常用工作，以及獨立的定時自動化工作區。
- Chromium 原生隱私安全控制、網站保護介面、釣魚解釋和有界工作階段活動記錄。
- 本機威脅情報索引、有界釣魚頁面訊號和憑證意圖檢查。
- HTTP(S) 平行下載控制、Metalink 支援，以及帶有界預設值的 BT/Magnet 整合。
- Canvas、OffscreenCanvas、Audio、WebGL 和部分 WebGPU 表面的反指紋措施。
- 僅觀察 MinerGuard 訊號，以及研究性質的 AST、來源流、聯邦模擬和 V8 bytecode shadow 原型。
- 使用者設定的 OpenAI、Claude（Anthropic）和 Gemini 相容模型 API，以及綁定精確文件工作階段的頁內摘要入口。
- 瀏覽器掌控的 Agent：包含有範圍約束的書籤/URL/頁面/下載/監控工具、核准回執、取消、稽核歷史，以及最終購買前的使用者接管。
- 英文、簡體中文和繁體中文公開文件。

### 變更

- 透過 Chromium 列舉介面讀取不可合併的 `Retry-After` 回應標頭，避免啟用斷言的 Windows 瀏覽器在有界同源書籤 URL 檢查期間崩潰。
- 產品收斂為 Chromium fork；歷史 Extension 和 Electron 方向不再屬於交付物。
- 公開狀態文案明確分開原始碼整合、自動化測試、build-tree 產物、執行證據和發行資格。
- 可選遠端摘要服務採用相容格式，不把行為綁定到特定產品名稱。

### 修正

- Chromium 背景抓取日誌與 vpython wheel/proxy 快取現在跟隨 `CHROMIUM_ROOT` 或 `.chromium-root` 選取的 checkout，不再靜默寫入已停用的舊 checkout 路徑。
- 修正正常啟動看不到 Browser Agent 工具列/側欄入口的問題，並為既有 Profile 增加一次性固定遷移。
- 修正 Agent WebUI 未送出側欄就緒通知、導致工具列和設定入口點擊後持續等待且介面不出現的問題；新增不繞過正式等待路徑的迴歸測試。
- 一般 Profile 可在第一次工作中啟用使用者選擇的 provider/model；實驗性 WebMCP 與交易能力繼續預設關閉。
- 把技術性規劃失敗改為一次有界 schema 修復、白名單唯讀恢復和新手可讀的重試提示。
- 把模型提出的分頁/文件能力綁定到瀏覽器即時核准的工作上下文：單分頁唯讀工作不再因模型 ID 輕微漂移而失敗，存在歧義或風險較高的動作仍維持 fail closed。
- 將 Agent 工作持久化移到允許阻塞的專用序列，消除 UI 序列上的 SQLite 當機，同時保留脫敏工作記錄和有界關閉行為。
- 書籤 URL 檢查遇到同源 HTTP 429 後，會把伺服器重試時窗記錄到該來源其餘 URL 並確定性結束，不再逐一等待。

- 加固 Profile 結束、跨序列報告投遞、補丁重播、構建身分、封裝保護和本機簽名檢查。
- 為獨立的主要無痕 Profile 補齊 Aegis 核心、Agent、Actor、設定/選單/工具列/側欄和下載介面；Guest、System 與輔助 OTR Profile 繼續 fail closed。
- 把本機 ad-hoc 簽名移到構建身分 finalize 之前，啟動已驗證 App 時不再修改已綁定位元組。
- Android 封裝現在拒絕符號連結和路徑逸出，並以不覆寫既有產物的原子方式發布輸出。
- 降低部分過濾列表與 Canvas 熱路徑開銷，並修正若干瀏覽器生命週期和 WebUI 問題。

### 安全

- 對所選本機 CDP 路徑套用精確文件授權和遠端來源傳播。
- 增加 fail-closed 摘要脫敏、敏感頁面回退、遠端目標明確確認，以及不回顯、由系統加密的 API 憑證。
- Release 驗證現在檢查密封 schema、目前原始碼與依賴狀態、構建圖和完整產物樹；只明確排除本機 `.DS_Store` 中繼資料。
- MinerGuard 和 V8 bytecode shadow 保持僅觀察；兩者都不能授權腳本阻斷或「通用惡意 JavaScript 防護」聲明。
- 在模型層以下強制執行 Browser Agent scope、文件綁定、Profile 隔離、秘密脫敏、SSRF 控制、精確審批、瀏覽器側結果驗證和 fail-closed 恢復。
- 增加桌面與 Android 處理程序層級遠端 CDP latch：建立主要無痕 Profile 會在延遲啟動或目標所有權檢查之前停止並阻斷桌面 HTTP/pipe 與 Android HTTP/socket 傳輸。桌面只能由一般 Profile 明確重新啟用，Android 在處理程序重新啟動前維持鎖止。
- 預設 NetLog 擷取會遮蔽模型 API key 請求標頭，Actor 私密 journal、診斷與 trace 也會抑制私密資料。明確使用 Chromium 敏感模式的 NetLog 仍沿用其敏感資料語意，必須按可能包含秘密處理。
- 使用不透明且精確依 Profile 隔離的網路/CNAME 分區，以及只存在於記憶體的無痕 Advanced/Torrent 所有權。關閉無痕會取消作用中的 Agent 下載與種子傳輸並撤銷控制，同時保留已寫入的種子位元組，以及已完成下載和獲准書籤寫入的 Chromium 原生持久語意。

### 已知限制

- 沒有受信任構建證明、正式產品 Developer ID 簽名、hardened runtime 公證、stapling 或安裝 App 驗收。
- Android 與 Windows 目前原始碼建置/裝置資格正在驗證；完成精確身分和執行記錄前不接受任何套件。
- Chromium 出站、遙測、更新、崩潰報告和代表性功能行為稽核仍未完成。
- Phase 2 研究使用 synthetic formal fixture。Phase 3 是獨立的 13 樣本 operator-blinded public pilot，召回率為 `1/3`；兩者都不能泛化為正式環境準確率、誤報率或安全證明。
