// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_download_prefs.h"

#include "components/download/public/common/download_features.h"
#include "components/prefs/testing_pref_service.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

class AegisDownloadPrefsTest : public testing::Test {
 public:
  AegisDownloadPrefsTest() {
    RegisterDownloadLocalStatePrefs(prefs_.registry());
  }

  ~AegisDownloadPrefsTest() override {
    download::features::ConfigureAegisParallelDownloading(0, true, true);
  }

 protected:
  TestingPrefServiceSimple prefs_;
};

TEST_F(AegisDownloadPrefsTest, DefaultsAreConservativeAndApplied) {
  const DownloadSettings settings = ReadDownloadSettings(prefs_);
  EXPECT_EQ(settings.parallel_mode, kDownloadParallelModeSmart);
  EXPECT_TRUE(settings.reduce_on_metered);
  EXPECT_TRUE(settings.reduce_on_battery);
  EXPECT_TRUE(settings.torrent_dht_enabled);
  EXPECT_TRUE(settings.torrent_pex_enabled);
  EXPECT_EQ(settings.torrent_download_limit_kib, 0);
  EXPECT_EQ(settings.torrent_upload_limit_kib, 256);

  ApplyDownloadSettings(prefs_);
  EXPECT_EQ(download::features::GetAegisParallelDownloadMode(), 0);
  EXPECT_TRUE(
      download::features::ShouldAegisReduceParallelismOnMetered());
  EXPECT_TRUE(
      download::features::ShouldAegisReduceParallelismOnBattery());
}

TEST_F(AegisDownloadPrefsTest, RoundTripsAndAppliesSettings) {
  const DownloadSettings expected{
      .parallel_mode = kDownloadParallelModeSix,
      .reduce_on_metered = false,
      .reduce_on_battery = false,
      .torrent_dht_enabled = false,
      .torrent_pex_enabled = true,
      .torrent_download_limit_kib = 4096,
      .torrent_upload_limit_kib = 512,
  };
  WriteDownloadSettings(&prefs_, expected);

  const DownloadSettings actual = ReadDownloadSettings(prefs_);
  EXPECT_EQ(actual.parallel_mode, expected.parallel_mode);
  EXPECT_EQ(actual.reduce_on_metered, expected.reduce_on_metered);
  EXPECT_EQ(actual.reduce_on_battery, expected.reduce_on_battery);
  EXPECT_EQ(actual.torrent_dht_enabled, expected.torrent_dht_enabled);
  EXPECT_EQ(actual.torrent_pex_enabled, expected.torrent_pex_enabled);
  EXPECT_EQ(actual.torrent_download_limit_kib,
            expected.torrent_download_limit_kib);
  EXPECT_EQ(actual.torrent_upload_limit_kib,
            expected.torrent_upload_limit_kib);
  EXPECT_EQ(download::features::GetAegisParallelDownloadMode(), 6);
  EXPECT_FALSE(
      download::features::ShouldAegisReduceParallelismOnMetered());
  EXPECT_FALSE(
      download::features::ShouldAegisReduceParallelismOnBattery());
}

TEST_F(AegisDownloadPrefsTest, ValidatesModesAndLimits) {
  EXPECT_TRUE(IsValidDownloadParallelMode(0));
  EXPECT_TRUE(IsValidDownloadParallelMode(1));
  EXPECT_TRUE(IsValidDownloadParallelMode(3));
  EXPECT_TRUE(IsValidDownloadParallelMode(6));
  EXPECT_FALSE(IsValidDownloadParallelMode(2));
  EXPECT_FALSE(IsValidTorrentRateLimit(-1));
  EXPECT_TRUE(IsValidTorrentRateLimit(kMaxTorrentRateLimitKib));
  EXPECT_FALSE(IsValidTorrentRateLimit(kMaxTorrentRateLimitKib + 1));
}

}  // namespace
}  // namespace aegis
