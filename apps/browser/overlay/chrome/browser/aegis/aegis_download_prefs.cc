// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_download_prefs.h"

#include "base/check.h"
#include "components/download/public/common/download_features.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/pref_service.h"

namespace aegis {

void RegisterDownloadLocalStatePrefs(PrefRegistrySimple* registry) {
  registry->RegisterIntegerPref(kDownloadParallelMode,
                                kDownloadParallelModeSmart);
  registry->RegisterBooleanPref(kDownloadReduceOnMetered, true);
  registry->RegisterBooleanPref(kDownloadReduceOnBattery, true);
  registry->RegisterBooleanPref(kTorrentDhtEnabled, true);
  registry->RegisterBooleanPref(kTorrentPexEnabled, true);
  registry->RegisterIntegerPref(kTorrentDownloadLimitKib, 0);
  registry->RegisterIntegerPref(kTorrentUploadLimitKib, 256);
}

DownloadSettings ReadDownloadSettings(const PrefService& local_state) {
  DownloadSettings settings;
  const int parallel_mode = local_state.GetInteger(kDownloadParallelMode);
  settings.parallel_mode = IsValidDownloadParallelMode(parallel_mode)
                               ? parallel_mode
                               : kDownloadParallelModeSmart;
  settings.reduce_on_metered =
      local_state.GetBoolean(kDownloadReduceOnMetered);
  settings.reduce_on_battery =
      local_state.GetBoolean(kDownloadReduceOnBattery);
  settings.torrent_dht_enabled = local_state.GetBoolean(kTorrentDhtEnabled);
  settings.torrent_pex_enabled = local_state.GetBoolean(kTorrentPexEnabled);
  const int download_limit =
      local_state.GetInteger(kTorrentDownloadLimitKib);
  settings.torrent_download_limit_kib =
      IsValidTorrentRateLimit(download_limit) ? download_limit : 0;
  const int upload_limit = local_state.GetInteger(kTorrentUploadLimitKib);
  settings.torrent_upload_limit_kib =
      IsValidTorrentRateLimit(upload_limit) ? upload_limit : 256;
  return settings;
}

bool IsValidDownloadParallelMode(int mode) {
  return mode == kDownloadParallelModeSmart ||
         mode == kDownloadParallelModeSingle ||
         mode == kDownloadParallelModeThree ||
         mode == kDownloadParallelModeSix;
}

bool IsValidTorrentRateLimit(int limit_kib) {
  return limit_kib >= 0 && limit_kib <= kMaxTorrentRateLimitKib;
}

void WriteDownloadSettings(PrefService* local_state,
                           const DownloadSettings& settings) {
  CHECK(local_state);
  CHECK(IsValidDownloadParallelMode(settings.parallel_mode));
  CHECK(IsValidTorrentRateLimit(settings.torrent_download_limit_kib));
  CHECK(IsValidTorrentRateLimit(settings.torrent_upload_limit_kib));
  local_state->SetInteger(kDownloadParallelMode, settings.parallel_mode);
  local_state->SetBoolean(kDownloadReduceOnMetered,
                          settings.reduce_on_metered);
  local_state->SetBoolean(kDownloadReduceOnBattery,
                          settings.reduce_on_battery);
  local_state->SetBoolean(kTorrentDhtEnabled, settings.torrent_dht_enabled);
  local_state->SetBoolean(kTorrentPexEnabled, settings.torrent_pex_enabled);
  local_state->SetInteger(kTorrentDownloadLimitKib,
                          settings.torrent_download_limit_kib);
  local_state->SetInteger(kTorrentUploadLimitKib,
                          settings.torrent_upload_limit_kib);
  ApplyDownloadSettings(*local_state);
}

void ApplyDownloadSettings(const PrefService& local_state) {
  const DownloadSettings settings = ReadDownloadSettings(local_state);
  download::features::ConfigureAegisParallelDownloading(
      settings.parallel_mode, settings.reduce_on_metered,
      settings.reduce_on_battery);
}

}  // namespace aegis
