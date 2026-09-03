// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_torrent_client.h"

#include <memory>
#include <utility>

#include "base/functional/bind.h"
#include "content/public/browser/service_process_host.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "sandbox/mac/seatbelt_extension.h"

namespace aegis {

TorrentTaskRegistry::TorrentTaskRegistry() = default;
TorrentTaskRegistry::~TorrentTaskRegistry() = default;

bool TorrentTaskRegistry::BeginStart(const std::string& owner_id) {
  if (owner_id.empty()) {
    return false;
  }
  OwnerState& owner = owners_[owner_id];
  if (!owner.accepting || owner.pending_starts != 0 || !owner.task_id.empty()) {
    return false;
  }
  ++owner.pending_starts;
  return true;
}

TorrentTaskRegistry::StartDisposition TorrentTaskRegistry::CompleteStart(
    const std::string& owner_id,
    bool ok,
    const std::string& task_id) {
  auto owner = owners_.find(owner_id);
  if (owner == owners_.end() || owner->second.pending_starts == 0) {
    return StartDisposition::kCancel;
  }
  --owner->second.pending_starts;
  if (!owner->second.accepting) {
    if (owner->second.pending_starts == 0) {
      owners_.erase(owner);
    }
    return StartDisposition::kCancel;
  }
  if (ok && !task_id.empty()) {
    owner->second.task_id = task_id;
  }
  return StartDisposition::kDeliver;
}

std::vector<std::string> TorrentTaskRegistry::RevokeOwner(
    const std::string& owner_id) {
  if (owner_id.empty()) {
    return {};
  }
  auto owner = owners_.find(owner_id);
  if (owner == owners_.end()) {
    return {};
  }
  owner->second.accepting = false;
  std::vector<std::string> tasks;
  if (!owner->second.task_id.empty()) {
    tasks.push_back(std::move(owner->second.task_id));
  }
  if (owner->second.pending_starts == 0) {
    owners_.erase(owner);
  }
  return tasks;
}

bool TorrentTaskRegistry::OwnsTask(const std::string& owner_id,
                                   const std::string& task_id) const {
  auto owner = owners_.find(owner_id);
  return owner != owners_.end() && owner->second.accepting &&
         owner->second.task_id == task_id;
}

std::string TorrentTaskRegistry::CurrentTaskId(
    const std::string& owner_id) const {
  auto owner = owners_.find(owner_id);
  return owner != owners_.end() && owner->second.accepting
             ? owner->second.task_id
             : std::string();
}

void TorrentTaskRegistry::ForgetTask(const std::string& owner_id,
                                     const std::string& task_id) {
  auto owner = owners_.find(owner_id);
  if (owner != owners_.end() && owner->second.task_id == task_id) {
    owner->second.task_id.clear();
  }
}

AegisTorrentClient* AegisTorrentClient::GetInstance() {
  static base::NoDestructor<AegisTorrentClient> instance;
  return instance.get();
}

AegisTorrentClient::AegisTorrentClient() = default;
AegisTorrentClient::~AegisTorrentClient() = default;

mojom::AegisTorrentService* AegisTorrentClient::GetRemote() {
  if (!remote_.is_bound()) {
    remote_ = content::ServiceProcessHost::Launch<mojom::AegisTorrentService>(
        content::ServiceProcessHost::Options()
            .WithDisplayName("Aegis Torrent Service")
            .Pass());
    remote_.reset_on_disconnect();
  }
  return remote_.get();
}

void AegisTorrentClient::ValidateTorrent(
    std::vector<uint8_t> torrent_data,
    mojom::AegisTorrentService::ValidateTorrentCallback callback) {
  GetRemote()->ValidateTorrent(
      std::move(torrent_data),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
          std::move(callback), mojom::TorrentPreview::New()));
}

void AegisTorrentClient::ValidateMagnet(
    std::string magnet_uri,
    mojom::AegisTorrentService::ValidateMagnetCallback callback) {
  GetRemote()->ValidateMagnet(
      std::move(magnet_uri),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
          std::move(callback), mojom::TorrentPreview::New()));
}

void AegisTorrentClient::StartTorrent(
    const std::string& owner_id,
    std::vector<uint8_t> torrent_data,
    std::string magnet_uri,
    const base::FilePath& destination,
    std::vector<uint32_t> selected_files,
    mojom::TorrentOptionsPtr options,
    mojom::AegisTorrentService::StartTorrentCallback callback) {
  if (!task_registry_.BeginStart(owner_id)) {
    std::move(callback).Run(false, "torrent profile is no longer active", "");
    return;
  }
  std::unique_ptr<sandbox::SeatbeltExtensionToken> token =
      sandbox::SeatbeltExtension::Issue(
          sandbox::SeatbeltExtension::FILE_READ_WRITE, destination.value());
  if (!token) {
    task_registry_.CompleteStart(owner_id, false, std::string());
    std::move(callback).Run(false, "download directory permission denied", "");
    return;
  }
  auto tracked_callback =
      base::BindOnce(&AegisTorrentClient::OnTorrentStarted,
                     base::Unretained(this), owner_id, std::move(callback));
  GetRemote()->StartTorrent(std::move(torrent_data), std::move(magnet_uri),
                            destination, std::move(selected_files),
                            std::move(options), std::move(*token),
                            mojo::WrapCallbackWithDefaultInvokeIfNotRun(
                                std::move(tracked_callback), false,
                                "torrent service disconnected", ""));
}

