// Copyright 2015 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "chrome/browser/ui/webui/settings/downloads_handler.h"

#include <optional>

#include "base/functional/bind.h"
#include "base/metrics/user_metrics.h"
#include "base/values.h"
#include "chrome/browser/aegis/aegis_download_prefs.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/select_file_policy/chrome_select_file_policy.h"
#include "chrome/common/pref_names.h"
#include "chrome/grit/generated_resources.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/shell_dialogs/selected_file_info.h"

#if BUILDFLAG(IS_CHROMEOS)
#include "chrome/browser/ash/file_manager/path_util.h"
#endif

using base::UserMetricsAction;

namespace {

base::DictValue DownloadSettingsToValue(
    const aegis::DownloadSettings& settings) {
  base::DictValue value;
  value.Set("parallelMode", settings.parallel_mode);
  value.Set("reduceOnMetered", settings.reduce_on_metered);
  value.Set("reduceOnBattery", settings.reduce_on_battery);
  value.Set("torrentDhtEnabled", settings.torrent_dht_enabled);
  value.Set("torrentPexEnabled", settings.torrent_pex_enabled);
  value.Set("torrentDownloadLimitKib",
            settings.torrent_download_limit_kib);
  value.Set("torrentUploadLimitKib", settings.torrent_upload_limit_kib);
  return value;
}

std::optional<aegis::DownloadSettings> DownloadSettingsFromValue(
    const base::Value& value) {
  if (!value.is_dict() || value.GetDict().size() != 7) {
    return std::nullopt;
  }
  const base::DictValue& dict = value.GetDict();
  const std::optional<int> parallel_mode = dict.FindInt("parallelMode");
  const std::optional<bool> reduce_on_metered =
      dict.FindBool("reduceOnMetered");
  const std::optional<bool> reduce_on_battery =
      dict.FindBool("reduceOnBattery");
  const std::optional<bool> torrent_dht_enabled =
      dict.FindBool("torrentDhtEnabled");
  const std::optional<bool> torrent_pex_enabled =
      dict.FindBool("torrentPexEnabled");
  const std::optional<int> torrent_download_limit =
      dict.FindInt("torrentDownloadLimitKib");
  const std::optional<int> torrent_upload_limit =
      dict.FindInt("torrentUploadLimitKib");
  if (!parallel_mode || !reduce_on_metered || !reduce_on_battery ||
      !torrent_dht_enabled || !torrent_pex_enabled ||
      !torrent_download_limit || !torrent_upload_limit ||
      !aegis::IsValidDownloadParallelMode(*parallel_mode) ||
      !aegis::IsValidTorrentRateLimit(*torrent_download_limit) ||
      !aegis::IsValidTorrentRateLimit(*torrent_upload_limit)) {
    return std::nullopt;
  }
  return aegis::DownloadSettings{
      .parallel_mode = *parallel_mode,
      .reduce_on_metered = *reduce_on_metered,
      .reduce_on_battery = *reduce_on_battery,
      .torrent_dht_enabled = *torrent_dht_enabled,
      .torrent_pex_enabled = *torrent_pex_enabled,
      .torrent_download_limit_kib = *torrent_download_limit,
      .torrent_upload_limit_kib = *torrent_upload_limit,
  };
}

PrefService* GetLocalState() {
  CHECK(g_browser_process);
  CHECK(g_browser_process->local_state());
  return g_browser_process->local_state();
}

}  // namespace

