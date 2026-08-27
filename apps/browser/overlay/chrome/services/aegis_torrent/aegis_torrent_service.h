// Copyright 2026 GCSA

#ifndef CHROME_SERVICES_AEGIS_TORRENT_AEGIS_TORRENT_SERVICE_H_
#define CHROME_SERVICES_AEGIS_TORRENT_AEGIS_TORRENT_SERVICE_H_

#include <memory>
#include <string>
#include <vector>

#include "build/build_config.h"
#include "chrome/services/aegis_torrent/public/mojom/aegis_torrent_service.mojom.h"
#include "mojo/public/cpp/bindings/receiver.h"

namespace aegis::torrent {

class AegisTorrentService : public mojom::AegisTorrentService {
 public:
  explicit AegisTorrentService(
      mojo::PendingReceiver<mojom::AegisTorrentService> receiver);
  AegisTorrentService(const AegisTorrentService&) = delete;
  AegisTorrentService& operator=(const AegisTorrentService&) = delete;
  ~AegisTorrentService() override;

  void ValidateTorrent(const std::vector<uint8_t>& torrent_data,
                       ValidateTorrentCallback callback) override;
  void ValidateMagnet(const std::string& magnet_uri,
                      ValidateMagnetCallback callback) override;
  void StartTorrent(const std::vector<uint8_t>& torrent_data,
                    const std::string& magnet_uri,
                    const base::FilePath& destination,
                    const std::vector<uint32_t>& selected_files,
                    mojom::TorrentOptionsPtr options,
#if BUILDFLAG(IS_MAC)
                    sandbox::SeatbeltExtensionToken destination_token,
#endif
                    StartTorrentCallback callback) override;
  void GetStatus(const std::string& task_id,
                 GetStatusCallback callback) override;
  void Pause(const std::string& task_id, PauseCallback callback) override;
  void Resume(const std::string& task_id, ResumeCallback callback) override;
  void Cancel(const std::string& task_id,
              bool delete_files,
              CancelCallback callback) override;

 private:
  struct State;

  void EnsureSession(const mojom::TorrentOptions& options);
  mojo::Receiver<mojom::AegisTorrentService> receiver_;
  std::unique_ptr<State> state_;
};

}  // namespace aegis::torrent

#endif  // CHROME_SERVICES_AEGIS_TORRENT_AEGIS_TORRENT_SERVICE_H_
