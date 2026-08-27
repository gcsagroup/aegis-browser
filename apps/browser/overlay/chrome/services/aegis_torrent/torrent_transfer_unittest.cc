// Copyright 2026 GCSA

#include <algorithm>
#include <cstdint>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/threading/platform_thread.h"
#include "base/time/time.h"
#include "libtorrent/add_torrent_params.hpp"
#include "libtorrent/address.hpp"
#include "libtorrent/create_torrent.hpp"
#include "libtorrent/error_code.hpp"
#include "libtorrent/load_torrent.hpp"
#include "libtorrent/session.hpp"
#include "libtorrent/settings_pack.hpp"
#include "libtorrent/torrent_flags.hpp"
#include "libtorrent/torrent_info.hpp"
#include "libtorrent/torrent_status.hpp"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::torrent {
namespace {

libtorrent::settings_pack LocalTransferSettings() {
  libtorrent::settings_pack settings = libtorrent::min_memory_usage();
  settings.set_str(libtorrent::settings_pack::listen_interfaces, "127.0.0.1:0");
  settings.set_bool(libtorrent::settings_pack::enable_dht, false);
  settings.set_bool(libtorrent::settings_pack::enable_lsd, false);
  settings.set_bool(libtorrent::settings_pack::enable_upnp, false);
  settings.set_bool(libtorrent::settings_pack::enable_natpmp, false);
  settings.set_bool(
      libtorrent::settings_pack::allow_multiple_connections_per_ip, true);
  settings.set_int(libtorrent::settings_pack::connections_limit, 12);
  return settings;
}

libtorrent::torrent_handle AddTorrent(
    libtorrent::session& session,
    const std::shared_ptr<const libtorrent::torrent_info>& info,
    const base::FilePath& save_path,
    bool seed_mode) {
  libtorrent::add_torrent_params params;
  params.ti = info;
  params.save_path = save_path.value();
  params.flags &= ~libtorrent::torrent_flags::paused;
  params.flags &= ~libtorrent::torrent_flags::auto_managed;
  if (seed_mode) {
    params.flags |= libtorrent::torrent_flags::seed_mode;
  }
  libtorrent::error_code error;
  libtorrent::torrent_handle handle =
      session.add_torrent(std::move(params), error);
  EXPECT_FALSE(error) << error.message();
  EXPECT_TRUE(handle.is_valid());
  return handle;
}

TEST(AegisTorrentTransferTest, DownloadsIdenticalPayloadFromTwoLocalSeeds) {
  base::ScopedTempDir root;
  ASSERT_TRUE(root.CreateUniqueTempDir());
  const base::FilePath seed_one = root.GetPath().AppendASCII("seed-one");
  const base::FilePath seed_two = root.GetPath().AppendASCII("seed-two");
  const base::FilePath download = root.GetPath().AppendASCII("download");
  ASSERT_TRUE(base::CreateDirectory(seed_one));
  ASSERT_TRUE(base::CreateDirectory(seed_two));
  ASSERT_TRUE(base::CreateDirectory(download));

  std::string payload(1024 * 1024, '\0');
  for (size_t index = 0; index < payload.size(); ++index) {
    payload[index] = static_cast<char>((index * 131 + 17) & 0xff);
  }
  const base::FilePath source_file = seed_one.AppendASCII("payload.bin");
  ASSERT_TRUE(base::WriteFile(source_file, payload));
  ASSERT_TRUE(base::WriteFile(seed_two.AppendASCII("payload.bin"), payload));

  std::vector<libtorrent::create_file_entry> files;
  files.emplace_back("payload.bin", static_cast<int64_t>(payload.size()));
  libtorrent::create_torrent creator(std::move(files), 16 * 1024,
                                     libtorrent::create_torrent::v1_only);
  libtorrent::error_code error;
  libtorrent::set_piece_hashes(creator, seed_one.value(), error);
  ASSERT_FALSE(error) << error.message();
  std::vector<char> metadata = creator.generate_buf();
  libtorrent::add_torrent_params loaded = libtorrent::load_torrent_buffer(
      metadata, error, libtorrent::load_torrent_limits());
  ASSERT_FALSE(error) << error.message();
  ASSERT_TRUE(loaded.ti);
  auto info = loaded.ti;

  libtorrent::session seeder_one(LocalTransferSettings());
  libtorrent::session seeder_two(LocalTransferSettings());
  libtorrent::session downloader(LocalTransferSettings());
  libtorrent::torrent_handle first =
      AddTorrent(seeder_one, info, seed_one, true);
  libtorrent::torrent_handle second =
      AddTorrent(seeder_two, info, seed_two, true);
  libtorrent::torrent_handle target =
      AddTorrent(downloader, info, download, false);

  ASSERT_GT(seeder_one.listen_port(), 0);
  ASSERT_GT(seeder_two.listen_port(), 0);
  const libtorrent::address loopback =
      libtorrent::make_address("127.0.0.1", error);
  ASSERT_FALSE(error) << error.message();
  target.connect_peer(
      {loopback, static_cast<uint16_t>(seeder_one.listen_port())});
  target.connect_peer(
      {loopback, static_cast<uint16_t>(seeder_two.listen_port())});

  libtorrent::torrent_status status;
  const base::TimeTicks deadline = base::TimeTicks::Now() + base::Seconds(20);
  do {
    status = target.status();
    if (status.is_finished || status.is_seeding) {
      break;
    }
    base::PlatformThread::Sleep(base::Milliseconds(100));
  } while (base::TimeTicks::Now() < deadline);

  EXPECT_TRUE(status.is_finished || status.is_seeding)
      << "downloaded=" << status.total_wanted_done
      << " total=" << status.total_wanted << " peers=" << status.num_peers;
  std::string downloaded;
  ASSERT_TRUE(
      base::ReadFileToString(download.AppendASCII("payload.bin"), &downloaded));
  EXPECT_EQ(downloaded, payload);
  EXPECT_TRUE(first.is_valid());
  EXPECT_TRUE(second.is_valid());
}

}  // namespace
}  // namespace aegis::torrent
