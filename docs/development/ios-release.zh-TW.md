# iOS 封裝與 TestFlight

倉庫提供的 `scripts/release/ios-runner.py` 簽名 runner 啟動入口已停用。即使已驗證 Admin，也會在讀取 payload、探測簽名金鑰、註冊或啟動 listener 前拒絕；沒有略過開關。佇列快照、唯一標籤與執行後的身分檢查不能保證簽名主機隔離。重新啟用必須另行實作並審查執行前授權或服務端 workflow 隔離；不得用手動註冊的共用或同標籤 runner 規避。本次只停用該原始碼入口，未變更任何現有主機、鑰匙圈或註冊；無憑據驗證、交付契約與唯讀查詢仍可用。

Alpha 固定僅供內部測試，原生匯出開啟 `testFlightInternalTestingOnly`，上傳後必須讀回 `INTERNAL_ONLY`。Beta 可供內外測試，禁止正式送審。Release 可用於各目的地，每個階段均明確選擇。上傳不會自動送審或公開發佈。

## cloud 預設與明確 manual 回退

CLI、Fastlane、Simple/Full Actions 和 candidate tag 建立的新 iOS 套件預設使用 `cloud`。雲端簽章在獲准的 GitHub-hosted macOS runner 使用 Xcode 26.6 和具 cloud-managed Distribution 權限的 ASC key，執行新的 archive→export，不匯入分發 P12。

需要回退時明確選擇：CLI 使用 `--signing-mode manual`，Fastlane 使用 `signing_mode:manual`，Actions 將 **Signing mode** 選為 **manual**。本機打包使用此明確回退。cloud 失敗會停止當次嘗試；核對回執與遠端狀態後，以未占用 build 與新 run ID 發起 manual 打包，不自動重傳。

