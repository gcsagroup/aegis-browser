[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# 補丁

本目錄中的補丁套用於本機 checkout 內固定的 Chromium 提交（`../CHROMIUM_COMMIT`）之上。

## 約定

1. 檔案命名為 `0001-short-title.patch`、`0002-...`
2. 按套用順序列入 `series`
3. 優先採用小型、易審查的差異，透過 `aegis/` 整合層接入，避免大範圍改寫 Blink
4. 不要把完整 Chromium 原始碼樹放進本 Git 儲存庫

## 目前本機補丁序列

狀態「series 中」只表示補丁檔案列在目前本機 `series`；不表示已經進入上游 Chromium、通過 Release 或 Android 門檻，也不表示可以發布。2026-08-25 的 49 補丁記錄僅保留為歷史快照。2026-08-29 的整合原始碼達到 **67 個 Chromium 補丁 + 2 個巢狀 V8 補丁**：0057–0065 是 Browser Agent 整合，0066 是設定、關於頁與更新狀態，0067 是視覺品牌。更早的 57/58 補丁診斷證據和 65+2 Agent 驗收都不能賦予最終 67+2 原始碼資格。桌面成品是否匹配必須以新執行的 `browser:status` 和對應驗收記錄中的新鮮度門檻為準；每次 series 變化後都要重新驗證。

| ID | 目的 | 狀態 |
|----|------|------|
| 0001 | 增加 `chrome/browser/aegis/` 樁程式碼與 feature flag | series 中 |
| 0002 | 接入網路節流與 tracker host 請求取消 | series 中 |
| 0003 | 內嵌 `chrome://aegis` WebUI 設定介面 | series 中 |
| 0004 | 透過導覽節流增加網路釣魚攔截頁 | series 中 |
| 0005 | 增加 Canvas、Audio 與 WebGL 的 FingerprintGuard 擾動接入點 | series 中 |
| 0006 | 將 `packages/core` 策略快照封裝為 C++ `.inc` 與 JSON | series 中 |
| 0007 | 增加 EasyList 編譯器與執行階段過濾清單更新器 | series 中 |
| 0008 | 去除追蹤查詢參數並增加 Cookie 清理器 | series 中 |
| 0009 | 揭示 CNAME 並清除跳轉追蹤 Cookie | series 中 |
| 0010 | 增加網路釣魚 URL 啟發式與可解釋攔截頁 | series 中 |
| 0011 | 增加面向密碼表單與緊迫文案的網路釣魚頁面感知 | series 中 |
| 0012 | 透過 gin 增加 JavaScript 策略 worker 與 Privacy AI/Ollama sidecar | series 中 |
| 0013 | 擾動 WebGPU `adapter.info` | series 中 |
| 0014 | 修正啟動 DCHECK；策略 worker 改在 `chrome://aegis` 執行 | series 中 |
| 0015 | 在設定和選單中增加 `chrome://aegis` 入口 | series 中 |
| 0016 | 增加模組說明文案與 Ollama 模型設定 | series 中 |
| 0017 | 啟動後延後過濾清單和 Cookie 清掃 | series 中 |
| 0018 | EasyList 啟動時使用本機 `compiled.json` 快取 | series 中 |
| 0019 | 更新 EasyList 快取：24 小時檢查、HTTP 304 處理與失敗退避 | series 中 |
| 0020 | 增加易懂的攔截頁文案、摘要與工作階段清理清單 | series 中 |
| 0021 | 增加 Cookie 精確清單與第一方收集路徑攔截 | series 中 |
| 0022 | 增加工作階段清單即時重新整理、Canvas 自我檢查與 GA4 收集假象 | series 中 |
| 0023 | 讓攔截可見、去除 Referer 參數、標註 Cookie，並增加本機 CDP/AI 控制 | series 中 |
| 0024 | 從遠端 CDP 目標清單隱藏內部頁，並在工作階段清單顯示 Agent 連線 | series 中 |
| 0025 | 本機 CDP 連線時顯示瀏覽器橫幅，並增加開啟 `chrome://aegis` 的按鈕 | series 中 |
| 0026 | 在 `chrome://aegis` 一次檢測 Canvas、WebGL、Audio 與 WebGPU | series 中 |
| 0027 | Audio 指紋按網站只擾動一次，並涵蓋 `copyFromChannel` | series 中 |
| 0028 | 按網站穩定化 WebGPU limits 與 subgroup 數值 | series 中 |
| 0029 | Android 套件包含 `chrome://aegis`，並為 Play 預留顯示名稱和套件身分 | series 中 |
| 0030 | Android 設定開啟 `chrome://aegis`，並在行動端停用 CDP/Ollama | series 中 |
| 0031 | 強化摘要/Ollama、網路釣魚與本機 CDP 安全邊界及迴歸測試 | series 中 |
| 0032 | 保存遠端 CDP 生產接線與安全測試檢查點 | series 中 |
| 0033 | 統一遠端 CDP 來源傳播、目標授權與敏感協定攔截 | series 中 |
| 0034 | 跨 hash 導覽保持初始空白文件所有權語意 | series 中 |
| 0035 | 修正 Aegis WebUI TypeScript lint | series 中 |
| 0036 | 修正 CDP 瀏覽器測試通知 matcher 類型 | series 中 |
| 0037 | 穩定 Aegis 瀏覽器單元測試建置與臨界值斷言 | series 中 |
| 0038 | 遠端建立目標時保留並單次授權初始文件 | series 中 |
| 0039 | 擷取 Ollama 最終 HTTP 請求本文，並驗證原始 PII 不外送 | series 中 |
| 0040 | Profile 銷毀前釋放 Aegis 元件、回呼與原始指標 | series 中 |
| 0041 | 在生產路徑停用 Google AIM eligibility 伺服器請求，同時為測試 factory 保留正向門 | series 中 |
| 0042 | 一般未註冊 Profile 不建立 policy FM/GCM listener，企業註冊後單次啟動 | series 中 |
| 0043 | 將 Aegis 阻擋、CNAME、Referer 與參數事件切回 Remote 所屬序列，並保護結束生命週期 | series 中 |
| 0044 | 按網域索引 path rule、縮短清單替換臨界區，並移除 Canvas 擾動的整圖雙重複製 | series 中 |
| 0045 | 增加結構化頁面保護事件、網站彙總、隱私裁剪與暫時網站暫停 | series 中 |
| 0046 | 增加瀏覽器原生盾牌入口、目前網站氣泡與一次性感知引導 | series 中 |
| 0047 | 增加保護概覽、摘要前確認、網路釣魚線索優先解釋與事件驅動狀態 | series 中 |
| 0048 | 將摘要來源限制在設定頁同一視窗，並拒絕跨視窗/Profile 分頁 | series 中 |
| 0049 | 增加有界網路釣魚頁面收集、品牌仿冒/路徑/短連結訊號與本機多來源 SHA-256 威脅索引 | series 中 |
| 0050 | 整合多連線加速下載與 BT 下載 | series 中 |
| 0051 | 增加原生下載設定及安全預設值 | series 中 |
| 0052 | 強化 Canvas、OffscreenCanvas、Audio、WebGL 與 WebGPU 反指紋 | series 中 |
| 0053 | 增加僅觀察、不阻擋的 MinerGuard | series 中 |
| 0054 | 增加預設關閉的 V8 bytecode shadow 觀察能力 | series 中 |
| 0055 | 支援可編輯位址的 OpenAI、Claude（Anthropic）與 Gemini 相容 API、模型清單及按位址隔離憑證 | series 中 |
| 0056 | 在目前網站保護氣泡中原地完成 AI 摘要確認與結果顯示，並以精確文件工作階段完善 API 請求生命週期 | series 中 |
| 0057 | 固定 Agent 使用的 V8 bytecode shadow 觀察提交 | series 中 |
| 0058 | 增加任務合約、狀態機、策略代理、模型協定、任務儲存與固定工具登錄表 | series 中 |
| 0059 | 將 Aegis 精確範圍、文件綁定與任務生命週期接入 Actor 執行層 | series 中 |
| 0060 | 增加原生側欄、選單、快速鍵、設定入口和桌面 Browser/UI 測試 | series 中 |
| 0061 | 修正固定區間安全稽核發現，並完成資源封裝、真實快速鍵和桌面整合強化 | series 中 |
| 0062 | 預設顯示 Browser Agent 入口並補充迴歸測試 | series 中 |
| 0063 | 為既有 Profile 遷移 Agent 工具列入口 | series 中 |
| 0064 | 明確側欄就緒訊號並修正入口狀態 | series 中 |
| 0065 | 自動開啟任務頁面並支援空白分頁任務 | series 中 |
| 0066 | GCSA 設定移除上游 AI/Google 入口、恢復搜尋引擎管理，並重做關於頁與更新狀態 | series 中 |
| 0067 | 接入 GCSA Logo 與跨平台 App 圖示，同時保留 Chromium 內部身分和使用者資料目錄 | series 中 |

在乾淨、固定版本的 checkout 上執行 `pnpm --filter @gcsa-aegis/browser apply-patches` 進行套用。任何 series 變化都必須重新完成離線重放、冷建置、增量建置和受影響測試。
