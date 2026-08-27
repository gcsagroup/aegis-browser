// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_torrent_client.h"

#include <memory>
#include <utility>

#include "base/functional/bind.h"
#include "content/public/browser/service_process_host.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "sandbox/mac/seatbelt_extension.h"

namespace aegis {

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
    std::vector<uint8_t> torrent_data,
    std::string magnet_uri,
    const base::FilePath& destination,
    std::vector<uint32_t> selected_files,
    mojom::TorrentOptionsPtr options,
    mojom::AegisTorrentService::StartTorrentCallback callback) {
  std::unique_ptr<sandbox::SeatbeltExtensionToken> token =
      sandbox::SeatbeltExtension::Issue(
          sandbox::SeatbeltExtension::FILE_READ_WRITE, destination.value());
  if (!token) {
    std::move(callback).Run(false, "download directory permission denied", "");
    return;
  }
  GetRemote()->StartTorrent(
      std::move(torrent_data), std::move(magnet_uri), destination,
      std::move(selected_files), std::move(options), std::move(*token),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
          std::move(callback), false, "torrent service disconnected", ""));
}

void AegisTorrentClient::GetStatus(
    std::string task_id,
    mojom::AegisTorrentService::GetStatusCallback callback) {
  GetRemote()->GetStatus(std::move(task_id),
                         mojo::WrapCallbackWithDefaultInvokeIfNotRun(
                             std::move(callback), mojom::TorrentStatus::New()));
}

void AegisTorrentClient::Pause(
    std::string task_id,
    mojom::AegisTorrentService::PauseCallback callback) {
  GetRemote()->Pause(
      std::move(task_id),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(std::move(callback), false));
}

void AegisTorrentClient::Resume(
    std::string task_id,
    mojom::AegisTorrentService::ResumeCallback callback) {
  GetRemote()->Resume(
      std::move(task_id),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(std::move(callback), false));
}

void AegisTorrentClient::Cancel(
    std::string task_id,
    bool delete_files,
    mojom::AegisTorrentService::CancelCallback callback) {
  GetRemote()->Cancel(
      std::move(task_id), delete_files,
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(std::move(callback), false));
}

}  // namespace aegis
