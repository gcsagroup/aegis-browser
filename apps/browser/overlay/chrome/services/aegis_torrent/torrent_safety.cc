// Copyright 2026 GCSA

#include "chrome/services/aegis_torrent/torrent_safety.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>
#include <utility>

#include "base/files/file_path.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "libtorrent/bdecode.hpp"
#include "libtorrent/file_storage.hpp"
#include "libtorrent/load_torrent.hpp"
#include "libtorrent/magnet_uri.hpp"
#include "libtorrent/torrent_info.hpp"

namespace aegis::torrent {
namespace {

constexpr size_t kMaxTorrentBytes = 4 * 1024 * 1024;
constexpr size_t kMaxMagnetBytes = 16 * 1024;
constexpr int kMaxFiles = 2048;
constexpr uint64_t kMaxTotalBytes = uint64_t{2} * 1024 * 1024 * 1024 * 1024;
constexpr size_t kMaxPathBytes = 1024;
constexpr size_t kMaxComponentBytes = 255;
constexpr int kMaxDirectoryDepth = 32;

bool IsUnsafeComponent(libtorrent::string_view component) {
  if (component.empty() || component.size() > kMaxComponentBytes ||
      component == "." || component == "..") {
    return true;
  }
  for (char value : component) {
    const unsigned char byte = static_cast<unsigned char>(value);
    if (byte == 0 || byte < 0x20 || value == '/' || value == '\\') {
      return true;
    }
  }
  return false;
}

bool ValidateV2Tree(const libtorrent::bdecode_node& node, int depth) {
  if (node.type() != libtorrent::bdecode_node::dict_t ||
      depth > kMaxDirectoryDepth) {
    return false;
  }
  for (int index = 0; index < node.dict_size(); ++index) {
    auto [key, value] = node.dict_at(index);
    if (key.empty()) {
      if (value.type() != libtorrent::bdecode_node::dict_t) {
        return false;
      }
      continue;
    }
    if (IsUnsafeComponent(key) || !ValidateV2Tree(value, depth + 1)) {
      return false;
    }
  }
  return true;
}

bool HasUnsafeRawPaths(const std::vector<uint8_t>& bytes) {
  libtorrent::error_code error;
  const auto data = libtorrent::span<char const>(
      reinterpret_cast<char const*>(bytes.data()), bytes.size());
  libtorrent::bdecode_node root =
      libtorrent::bdecode(data, error, nullptr, kMaxDirectoryDepth + 8, 200000);
  if (error || root.type() != libtorrent::bdecode_node::dict_t) {
    return true;
  }
  libtorrent::bdecode_node info = root.dict_find_dict("info");
  if (!info) {
    return true;
  }
  libtorrent::string_view name = info.dict_find_string_value("name.utf-8");
  if (name.empty()) {
    name = info.dict_find_string_value("name");
  }
  if (IsUnsafeComponent(name)) {
    return true;
  }

  libtorrent::bdecode_node files = info.dict_find_list("files");
  if (files) {
    if (files.list_size() <= 0 || files.list_size() > kMaxFiles) {
      return true;
    }
    for (int file_index = 0; file_index < files.list_size(); ++file_index) {
      libtorrent::bdecode_node file = files.list_at(file_index);
      if (file.type() != libtorrent::bdecode_node::dict_t) {
        return true;
      }
      libtorrent::bdecode_node path = file.dict_find_list("path.utf-8");
      if (!path) {
        path = file.dict_find_list("path");
      }
      if (!path || path.list_size() <= 0 ||
          path.list_size() > kMaxDirectoryDepth) {
        return true;
      }
      for (int part = 0; part < path.list_size(); ++part) {
        libtorrent::bdecode_node component = path.list_at(part);
        if (component.type() != libtorrent::bdecode_node::string_t ||
            IsUnsafeComponent(component.string_value())) {
          return true;
        }
      }
    }
  }

  libtorrent::bdecode_node file_tree = info.dict_find_dict("file tree");
  return file_tree && !ValidateV2Tree(file_tree, 0);
}

bool IsSafeNormalizedPath(const std::string& path) {
  if (path.empty() || path.size() > kMaxPathBytes ||
      !base::IsStringUTF8(path)) {
    return false;
  }
  const base::FilePath file_path = base::FilePath::FromUTF8Unsafe(path);
  if (file_path.IsAbsolute() || file_path.ReferencesParent()) {
    return false;
  }
  const std::vector<base::FilePath::StringType> components =
      file_path.GetComponents();
  return !components.empty() &&
         static_cast<int>(components.size()) <= kMaxDirectoryDepth + 1;
}

SafeTorrentPreview Fail(std::string error) {
  SafeTorrentPreview result;
  result.error = std::move(error);
  return result;
}

}  // namespace

SafeTorrentPreview ValidateTorrentBytes(const std::vector<uint8_t>& bytes) {
  if (bytes.empty() || bytes.size() > kMaxTorrentBytes) {
    return Fail("torrent metadata exceeds the 4 MiB limit");
  }
  if (HasUnsafeRawPaths(bytes)) {
    return Fail("torrent contains an unsafe file path");
  }

  libtorrent::load_torrent_limits limits;
  limits.max_buffer_size = static_cast<int>(kMaxTorrentBytes);
  limits.max_pieces = 1'048'576;
  limits.max_decode_depth = kMaxDirectoryDepth + 8;
  limits.max_decode_tokens = 200'000;
  limits.max_duplicate_filenames = 32;
  limits.max_directory_depth = kMaxDirectoryDepth;

  libtorrent::error_code error;
  const auto data = libtorrent::span<char const>(
      reinterpret_cast<char const*>(bytes.data()), bytes.size());
  libtorrent::add_torrent_params params =
      libtorrent::load_torrent_buffer(data, error, limits);
  if (error || !params.ti) {
    return Fail(error ? error.message() : "torrent metadata is incomplete");
  }
  if (params.ti->num_files() <= 0 || params.ti->num_files() > kMaxFiles ||
      params.ti->total_size() < 0 ||
      static_cast<uint64_t>(params.ti->total_size()) > kMaxTotalBytes) {
    return Fail("torrent file count or total size exceeds the safety limit");
  }
  if (!base::IsStringUTF8(params.ti->name()) || params.ti->name().empty() ||
      params.ti->name().size() > kMaxComponentBytes) {
    return Fail("torrent name is invalid");
  }

  SafeTorrentPreview result;
  result.name = params.ti->name();
  result.total_size = static_cast<uint64_t>(params.ti->total_size());
  result.has_v1 = params.ti->info_hashes().has_v1();
  result.has_v2 = params.ti->info_hashes().has_v2();
  result.tracker_count = static_cast<uint32_t>(std::min<size_t>(
      params.trackers.size(), std::numeric_limits<uint32_t>::max()));
  const libtorrent::file_storage& files = params.ti->layout();
  result.files.reserve(files.num_files());
  for (int file_number = 0; file_number < files.num_files(); ++file_number) {
    const libtorrent::file_index_t file_index{file_number};
    const std::string path = files.file_path(file_index);
    if (files.file_absolute_path(file_index) ||
        (files.file_flags(file_index) &
         libtorrent::file_storage::flag_symlink) ||
        !IsSafeNormalizedPath(path) || files.file_size(file_index) < 0) {
      return Fail("torrent contains an unsafe file entry");
    }
    result.files.push_back(
        {static_cast<uint32_t>(file_number), path,
         static_cast<uint64_t>(files.file_size(file_index))});
  }
  result.ok = true;
  return result;
}

SafeTorrentPreview ValidateMagnetUri(const std::string& magnet_uri) {
  if (magnet_uri.empty() || magnet_uri.size() > kMaxMagnetBytes ||
      !base::StartsWith(magnet_uri, "magnet:?",
                        base::CompareCase::INSENSITIVE_ASCII)) {
    return Fail("magnet link is invalid or too large");
  }
  libtorrent::error_code error;
  libtorrent::add_torrent_params params =
      libtorrent::parse_magnet_uri(magnet_uri, error);
  if (error || (!params.info_hashes.has_v1() && !params.info_hashes.has_v2())) {
    return Fail(error ? error.message()
                      : "magnet link has no supported info hash");
  }
  if (!params.name.empty() && (!base::IsStringUTF8(params.name) ||
                               params.name.size() > kMaxComponentBytes ||
                               IsUnsafeComponent(params.name))) {
    return Fail("magnet display name is unsafe");
  }

  SafeTorrentPreview result;
  result.ok = true;
  result.name = params.name.empty() ? "Magnet download" : params.name;
  result.has_v1 = params.info_hashes.has_v1();
  result.has_v2 = params.info_hashes.has_v2();
  result.tracker_count = static_cast<uint32_t>(std::min<size_t>(
      params.trackers.size(), std::numeric_limits<uint32_t>::max()));
  return result;
}

}  // namespace aegis::torrent