簽章選擇僅用於新套件。Status/Wait 與既有套件的後續階段依原有身分與簽章回執運作；舊 manual 回執仍驗證憑證指紋與 profile。manual tag 使用[雲端簽章指南](ios-cloud-signing-poc.md#current-signing-default-and-manual-fallback)的來源綁定註解。

使用乾淨且已提交的原始碼、Ruby 3.3.6、鎖定的 Fastlane、Node 22.23.1、Python 3.11+ 與 Xcode。執行 `bundle install`，以 `./release ios plan` 讀取來源 SHA/tree 與原生輸入摘要。所有變更均需明確指定 `--profile`。

```sh
./release ios package --profile alpha --signing-mode manual --version 1.0.0 --build 6 --run-id ios-alpha-6
./release ios upload --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256
./release ios wait --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios status --profile alpha --version 1.0.0 --build 6 --destination testflight
```

範例編號僅供示意，實際先查 ASC，再選未使用的 build。`compliance`、`metadata`、`distribute` 必須保留原始 manifest 摘要、run ID 與完成的上傳記錄，重用同一產物。合規 JSON 需有明確布林答案、來源 SHA、原生輸入摘要及授權說明；中繼資料 JSON 僅允許語言別的 `description`／`whatsNew`，保留回饋聯絡資訊及其他語言。本地簽名不匯出私鑰、不改共用鑰匙圈 ACL，憑證資料不得進入 Git 或公開證據。

預設 cloud 使用 `AEGIS_APPLE_TEAM_ID` 和受保護的 ASC key：`AEGIS_ASC_KEY_ID`、`AEGIS_ASC_ISSUER_ID`、`AEGIS_ASC_KEY_BASE64`。僅明確選擇 manual 時匯入分發 P12 與 profiles。

明確選擇 `manual` 時，Actions 打包使用 GitHub 託管的臨時 macOS。在 `aegis-ios-signing` 保留 team、憑證指紋和三份 profile 名稱變數，並設定加密 secrets：`AEGIS_IOS_DISTRIBUTION_P12_BASE64`、`AEGIS_IOS_DISTRIBUTION_P12_PASSWORD`、`AEGIS_IOS_APP_PROFILE_BASE64`、`AEGIS_IOS_SAFARI_PROFILE_BASE64`、`AEGIS_IOS_SHARE_PROFILE_BASE64`。二進位材料使用單行 Base64，打包後清理臨時鑰匙圈與 profiles；簽名材料不得進入日誌、Git、artifact 或上傳憑據環境。

Actions 的封裝與上傳統一使用 **iOS Delivery**；獨立保留 **iOS Release Validation** 自動無憑證驗證與 **iOS Coverage** 模擬器覆蓋率。手動執行三個 iOS 工作流程均要求實際倉庫 Admin 權限（包含組織所有者授予的 Admin），原發起者和重跑者都必須通過驗證。Maintain/Write/Read 和權限未知均在受保護作業排隊前拒絕；GitHub 原生介面仍可能向 Write 顯示執行按鈕。本地流程驗證真實 token 使用者，runner 在簽章探測前驗證真實 CLI Admin。fork 交付入口維持停用。

表單採用英文。本地 CLI 維持原有介面。欄位、選項與執行步驟見[中英文操作指南](ios-delivery-actions.md)。

交付憑據保留包型、版本、build、原封裝 run、最新狀態 run、精確 attempt 與獨立固定的 manifest 摘要。憑據不提供權限，也不取代來源、成功生產者、完整性或防重複檢查。每次等待整次執行成功，再用最新 Summary 憑據；結果未知先讀回對帳，不可重傳。推送 `candidate/ios/版本-profile.build` 仍只封裝至私有 Draft，不自動上傳 TF，正常 Draft 優先使用 Tag 觸發。先驗證來源與產物，再載入 ASC 憑證；外測 Beta Review 與正式送審仍須獨立授權。

上游合併前通過必需 CI；合併後追蹤新 main CI，重新測試託管 Fastlane、Actions、Tag→私有 Draft 三種方法及 Alpha/Beta/Release 三種封裝，下載驗證每份產物並讀回 TF 結果。外測 Beta Review 與正式送審不在自動驗收中執行。上游通過後僅停用 fork 的 iOS 入口，保留歷史與回復快照，不影響其他平台。完整設定、JSON 範例及復原步驟見 [iOS operations](ios-release.md)。

目前已驗證的 Apple 系統加密實作，在實際 Info.plist 中宣告布林值 `ITSAppUsesNonExemptEncryption=false`；匯出驗證會比對簽章 App 的同一宣告。加密實作或依賴變更後必須重新評估，歷史 IPA 維持原樣。驗收先讀回 TF 自動識別的 `usesNonExemptEncryption=false`，再考慮明確的合規更新。

候选 Tag 还需独立于工作流代码的仓库保护：[限定规则](../../.github/ios-candidate-admin-ruleset.json) 仅覆盖 `refs/tags/candidate/ios/**/*`，创建、更新、删除只允许仓库 Admin。先以 disabled 准备，通过 GraphQL 确认 role ID5 的 `repositoryRoleName=admin`，再启用并用真实 Admin token 执行 `node scripts/ci/ios-operator.mjs --verify-candidate-tag-policy`。不扩大绕过角色或 Tag 范围。交付权限边界以通过合并流程的 main 代码可信为前提，共享 main 审核治理不在此次 iOS 改动中。

## 本地自動準備簽名

在鎖定的 Ruby/Bundler 執行環境中執行 `python3 scripts/release/local-ios-signing.py --team "$AEGIS_APPLE_TEAM_ID" --certificate-sha1 "$AEGIS_IOS_CERT_SHA1" --unlock`。腳本從下載目錄讀取現有私密 ASC 設定和金鑰，只解析賦值、不執行 shell；以唯讀 Connect API 下載及校驗三份現有 App Store profile，安裝缺少的 profile。匯出名稱固定為 `Aegis-AppStore-App.mobileprovision`、`Aegis-AppStore-Safari.mobileprovision`、`Aegis-AppStore-Share.mobileprovision`，不加日期；三個產品渠道共用，遠端 profile 與 Bundle ID 名稱也沿用不含日期的命名。

`--unlock` 從憑證指紋相符的材料目錄讀取私密 `EXISTING-KEYCHAIN-PASSWORD.txt`，透過 macOS Security API 解鎖現有非登入簽名鑰匙圈，密碼不進入命令列、日誌、回執或 AI 介面操作。不更動登入／系統鑰匙圈、共用 ACL、分區或搜尋清單；既有私鑰授權仍由系統執行。缺失、衝突、符號連結、非私密輸入及驗證失敗均停止，不重試密碼或退回界面自動填寫。驗證回執位於 `.artifacts/ios-signing/app-store/signing-receipt.json`。

## Actions 精簡版與完整版

`iOS Delivery · Simple` 包含操作、版本、build、打包產物和簽章模式；新套件預設 cloud。操作為僅打包、打包並上傳 TF、查詢狀態、等待處理；查詢/等待只需版本與 build，不需憑據或舊 artifact，且只發送 GET。等待最多 30 分鐘，不會重傳。逾時仍為失敗，Summary 與狀態 artifact 保留最後一次 Apple 狀態，可用 Status 或 Wait 再查同一構建。

`iOS Delivery · Full` 呼叫同一 reusable workflow；舊包補傳、說明、合規及分發仍需最新成功執行的完整交付憑據。Admin、來源、producer/attempt、原始摘要與防重複校驗保留。詳見[完整操作指引](ios-release.zh-CN.md)。
