[English](./README.md) | [简体中文](./README.zh-CN.md) | [**繁體中文**](./README.zh-TW.md)

# GCSA-aegis Browser

GCSA-aegis Browser 是把隱私與安全能力直接整合到瀏覽器層和引擎層的 Chromium fork。它不是 Electron 外殼，也不把擴充功能當成產品本體。

策略邏輯以 `packages/core` 為來源，透過產生的規則快照、內嵌 policy worker、Chromium browser service，以及 Blink/V8 接入點落地。

## 目前狀態

- 目前整合原始碼列出 **67 個頂層 Chromium 補丁**，另有 **2 個巢狀 V8 補丁**。
- 先前的 57 補丁診斷清單和 65 補丁 Agent 驗收保留為歷史快照，均不綁定目前 67 補丁 HEAD，也不能為它授予資格。
- 仍需重新完成目前整合原始碼的精確重放、身分綁定建置、受影響執行驗收和發布門檻。目前沒有正式產品簽署、公證、封裝、安裝驗收或已發布的桌面發行版。
- Android **尚未從目前原始碼建置**，目前沒有可對應到原始碼的 APK 或 AAB。

因此，儲存庫目前沒有可發布的桌面或 Android 產物。

## Chromium 固定基線

| 檔案 | 含義 |
|---|---|
| [CHROMIUM_VERSION](./CHROMIUM_VERSION) | 固定的 Mac Stable 版本，目前為 `151.0.7922.77` |
| [CHROMIUM_COMMIT](./CHROMIUM_COMMIT) | 補丁所基於的精確 Chromium commit |

此版本是固定快照，不會自動跟隨更新的 Stable 版本。

## 文件

- [Fork 架構](./docs/fork-architecture.zh-TW.md)
- [Android 建置與驗收狀態](./docs/android.zh-TW.md)
- [Play Store 準備草案](./docs/play-store.zh-TW.md)

- [Overlay 同步規則](./docs/overlay.zh-TW.md)
- [Chromium 目錄配置](./docs/tree-layout.zh-TW.md)
- [補丁維護說明](./patches/README.zh-TW.md)

實際操作以 `patches/series`、`patches/v8/series` 和 `scripts/` 下的腳本為準。歷史狀態記錄不能取代目前重放、建置或執行驗證。

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
export CHROMIUM_ROOT="$HOME/Projects/GCSA-aegis-chromium"
```

也可把 Chromium 根目錄寫入已被 Git 忽略的 `apps/browser/.chromium-root`。

## 本機流程

以下命令從儲存庫根目錄執行。Bootstrap、fetch、sync 和相依套件下載會存取網路。

```bash
# 準備 depot_tools。
pnpm --filter @gcsa-aegis/browser bootstrap

# 擷取固定 Chromium 原始碼，需要數十 GB 空間。
pnpm --filter @gcsa-aegis/browser fetch

# 依序重放 Chromium 和巢狀 V8 補丁。
pnpm --filter @gcsa-aegis/browser apply-patches

# 準備用於本機 BT 建置的固定 libtorrent 原始碼。
pnpm --filter @gcsa-aegis/browser bootstrap:libtorrent

# 建置並執行 component 開發版。
pnpm --filter @gcsa-aegis/browser build
pnpm --filter @gcsa-aegis/browser run

# 產生 non-component Release build-tree 輸入。
pnpm --filter @gcsa-aegis/browser build:release
pnpm --filter @gcsa-aegis/browser run:release

# 檢查 checkout、補丁、overlay 和輸出狀態。
pnpm --filter @gcsa-aegis/browser status