void AegisTorrentClient::OnTorrentStarted(
    std::string owner_id,
    mojom::AegisTorrentService::StartTorrentCallback callback,
    bool ok,
    const std::string& error,
    const std::string& task_id) {
  const TorrentTaskRegistry::StartDisposition disposition =
      task_registry_.CompleteStart(owner_id, ok, task_id);
  if (disposition == TorrentTaskRegistry::StartDisposition::kCancel) {
    if (ok && !task_id.empty() && remote_.is_bound()) {
      remote_->Cancel(task_id, false, base::BindOnce([](bool) {}));
    }
    std::move(callback).Run(false, "torrent profile closed before start", "");
    return;
  }
  std::move(callback).Run(ok, error, task_id);
}

void AegisTorrentClient::GetStatus(
    const std::string& owner_id,
    std::string task_id,
    mojom::AegisTorrentService::GetStatusCallback callback) {
  if (!task_registry_.OwnsTask(owner_id, task_id)) {
    auto status = mojom::TorrentStatus::New();
    status->error = "torrent task is not available in this profile";
    std::move(callback).Run(std::move(status));
    return;
  }
  auto tracked_callback = base::BindOnce(&AegisTorrentClient::OnTorrentStatus,
                                         base::Unretained(this), owner_id,
                                         task_id, std::move(callback));
  GetRemote()->GetStatus(
      std::move(task_id),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(std::move(tracked_callback),
                                                  mojom::TorrentStatus::New()));
}

void AegisTorrentClient::OnTorrentStatus(
    std::string owner_id,
    std::string task_id,
    mojom::AegisTorrentService::GetStatusCallback callback,
    mojom::TorrentStatusPtr status) {
  if (status && task_registry_.OwnsTask(owner_id, task_id) &&
      (!status->found || status->finished)) {
    task_registry_.ForgetTask(owner_id, task_id);
    if (status->found && status->finished && remote_.is_bound()) {
      // Completion is terminal: stop the paused seed and release the utility
      // task without deleting the user's completed files. Mojo ordering keeps
      // this cleanup ahead of a subsequent StartTorrent on the same Remote.
      remote_->Cancel(task_id, false, base::BindOnce([](bool) {}));
    }
  }
  std::move(callback).Run(std::move(status));
}

void AegisTorrentClient::Pause(
    const std::string& owner_id,
    std::string task_id,
    mojom::AegisTorrentService::PauseCallback callback) {
  if (!task_registry_.OwnsTask(owner_id, task_id)) {
    std::move(callback).Run(false);
    return;
  }
  GetRemote()->Pause(
      std::move(task_id),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(std::move(callback), false));
}

void AegisTorrentClient::Resume(
    const std::string& owner_id,
    std::string task_id,
    mojom::AegisTorrentService::ResumeCallback callback) {
  if (!task_registry_.OwnsTask(owner_id, task_id)) {
    std::move(callback).Run(false);
    return;
  }
  GetRemote()->Resume(
      std::move(task_id),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(std::move(callback), false));
}

void AegisTorrentClient::Cancel(
    const std::string& owner_id,
    std::string task_id,
    bool delete_files,
    mojom::AegisTorrentService::CancelCallback callback) {
  if (!task_registry_.OwnsTask(owner_id, task_id)) {
    std::move(callback).Run(false);
    return;
  }
  auto tracked_callback = base::BindOnce(
      &AegisTorrentClient::OnTorrentCancelled, base::Unretained(this), owner_id,
      task_id, std::move(callback));
  GetRemote()->Cancel(std::move(task_id), delete_files,
                      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
                          std::move(tracked_callback), false));
}

void AegisTorrentClient::OnTorrentCancelled(
    std::string owner_id,
    std::string task_id,
    mojom::AegisTorrentService::CancelCallback callback,
    bool ok) {
  if (ok) {
    task_registry_.ForgetTask(owner_id, task_id);
  }
  std::move(callback).Run(ok);
}

void AegisTorrentClient::RevokeOwnerTasks(const std::string& owner_id) {
  const std::vector<std::string> tasks = task_registry_.RevokeOwner(owner_id);
  if (!remote_.is_bound()) {
    return;
  }
  for (const std::string& task_id : tasks) {
    remote_->Cancel(task_id, false, base::BindOnce([](bool) {}));
  }
}

std::string AegisTorrentClient::CurrentTaskId(
    const std::string& owner_id) const {
  return task_registry_.CurrentTaskId(owner_id);
}

}  // namespace aegis
