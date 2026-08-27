// Copyright 2026 GCSA

#include "chrome/services/aegis_torrent/aegis_torrent_service.h"

#include <algorithm>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "base/unguessable_token.h"
#include "build/build_config.h"
#include "chrome/services/aegis_torrent/torrent_safety.h"
#include "libtorrent/add_torrent_params.hpp"
#include "libtorrent/extensions/smart_ban.hpp"
#include "libtorrent/extensions/ut_metadata.hpp"
#include "libtorrent/extensions/ut_pex.hpp"
#include "libtorrent/load_torrent.hpp"
#include "libtorrent/magnet_uri.hpp"
#include "libtorrent/session.hpp"
#include "libtorrent/session_params.hpp"
#include "libtorrent/settings_pack.hpp"
#include "libtorrent/torrent_flags.hpp"
#include "libtorrent/torrent_status.hpp"
#include "sandbox/mac/seatbelt_extension.h"
#include "sandbox/mac/seatbelt_extension_token.h"

namespace aegis::torrent {
namespace {

mojom::TorrentPreviewPtr ToMojoPreview(const SafeTorrentPreview& source) {
  auto preview = mojom::TorrentPreview::New();
  preview->ok = source.ok;
  preview->error = source.error;
  preview->name = source.name;
  preview->total_size = source.total_size;
  preview->has_v1 = source.has_v1;
  preview->has_v2 = source.has_v2;
  preview->tracker_count = source.tracker_count;
  for (const SafeTorrentFile& source_file : source.files) {
    auto file = mojom::TorrentFile::New();
    file->index = source_file.index;
    file->path = source_file.path;
    file->size = source_file.size;
    preview->files.push_back(std::move(file));
  }
  return preview;
}

std::string TorrentStateName(libtorrent::torrent_status::state_t state) {
  using State = libtorrent::torrent_status;
  switch (state) {
    case State::checking_files:
      return "checking";
    case State::downloading_metadata:
      return "metadata";
    case State::downloading:
      return "downloading";
    case State::finished:
      return "finished";
    case State::seeding:
      return "seeding";
    case State::checking_resume_data:
      return "resuming";
  }
}

uint32_t ClampToUint32(int value) {
  return value <= 0 ? 0u : static_cast<uint32_t>(value);
}

}  // namespace

struct AegisTorrentService::State {
  struct Task {
    std::string name;
    libtorrent::torrent_handle handle;
    std::unique_ptr<sandbox::SeatbeltExtension> destination_extension;
  };