# 執行儲存庫和 Browser 指令碼門禁。
pnpm run quality:fast
pnpm --filter @gcsa-aegis/browser test:scripts
```

常用輸出目錄：

- `$CHROMIUM_ROOT/src/out/AegisLocalDev`：component 開發輸出。
- `$CHROMIUM_ROOT/src/out/AegisRelease`：non-component Release build-tree 輸入。
- `apps/browser/dist`：僅在身分和發布門禁通過後產生的封裝輸出。

建置成功不會自動把產物升級為 RC 或發行版。

## 補丁與 Overlay 模型

`overlay/` 保存預期的 Aegis 整合原始碼。它既不是獨立產品，也不是已套用原始碼的唯一事實來源。變更必須匯出到有序補丁序列，並在精確固定的 Chromium 基線上重新重放。

目前原始碼口徑：

- 列入 Chromium 序列的 67 個頂層補丁。
- 2 個套用在巢狀 V8 checkout 中的補丁。
- 歷史身分只涵蓋先前的 57 補丁和 65 補丁快照，均不涵蓋 0066–0067。
- 目前 67 補丁 HEAD 必須重新完成精確重放和建置身分綁定，才能形成目前資格結論。

「已列入 series」只表示補丁檔案存在，不證明重放、可重現建置、平台驗收、簽署、封裝或發布已經完成。

## 產品邊界

目前桌面原始碼包括：

- tracker、連結、Cookie、bounce 和釣魚防護；
- 針對部分 Canvas、Audio、WebGL、WebGPU 表面的 Blink 指紋擾動；
- 原生 HTTP(S)、Metalink、Torrent 和 Magnet 下載；
- 本機啟發式摘要，以及使用者設定的 OpenAI、Claude（Anthropic）或 Gemini 相容 API；
- 瀏覽器掌控的 Agent：包含 Observe/Ask/Act 模式、有範圍約束的書籤/URL/頁面/下載/工作流程/監控工具、精確審批、稽核歷史、取消，以及最終購買前的強制使用者接管；
- 僅觀察的 MinerGuard 訊號；以及
- 預設關閉、需明確啟用的 V8 bytecode-shadow 研究路徑。

必須保留以下邊界：

- MinerGuard 只觀察和回報，不會停止指令碼、Worker 或網路連線。
- 指紋擾動只降低部分穩定表面，不能讓瀏覽器「不可識別」。
- 遠端摘要需使用者確認，並先在 browser 側去識別化。允許 HTTPS；明文 HTTP 僅允許數值 loopback 位址。
- API Key 可選，透過作業系統加密保存在目前瀏覽器設定中，不回顯明文。
- Android handler 目前無法取得一般網頁 tab，因此 Android 頁面摘要不可用。

下載功能位於 Chromium 原生 `chrome://downloads` 和 `chrome://settings/downloads`。影片擷取、媒體轉換、FFmpeg 和預裝下載擴充功能不屬於產品範圍。

## 發布邊界

桌面發布前，同一候選必須完成：

1. 從固定基線乾淨重放；
2. 清單綁定根儲存庫 commit、Chromium commit、兩套補丁序列、GN 參數和產物雜湊；
3. 受影響的原生、指令碼和執行測試通過；
4. 產品身分、簽署、公證與封裝；
5. 代表系統上的全新安裝和升級驗收；以及
6. 明確的發布決定。

目前本機 diagnostic build-tree 已涵蓋 0055/0056/0057，但不符合上述條件。完整補丁涵蓋不會使其成為 RC 或發行版。
本機 RC 已符合其中的乾淨重播、身分和受影響測試要求，但尚未符合產品身分、受信任簽署、公證、已安裝散佈套件或發行授權門禁。

## Android

Android 與桌面共享固定 Chromium 基線，但目前原始碼尚未產出合格 Android 建置。Android client 需要受支援的 x86-64 Linux 環境；macOS 和 Windows 不能作為 Chromium Android 建置主機。

請參閱 [Android 建置與驗收狀態](./docs/android.zh-TW.md) 和 [Play Store 準備草案](./docs/play-store.zh-TW.md)。以下只是未來建置入口，不是 APK 已存在的證據：

```bash
pnpm --filter @gcsa-aegis/browser build:android
pnpm --filter @gcsa-aegis/browser package:android
```

## 網路邊界

本機檢查、補丁重放和多數儲存庫測試不需要 GitHub。Bootstrap、fetch、sync、EasyList 更新和缺少的 Chromium 相依套件可能存取外部服務；執行中的 Chromium 也可能產生與 Git 操作無關的網路流量。

使用網路、簽署、封裝或發布憑證前，必須再次確認精確命令和候選身分。
