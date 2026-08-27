# 架構

[English](architecture.md) | [简体中文](architecture.zh-CN.md) | **繁體中文**

## 產品形態

GCSA-aegis 是整合式 Chromium fork，不是 Electron 套殼，也不把核心能力作為獨立擴充功能交付。

```text
packages/core
  策略、偵測器、生成資源、研究性質評測器
        │
        ▼
Chromium 補丁堆疊與 overlay
        │
        ▼
AegisService / throttles / 儲存鉤子 / WebUI / 原生介面
        │
        ├── 瀏覽器本機決策與本機啟發式摘要
        └── 可選的使用者設定相容模型 API
```

`packages/core` 是可測試 TypeScript 邏輯和生成資源的構建期來源。`apps/browser` 負責 Chromium 釘選、補丁堆疊、overlay、構建腳本、驗證工具和平台封裝邊界。

## 執行路徑

1. **網路與導覽：**Chromium throttle 套用追蹤器規則、部分第一方收集路徑規則、連結清理、釣魚檢查和本機威脅情報查詢。
2. **儲存：**Cookie 分類和 bounce tracking 清理在瀏覽器掌控的生命週期和 Profile 邊界內執行。
3. **指紋表面：**Blink 及相關鉤子降低部分 Canvas、OffscreenCanvas、Audio、WebGL 和 WebGPU 表面的穩定跨站訊號。這是緩解措施，不等於匿名。
4. **下載：**使用者介面仍使用 Chromium 下載頁。整合層增加有界 HTTP(S) 平行、Metalink 和 BT/Magnet 路徑，並設定明確的資源與安全限制。
5. **頁面摘要：**renderer 提供有界候選快照，browser 再次驗證和脫敏。敏感頁面強制回退本機啟發式。使用者可設定 OpenAI、Claude（Anthropic）或 Gemini 相容端點；非 loopback 使用必須明確目標並確認。
6. **本機自動化：**所選桌面 CDP 路徑增加 loopback、來源和精確文件授權控制。獲授權的本機 agent 仍可讀取頁面 DOM，因此這不是通用資料防洩漏邊界。

## 研究路徑

僅 Node AST 分析、有界行為/來源函式、本機聯邦模擬和 V8 Ignition bytecode shadow 屬於研究工具或僅觀察儀表。它們不是已部署模型、完整瀏覽器資訊流系統、腳本阻斷器，也不能證明通用惡意 JavaScript 防護。

## 目前原始碼與產物身分

- 現場原始碼整合包含 56 個頂層 Chromium 補丁和 2 個巢狀 V8 補丁；外部 checkout 與 overlay、補丁譜系一致。
- 最新帶身分清單的本機 build-tree 只涵蓋 54 個頂層補丁及這 2 個 V8 補丁；由於根儲存庫當時為 dirty，資格為 `diagnostic-only`。
- 0055、0056 已同步進原始碼，但沒有被該產物身分涵蓋。不能把它們的存在與舊執行計數合併後宣稱目前版本發行合格。

## 隱私與信任邊界

- API 憑證可選，使用作業系統加密保存，按 API 格式與規範化端點隔離，介面不回顯。
- 遠端摘要文字有長度限制並經過脫敏，但完整 Chromium 出站、遙測、更新、崩潰報告和錯誤路徑稽核仍未完成。
- 本機 build-tree 簽名或結構驗證不等於產品身分、Developer ID 簽名、公證、stapling 或安裝 App 驗收。
- Android 仍阻塞於合格的 x86-64 Linux 構建、目前原始碼安裝套件和真實裝置驗收。

## 發行狀態

該架構已進入原始碼並完成部分本機驗證，但產品整體仍為**發行 No-Go**。剩餘門禁見[路線圖](roadmap.zh-TW.md)，開發操作見 [Browser 指南](../apps/browser/README.zh-TW.md)。