  std::unique_ptr<libtorrent::session> session;
  std::unordered_map<std::string, Task> tasks;
};

AegisTorrentService::AegisTorrentService(
    mojo::PendingReceiver<mojom::AegisTorrentService> receiver)
    : receiver_(this, std::move(receiver)), state_(std::make_unique<State>()) {}

AegisTorrentService::~AegisTorrentService() = default;

void AegisTorrentService::ValidateTorrent(
    const std::vector<uint8_t>& torrent_data,
    ValidateTorrentCallback callback) {
  std::move(callback).Run(ToMojoPreview(ValidateTorrentBytes(torrent_data)));
}

void AegisTorrentService::ValidateMagnet(const std::string& magnet_uri,
                                         ValidateMagnetCallback callback) {
  std::move(callback).Run(ToMojoPreview(ValidateMagnetUri(magnet_uri)));
}

void AegisTorrentService::EnsureSession(const mojom::TorrentOptions& options) {
  libtorrent::settings_pack settings = libtorrent::min_memory_usage();
  settings.set_str(libtorrent::settings_pack::user_agent,
                   "Aegis/0.1 libtorrent/2.1.1");
  settings.set_bool(libtorrent::settings_pack::enable_upnp, false);
  settings.set_bool(libtorrent::settings_pack::enable_natpmp, false);
  settings.set_bool(libtorrent::settings_pack::enable_lsd, false);
  settings.set_bool(libtorrent::settings_pack::enable_dht, options.enable_dht);
  settings.set_int(libtorrent::settings_pack::connections_limit, 80);
  settings.set_int(libtorrent::settings_pack::active_downloads, 3);
  settings.set_int(libtorrent::settings_pack::active_seeds, 0);
  settings.set_int(libtorrent::settings_pack::download_rate_limit,
                   static_cast<int>(std::min<uint64_t>(
                       uint64_t{options.download_limit_kib} * 1024,
                       std::numeric_limits<int>::max())));
  settings.set_int(libtorrent::settings_pack::upload_rate_limit,
                   static_cast<int>(std::min<uint64_t>(
                       uint64_t{options.upload_limit_kib} * 1024,
                       std::numeric_limits<int>::max())));
  if (!state_->session) {
    std::vector<std::shared_ptr<libtorrent::plugin>> no_default_plugins;
    libtorrent::session_params params(std::move(settings),
                                      std::move(no_default_plugins));
    state_->session = std::make_unique<libtorrent::session>(std::move(params));
  } else {
    state_->session->apply_settings(std::move(settings));
    state_->session->resume();
  }
}

void AegisTorrentService::StartTorrent(
    const std::vector<uint8_t>& torrent_data,
    const std::string& magnet_uri,
    const base::FilePath& destination,
    const std::vector<uint32_t>& selected_files,
    mojom::TorrentOptionsPtr options,
#if BUILDFLAG(IS_MAC)
    sandbox::SeatbeltExtensionToken destination_token,
#endif
    StartTorrentCallback callback) {
  if (!options || destination.empty() || !destination.IsAbsolute() ||
      (torrent_data.empty() == magnet_uri.empty())) {
    std::move(callback).Run(false, "invalid torrent start request", "");
    return;
  }

  const SafeTorrentPreview preview = torrent_data.empty()
                                         ? ValidateMagnetUri(magnet_uri)
                                         : ValidateTorrentBytes(torrent_data);
  if (!preview.ok) {
    std::move(callback).Run(false, preview.error, "");
    return;
  }

#if BUILDFLAG(IS_MAC)
  auto destination_extension =
      sandbox::SeatbeltExtension::FromToken(std::move(destination_token));
  if (!destination_extension || !destination_extension->Consume()) {
    std::move(callback).Run(false, "download directory permission denied", "");
    return;
  }
#endif

  libtorrent::error_code error;
  libtorrent::add_torrent_params params;
  if (!torrent_data.empty()) {
    libtorrent::load_torrent_limits limits;
    limits.max_buffer_size = 4 * 1024 * 1024;
    limits.max_pieces = 1'048'576;
    limits.max_decode_depth = 40;
    limits.max_decode_tokens = 200'000;
    limits.max_duplicate_filenames = 32;
    limits.max_directory_depth = 32;
    const auto data = libtorrent::span<char const>(
        reinterpret_cast<char const*>(torrent_data.data()),
        torrent_data.size());
    params = libtorrent::load_torrent_buffer(data, error, limits);
  } else {
    params = libtorrent::parse_magnet_uri(magnet_uri, error);
  }
  if (error) {
    std::move(callback).Run(false, error.message(), "");
    return;
  }

  params.flags &= ~libtorrent::torrent_flags::paused;
  params.flags &= ~libtorrent::torrent_flags::auto_managed;
  params.save_path = destination.AsUTF8Unsafe();
  params.extensions.push_back(&libtorrent::create_ut_metadata_plugin);
  params.extensions.push_back(&libtorrent::create_smart_ban_plugin);
  if (options->enable_pex) {
    params.extensions.push_back(&libtorrent::create_ut_pex_plugin);
  }
  if (!torrent_data.empty() && !selected_files.empty()) {
    params.file_priorities.assign(preview.files.size(),
                                  libtorrent::dont_download);
    for (uint32_t file_index : selected_files) {
      if (file_index >= params.file_priorities.size()) {
        std::move(callback).Run(false, "selected file index is invalid", "");
        return;
      }
      params.file_priorities[file_index] = libtorrent::default_priority;
    }
  }

  EnsureSession(*options);
  libtorrent::torrent_handle handle =
      state_->session->add_torrent(std::move(params), error);
  if (error || !handle.is_valid()) {
    std::move(callback).Run(
        false, error ? error.message() : "failed to add torrent", "");
    return;
  }
  const std::string task_id = base::UnguessableToken::Create().ToString();
  State::Task task;
  task.name = preview.name;
  task.handle = std::move(handle);
#if BUILDFLAG(IS_MAC)
  task.destination_extension = std::move(destination_extension);
#endif
  state_->tasks.emplace(task_id, std::move(task));
  std::move(callback).Run(true, "", task_id);
}

void AegisTorrentService::GetStatus(const std::string& task_id,
                                    GetStatusCallback callback) {
  auto result = mojom::TorrentStatus::New();
  auto task = state_->tasks.find(task_id);
  if (task == state_->tasks.end() || !task->second.handle.is_valid()) {
    result->error = "torrent task not found";
    std::move(callback).Run(std::move(result));
    return;
  }
  const libtorrent::torrent_status status = task->second.handle.status();
  if (status.is_seeding) {
    task->second.handle.pause();
  }
  result->found = true;
  result->name = status.name.empty() ? task->second.name : status.name;
  result->state = TorrentStateName(status.state);
  result->total_bytes =
      status.total_wanted > 0 ? static_cast<uint64_t>(status.total_wanted) : 0;
  result->completed_bytes =
      status.total_wanted_done > 0
          ? static_cast<uint64_t>(status.total_wanted_done)
          : 0;
  result->progress_ppm = ClampToUint32(status.progress_ppm);
  result->download_rate = ClampToUint32(status.download_payload_rate);
  result->upload_rate = ClampToUint32(status.upload_payload_rate);
  result->peers = ClampToUint32(status.num_peers);
  result->seeds = ClampToUint32(status.num_seeds);
  result->paused = bool(status.flags & libtorrent::torrent_flags::paused);
  result->finished = status.is_finished || status.is_seeding;
  if (status.errc) {
    result->error = status.errc.message();
  }
  bool has_active_task = false;
  for (const auto& item : state_->tasks) {
    const State::Task& candidate = item.second;
    if (!candidate.handle.is_valid()) {
      continue;
    }
    const libtorrent::torrent_status candidate_status =
        candidate.handle.status();
    if (!candidate_status.is_finished && !candidate_status.is_seeding &&
        !(candidate_status.flags & libtorrent::torrent_flags::paused)) {
      has_active_task = true;
      break;
    }
  }
  if (!has_active_task && state_->session) {
    libtorrent::settings_pack idle;
    idle.set_bool(libtorrent::settings_pack::enable_dht, false);
    state_->session->apply_settings(std::move(idle));
  }
  std::move(callback).Run(std::move(result));
}

void AegisTorrentService::Pause(const std::string& task_id,
                                PauseCallback callback) {
  auto task = state_->tasks.find(task_id);
  const bool ok = task != state_->tasks.end() && task->second.handle.is_valid();
  if (ok) {
    task->second.handle.pause();
  }
  std::move(callback).Run(ok);
}

void AegisTorrentService::Resume(const std::string& task_id,
                                 ResumeCallback callback) {
  auto task = state_->tasks.find(task_id);
  const bool ok = task != state_->tasks.end() && task->second.handle.is_valid();
  if (ok) {
    task->second.handle.resume();
  }
  std::move(callback).Run(ok);
}

void AegisTorrentService::Cancel(const std::string& task_id,
                                 bool delete_files,
                                 CancelCallback callback) {
  auto task = state_->tasks.find(task_id);
  if (task == state_->tasks.end() || !state_->session) {
    std::move(callback).Run(false);
    return;
  }
  libtorrent::torrent_handle handle = task->second.handle;
  handle.pause();
  state_->tasks.erase(task);
  const bool should_reset_session = state_->tasks.empty();
  std::move(callback).Run(true);
  if (should_reset_session) {
    state_->session.reset();
  } else {
    state_->session->remove_torrent(
        handle, delete_files ? libtorrent::session_handle::delete_files
                             : libtorrent::remove_flags_t{});
  }
}

}  // namespace aegis::torrent
