// Copyright 2012 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/path_service.h"
#include "base/strings/escape.h"
#include "base/strings/utf_string_conversions.h"
#include "build/branding_buildflags.h"
#include "build/build_config.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/ui/webui/help/aegis_github_update.h"
#include "chrome/browser/ui/webui/help/version_updater.h"
#include "chrome/browser/upgrade_detector/upgrade_detector.h"
#include "chrome/common/chrome_paths.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"

namespace {
class VersionUpdaterBasic : public VersionUpdater {
 public:
  explicit VersionUpdaterBasic(content::WebContents* web_contents) {
#if !BUILDFLAG(GOOGLE_CHROME_BRANDING) && !BUILDFLAG(CHROME_FOR_TESTING)
    if (web_contents) {
      base::FilePath downloads;
      base::PathService::Get(chrome::DIR_DEFAULT_DOWNLOADS, &downloads);
      update_ = std::make_unique<aegis::GitHubUpdate>(
          web_contents->GetBrowserContext()
              ->GetDefaultStoragePartition()
              ->GetURLLoaderFactoryForBrowserProcess(),
          downloads, aegis::GitHubUpdatePlatform(),
          g_browser_process->GetApplicationLocale());
    }
#endif
  }
  ~VersionUpdaterBasic() override = default;
  base::FilePath GetDownloadedUpdatePath() const override {
    return update_ ? update_->GetDownloadedUpdatePath() : base::FilePath();
  }

  void CheckForUpdate(StatusCallback callback, PromoteCallback) override {
    if (update_) {
      update_->Check(base::BindRepeating(
          [](StatusCallback callback, aegis::GitHubUpdate::State state,
             int progress, const std::string& message) {
            Status status = DISABLED;
            switch (state) {
              case aegis::GitHubUpdate::State::kChecking:
                status = CHECKING;
                break;
              case aegis::GitHubUpdate::State::kVerifying:
              case aegis::GitHubUpdate::State::kDownloading:
                status = UPDATING;
                break;
              case aegis::GitHubUpdate::State::kError:
                status = FAILED;
                break;
              // 下载完毕尚未安装，不能显示“重新启动即可更新”。
              case aegis::GitHubUpdate::State::kUnchecked:
              case aegis::GitHubUpdate::State::kLocalNewer:
              case aegis::GitHubUpdate::State::kReady:
              case aegis::GitHubUpdate::State::kCurrent:
              case aegis::GitHubUpdate::State::kEmpty:
                break;
            }
            callback.Run(status, progress, false, false, std::string(), 0,
                         base::UTF8ToUTF16(base::EscapeForHTML(message)));
          },
          std::move(callback)));
      return;
    }
    const Status status = UpgradeDetector::GetInstance()->is_upgrade_available()
                              ? NEARLY_UPDATED
                              : DISABLED;
    callback.Run(status, 0, false, false, std::string(), 0, std::u16string());
  }
#if BUILDFLAG(IS_MAC)
  void PromoteUpdater() override {}
#endif
 private:
  std::unique_ptr<aegis::GitHubUpdate> update_;
};
}  // namespace

std::unique_ptr<VersionUpdater> VersionUpdater::Create(
    content::WebContents* web_contents) {
  return std::make_unique<VersionUpdaterBasic>(web_contents);
}
