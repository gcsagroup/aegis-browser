# iOS 封裝與 TestFlight

Alpha 固定僅供內部測試，原生匯出開啟 `testFlightInternalTestingOnly`，上傳後必須讀回 `INTERNAL_ONLY`。Beta 可供內外測試，禁止正式送審。Release 可用於各目的地，每個階段均明確選擇。上傳不會自動送審或公開發佈。

使用乾淨且已提交的原始碼、Ruby 3.3.6、鎖定的 Fastlane、Node 22.23.1、Python 3.11+ 與 Xcode。執行 `bundle install`，以 `./release ios plan` 讀取來源 SHA/tree 與原生輸入摘要。所有變更均需明確指定 `--profile`。

```sh
./release ios package --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6
./release ios upload --profile alpha --version 1.0.0 --build 6 --run-id ios-alpha-6 --destination testflight --manifest-sha256 MANIFEST_SHA256
./release ios wait --profile alpha --version 1.0.0 --build 6 --destination testflight
./release ios status --profile alpha --version 1.0.0 --build 6 --destination testflight
```

範例編號僅供示意，實際先查 ASC，再選未使用的 build。`compliance`、`metadata`、`distribute` 必須保留原始 manifest 摘要、run ID 與完成的上傳記錄，重用同一產物。合規 JSON 需有明確布林答案、來源 SHA、原生輸入摘要及授權說明；中繼資料 JSON 僅允許語言別的 `description`／`whatsNew`，保留回饋聯絡資訊及其他語言。不匯出私鑰，不改共用鑰匙圈 ACL，憑證資料不得進入參數、Git 或公開證據。

Actions 的封裝與上傳統一使用 **iOS Delivery**；獨立保留 **iOS Release Validation** 自動無憑證驗證與 **iOS Coverage** 模擬器覆蓋率。手動執行三個 iOS 工作流程均要求實際倉庫 Admin 權限（包含組織所有者授予的 Admin），原發起者和重跑者都必須通過驗證。Maintain/Write/Read 和權限未知均在受保護作業排隊前拒絕；GitHub 原生介面仍可能向 Write 顯示執行按鈕。本地流程驗證真實 token 使用者，runner 在簽章探測前驗證真實 CLI Admin。fork 交付入口維持停用。

在 main 選擇 `operation=package`，預設 Alpha，`destination=auto` 僅保留產物；`github-draft` 必須提供精確 Tag。推送 `candidate/ios/版本-profile.build` 自動解析身分，僅封裝至私有 Draft，不自動上傳 TF。已有實包在同一流程選擇 `upload|wait|status|metadata|compliance|distribute`，提供原始 `package_run_id`、`manifest_sha256`、精確 `source_attempt`；後續階段再指定最新成功狀態的 `upload_run_id`。`distribute` 必須明確選擇內測／外測和現有群組，Alpha 外測在准入階段拒絕。先驗證來源與產物，再載入 ASC 憑證。被拒絕或明確未執行的舊作業不會阻擋 Admin；任何可能已開始的變更仍須先讀回對帳，不可盲目重試。外測 Beta Review 與正式送審均須獨立授權，不在自動驗收中執行。

上游合併前通過必需 CI；合併後追蹤新 main CI，重新測試本地 Fastlane、Actions、Tag→私有 Draft 三種方法及 Alpha/Beta/Release 三種封裝，下載驗證每份產物並讀回 TF 結果。外測 Beta Review 與正式送審不在自動驗收中執行。上游通過後僅停用 fork 的 iOS 入口，保留歷史與回復快照，不影響其他平台。完整設定、JSON 範例及復原步驟見 [iOS operations](ios-release.md)。
