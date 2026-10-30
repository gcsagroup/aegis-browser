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

Actions 將無憑證驗證、受保護簽章、私有 Draft 與 TF 分開。候選 Tag 為 `candidate/ios/版本-profile.build`。TF 使用原始 `package_run_id`、最新成功狀態的 `upload_run_id`、明確 attempt 與原始摘要，先驗證來源和產物，再載入 ASC 憑證。結果未知時先讀回對帳，不盲目重試。測試員 `INSTALLED` 狀態不代表此 build 的真機證據。內建磁碟保留至少 8 GiB、外接磁碟至少 15 GiB 真正可用空間。

上游合併前通過必需 CI；合併後追蹤新 main CI，重新測試本地 Fastlane、Actions、Tag→私有 Draft 三種方法及 Alpha/Beta/Release 三種封裝，下載驗證每份產物並讀回 TF 結果。外測 Beta Review 與正式送審不在自動驗收中執行。上游通過後僅停用 fork 的 iOS 入口，保留歷史與回復快照，不影響其他平台。完整設定、JSON 範例及復原步驟見 [iOS operations](ios-release.md)。
