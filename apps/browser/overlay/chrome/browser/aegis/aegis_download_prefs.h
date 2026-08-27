// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AEGIS_DOWNLOAD_PREFS_H_
#define CHROME_BROWSER_AEGIS_AEGIS_DOWNLOAD_PREFS_H_

class PrefRegistrySimple;
class PrefService;

namespace aegis {

inline constexpr char kDownloadParallelMode[] =
    "aegis.download.parallel_mode";
inline constexpr char kDownloadReduceOnMetered[] =
    "aegis.download.reduce_on_metered";
inline constexpr char kDownloadReduceOnBattery[] =
    "aegis.download.reduce_on_battery";
inline constexpr char kTorrentDhtEnabled[] =
    "aegis.download.torrent_dht_enabled";
inline constexpr char kTorrentPexEnabled[] =
    "aegis.download.torrent_pex_enabled";
inline constexpr char kTorrentDownloadLimitKib[] =
    "aegis.download.torrent_download_limit_kib";
inline constexpr char kTorrentUploadLimitKib[] =
    "aegis.download.torrent_upload_limit_kib";

constexpr int kDownloadParallelModeSmart = 0;
constexpr int kDownloadParallelModeSingle = 1;
constexpr int kDownloadParallelModeThree = 3;
constexpr int kDownloadParallelModeSix = 6;
constexpr int kMaxTorrentRateLimitKib = 1'000'000;

struct DownloadSettings {
  int parallel_mode = kDownloadParallelModeSmart;
  bool reduce_on_metered = true;
  bool reduce_on_battery = true;
  bool torrent_dht_enabled = true;
  bool torrent_pex_enabled = true;
  int torrent_download_limit_kib = 0;
  int torrent_upload_limit_kib = 256;
};

void RegisterDownloadLocalStatePrefs(PrefRegistrySimple* registry);
DownloadSettings ReadDownloadSettings(const PrefService& local_state);
bool IsValidDownloadParallelMode(int mode);
bool IsValidTorrentRateLimit(int limit_kib);
void WriteDownloadSettings(PrefService* local_state,
                           const DownloadSettings& settings);
void ApplyDownloadSettings(const PrefService& local_state);

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_DOWNLOAD_PREFS_H_
