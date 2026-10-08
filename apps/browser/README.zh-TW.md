[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# GCSA-aegis Browser

[![C++ 單元測試](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml/badge.svg?branch=main)](https://github.com/gcsagroup/aegis-browser/actions/workflows/cpp-unit-tests.yml)

GCSA-aegis Browser 將隱私與安全能力直接整合到 Chromium 瀏覽器及其引擎。

策略邏輯以 `packages/core` 為來源，透過產生的規則快照、內嵌 policy worker、Chromium browser service，以及 Blink/V8 接入點落地。

> **2026-10-09 · Chromium 155 与 Quinn 改动整合：** 本次源码更新统一纳入原生鼠标手势、Quinn 的 W2 双节点租约/双 relay 与 SM-00 离线预检、Agent 修复及 iOS 下载恢复修复。Mac 候选为 Ver 2.2 (144)，桌面基线 `155.0.8059.40`；整合范围、验收和保留边界见[整合记录](../../docs/audit/main-quinn-integration-2026-10-09.zh-CN.md)，合入路径为 [#32](https://github.com/gcsagroup/aegis-browser/pull/32)。网络计量仍是本地原型，正式跨平台发行尚未完成。

> **歷史證據（2026-09-22）：** macOS Ver 2.0 (061) 的 539 項原生迴歸等結果，僅屬於[原稽核記錄](../../docs/audit/p1-p2-followup-2026-09-22.zh-CN.md)綁定的候選，不代表目前原始碼已通過驗收。

目前聚焦 macOS，執行、真實網路與散布驗收仍待完成。其他平台按[路線圖](../../docs/roadmap.zh-TW.md)推進。

[2026-09-10 稽核](../../docs/audit/main-consolidation-2026-09-10.md)保留歷史補丁重放和測試結果，不代表目前原始碼已通過驗收。

## Chromium 固定基線

| 檔案 | 含義 |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | 本分支桌面基线 `155.0.8059.40`，尚未正式发布 |
| [CHROMIUM_COMMIT](./CHROMIUM_COMMIT) | 補丁所基於的精確 Chromium commit |

此版本是固定快照，不會自動跟隨更新的 Stable 版本。

## 文件

- [Fork 架構](./docs/fork-architecture.zh-TW.md)
- [Android 建置與驗收狀態](./docs/android.zh-TW.md)
- [Play Store 準備草案](./docs/play-store.zh-TW.md)

- [Overlay 同步規則](./docs/overlay.zh-TW.md)
- [Chromium 目錄配置](./docs/tree-layout.zh-TW.md)
- [補丁維護說明](./patches/README.zh-TW.md)

## 儲存庫配置

```text
apps/browser/
  args/                 GN 設定
  overlay/              預期的整合原始碼
  patches/series        有序 Chromium 補丁清單
  patches/v8/series     有序巢狀 V8 補丁清單
  scripts/              擷取、重放、建置、執行、驗證和封裝工具
  docs/                 公開與開發文件
```

Chromium 原始碼放在本儲存庫之外。典型本機設定為：

```bash
export REPO_ROOT="$HOME/Projects/GCSA-aegis"
export CHROMIUM_ROOT="$HOME/Projects/GCSA-aegis-build/macos"
```

也可把 Chromium 根目錄寫入已被 Git 忽略的 `apps/browser/.chromium-root`。

平台工作區統一放在同級 `GCSA-aegis-build` 中，分別為 `macos`、`android` 和既有共享原始碼的 `shared/chromium`。下列命令描述首次建置環境；既有的 Mac 連結工作樹如果沒有獨立 `.gclient`，不要重新 fetch。共享相依套件更新明確選擇 `shared/chromium`，Android 操作明確選擇 `android`。固定驗收 App 路徑與歷史證據保留，移動原始碼目錄不等於重新建置或發布。

## 本機流程

先完成[工作區設定](../../README.zh-TW.md#開始參與)。以下命令從儲存庫根目錄執行，並使用 mise 工具鏈（需要時加 `mise exec -- <command>` 前綴）。Bootstrap、fetch、sync 和相依套件下載會存取網路。

```bash
# 準備 depot_tools。
pnpm --filter @gcsa-aegis/browser bootstrap

# 擷取固定 Chromium 原始碼，需要數十 GB 空間。
pnpm --filter @gcsa-aegis/browser run fetch

# 依序重放 Chromium 和巢狀 V8 補丁。
pnpm --filter @gcsa-aegis/browser apply-patches

# 準備用於本機 BT 建置的固定 libtorrent 原始碼。
pnpm --filter @gcsa-aegis/browser bootstrap:libtorrent

# 建置並執行 component 開發版。
pnpm --filter @gcsa-aegis/browser build
pnpm run browser:run

# 產生 non-component Release build-tree 輸入。
pnpm --filter @gcsa-aegis/browser build:release
pnpm --filter @gcsa-aegis/browser run:release

# 檢查 checkout、補丁、overlay 和輸出狀態。
pnpm --filter @gcsa-aegis/browser status

# 執行儲存庫和 Browser 指令碼門禁。
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser test:scripts

# 選用：預檢無金鑰本機模型的 Agent 原生工具呼叫協定。
node apps/browser/scripts/verify-agent-local-model.mjs \
  --base-url http://127.0.0.1:8000/v1 --model MODEL --rounds 2
```

本機模型預檢不會保存完整提示詞或原始回應。它會重複檢查模型探索、目標路由、計畫和執行
呼叫，但不能取代在真實瀏覽器裡的端到端執行。

Windows 介面驗收使用共享的 [驗收腳本](./scripts/windows-agent-ui-acceptance.ps1)，不要繼續維護伺服器上的獨立副本。
執行前先執行 [腳本自測](./scripts/windows-agent-ui-acceptance_test.ps1)，傳入 Windows Node 的 `-NodePath` 和全新的 `-EvidenceDir`；
此自測只驗證啟動參數與視窗輔助程式碼編譯，不算介面通過。實際驗收須在已解鎖桌面執行，不能自動批准其他程式的防火牆彈窗。

常用輸出目錄：

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`：component 開發輸出。
- `$CHROMIUM_ROOT/src/out/AegisRelease`：non-component Release build-tree 輸入。
- `apps/browser/dist`：僅在身分和發布門禁通過後產生的封裝輸出。

建置成功不會自動把產物升級為 RC 或發行版。

## 補丁與 Overlay 模型

`overlay/` 保存預期的整合原始碼。變更須匯出到有序的 [Chromium](./patches/series) 和 [V8](./patches/v8/series) 補丁清單，再在固定基線上重放。目前清單以這兩份檔案為準；歷史數量與原始碼樹雜湊見[稽核記錄](../../docs/audit/README.zh-TW.md)。

列入補丁清單不代表重放、建置或執行驗證通過。

## 產品邊界

目前桌面原始碼包括：

- tracker、連結、Cookie、bounce 和釣魚防護；
- 針對部分 Canvas、Audio、WebGL、WebGPU 表面的 Blink 指紋擾動；
- 原生 HTTP(S)、Metalink、Torrent 和 Magnet 下載；
- 本機啟發式摘要，以及使用者設定的 OpenAI、Claude（Anthropic）或 Gemini 相容 API；
- Browser Agent v2：包含模型優先目標路由、可見計畫、瀏覽器掌控的執行/觀察/驗證循環、常用任務按鈕、定時自動化、有範圍約束的書籤/URL/頁面/下載工具、精確核准，以及最終購買前的強制使用者接管；
- 僅觀察的 MinerGuard 訊號；以及
- 預設關閉、需明確啟用的 V8 bytecode-shadow 研究路徑。

必須保留以下邊界：

- MinerGuard 只觀察和回報，不會停止指令碼、Worker 或網路連線。
- 指紋擾動只降低部分穩定表面，不能讓瀏覽器「不可識別」。
- 遠端摘要需使用者確認，並先在 browser 側去識別化。允許 HTTPS；明文 HTTP 僅允許數值 loopback 位址。
- API Key 可選，透過作業系統加密保存在目前瀏覽器設定中，不回顯明文。
- v2 原始碼已實作 Android 頁面擷取和目前頁面綁定；是否執行合格取決於目前 APK 的實機驗收。

下載功能位於 Chromium 原生 `chrome://downloads` 和 `chrome://settings/downloads`。影片擷取、媒體轉換、FFmpeg 和預裝下載擴充功能不屬於產品範圍。

## 發布邊界

桌面發布前，同一候選必須完成：

1. 從固定基線乾淨重放；
2. 清單綁定根儲存庫 commit、Chromium commit、兩套補丁序列、GN 參數和產物雜湊；
3. 受影響的原生、指令碼和執行測試通過；
4. 產品身分、簽署、公證與封裝；
5. 代表系統上的全新安裝和升級驗收；以及
6. 明確的發布決定。

## Android

Android 與桌面共用固定 Chromium 基線，並從乾淨的 x86-64 Linux checkout 建置。只有完成 APK 精確身分和實機執行記錄後才可接受該建置；macOS 和 Windows 不能作為 Chromium Android 建置主機。

請參閱 [Android 建置與驗收狀態](./docs/android.zh-TW.md) 和 [Play Store 準備草案](./docs/play-store.zh-TW.md)。以下是建置入口，本身不構成驗收證據：

```bash
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## 網路邊界

本機檢查、補丁重放和多數儲存庫測試不需要 GitHub。Bootstrap、fetch、sync、EasyList 更新和缺少的 Chromium 相依套件可能存取外部服務；執行中的 Chromium 也可能產生與 Git 操作無關的網路流量。

使用網路、簽署、封裝或發布憑證前，必須再次確認精確命令和候選身分。

### 瀏覽器自身更新

「關於 GCSA Aegis」檢查 GitHub 正式版本，自動下載符合平台的安裝套件並校驗，安裝需手動完成。見[更新流程](../../docs/github-browser-updates.zh-CN.md)及[Ver 1.1 (018) 本機驗收](../../docs/ui-copy-acceptance.zh-CN.md)。
