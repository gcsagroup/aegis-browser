// Copyright 2026 GCSA

#ifndef CHROME_SERVICES_AEGIS_TORRENT_TORRENT_SAFETY_H_
#define CHROME_SERVICES_AEGIS_TORRENT_TORRENT_SAFETY_H_

#include <cstdint>
#include <string>
#include <vector>

namespace aegis::torrent {

struct SafeTorrentFile {
  uint32_t index = 0;
  std::string path;
  uint64_t size = 0;
};

struct SafeTorrentPreview {
  bool ok = false;
  std::string error;
  std::string name;
  uint64_t total_size = 0;
  bool has_v1 = false;
  bool has_v2 = false;
  uint32_t tracker_count = 0;
  std::vector<SafeTorrentFile> files;
};

SafeTorrentPreview ValidateTorrentBytes(const std::vector<uint8_t>& bytes);
SafeTorrentPreview ValidateMagnetUri(const std::string& magnet_uri);

}  // namespace aegis::torrent

#endif  // CHROME_SERVICES_AEGIS_TORRENT_TORRENT_SAFETY_H_