namespace settings {

DownloadsHandler::DownloadsHandler(Profile* profile) : profile_(profile) {}

DownloadsHandler::~DownloadsHandler() {
  // There may be pending file dialogs, we need to tell them that we've gone
  // away so they don't try and call back to us.
  if (select_folder_dialog_) {
    select_folder_dialog_->ListenerDestroyed();
  }
}

void DownloadsHandler::RegisterMessages() {
  web_ui()->RegisterMessageCallback(
      "initializeDownloads",
      base::BindRepeating(&DownloadsHandler::HandleInitialize,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "resetAutoOpenFileTypes",
      base::BindRepeating(&DownloadsHandler::HandleResetAutoOpenFileTypes,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "selectDownloadLocation",
      base::BindRepeating(&DownloadsHandler::HandleSelectDownloadLocation,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "getAegisDownloadSettings",
      base::BindRepeating(&DownloadsHandler::HandleGetAegisDownloadSettings,
                          base::Unretained(this)));
  web_ui()->RegisterMessageCallback(
      "setAegisDownloadSettings",
      base::BindRepeating(&DownloadsHandler::HandleSetAegisDownloadSettings,
                          base::Unretained(this)));
#if BUILDFLAG(IS_CHROMEOS)
  web_ui()->RegisterMessageCallback(
      "getDownloadLocationText",
      base::BindRepeating(&DownloadsHandler::HandleGetDownloadLocationText,
                          base::Unretained(this)));
#endif
}

void DownloadsHandler::OnJavascriptAllowed() {
  pref_registrar_.Init(profile_->GetPrefs());
  pref_registrar_.Add(
      prefs::kDownloadExtensionsToOpen,
      base::BindRepeating(&DownloadsHandler::SendAutoOpenDownloadsToJavascript,
                          base::Unretained(this)));
}

void DownloadsHandler::OnJavascriptDisallowed() {
  pref_registrar_.RemoveAll();
}

void DownloadsHandler::HandleInitialize(const base::ListValue& args) {
  AllowJavascript();
  SendAutoOpenDownloadsToJavascript();
}

void DownloadsHandler::SendAutoOpenDownloadsToJavascript() {
  content::DownloadManager* manager = profile_->GetDownloadManager();
  bool auto_open_downloads =
      DownloadPrefs::FromDownloadManager(manager)->IsAutoOpenByUserUsed();
  FireWebUIListener("auto-open-downloads-changed",
                    base::Value(auto_open_downloads));
}

void DownloadsHandler::HandleGetAegisDownloadSettings(
    const base::ListValue& args) {
  AllowJavascript();
  CHECK_EQ(args.size(), 1u);
  ResolveJavascriptCallback(
      args[0], DownloadSettingsToValue(
                   aegis::ReadDownloadSettings(*GetLocalState())));
}

void DownloadsHandler::HandleSetAegisDownloadSettings(
    const base::ListValue& args) {
  AllowJavascript();
  CHECK(args.size() == 2u || args.size() == 3u);
  if (args.size() == 3u && args[2] != DownloadSettingsToValue(
          aegis::ReadDownloadSettings(*GetLocalState()))) {
    RejectJavascriptCallback(args[0], base::Value("settings_changed"));
    return;
  }
  std::optional<aegis::DownloadSettings> settings =
      DownloadSettingsFromValue(args[1]);
  if (!settings) {
    RejectJavascriptCallback(args[0],
                             base::Value("invalid Aegis download settings"));
    return;
  }
  aegis::WriteDownloadSettings(GetLocalState(), *settings);
  ResolveJavascriptCallback(args[0], DownloadSettingsToValue(*settings));
}

void DownloadsHandler::HandleResetAutoOpenFileTypes(
    const base::ListValue& args) {
  base::RecordAction(UserMetricsAction("Options_ResetAutoOpenFiles"));
  content::DownloadManager* manager = profile_->GetDownloadManager();
  DownloadPrefs::FromDownloadManager(manager)->ResetAutoOpenByUser();
}

void DownloadsHandler::HandleSelectDownloadLocation(
    const base::ListValue& args) {
  // Early return if the select folder dialog is already active.
  if (select_folder_dialog_) {
    return;
  }

  PrefService* pref_service = profile_->GetPrefs();
  select_folder_dialog_ = ui::SelectFileDialog::Create(
      this,
      std::make_unique<ChromeSelectFilePolicy>(web_ui()->GetWebContents()));
  ui::SelectFileDialog::FileTypeInfo info;
  info.allowed_paths = ui::SelectFileDialog::FileTypeInfo::NATIVE_PATH;
  select_folder_dialog_->SelectFile(
      ui::SelectFileDialog::SELECT_FOLDER,
      l10n_util::GetStringUTF16(IDS_SETTINGS_DOWNLOAD_LOCATION),
      pref_service->GetFilePath(prefs::kDownloadDefaultDirectory), &info, 0,
      base::FilePath::StringType(),
      web_ui()->GetWebContents()->GetTopLevelNativeWindow(), nullptr);
}

void DownloadsHandler::FileSelected(const ui::SelectedFileInfo& file,
                                    int index) {
  select_folder_dialog_ = nullptr;

  base::RecordAction(UserMetricsAction("Options_SetDownloadDirectory"));
  PrefService* pref_service = profile_->GetPrefs();
  pref_service->SetFilePath(prefs::kDownloadDefaultDirectory, file.path());
  pref_service->SetFilePath(prefs::kSaveFileDefaultDirectory, file.path());
}

void DownloadsHandler::FileSelectionCanceled() {
  select_folder_dialog_ = nullptr;
}

#if BUILDFLAG(IS_CHROMEOS)
void DownloadsHandler::HandleGetDownloadLocationText(
    const base::ListValue& args) {
  AllowJavascript();
  CHECK_EQ(2U, args.size());
  const std::string& callback_id = args[0].GetString();
  const std::string& path = args[1].GetString();

  ResolveJavascriptCallback(
      base::Value(callback_id),
      base::Value(
          file_manager::util::GetPathDisplayTextForSettings(profile_, path)));
}
#endif

}  // namespace settings
