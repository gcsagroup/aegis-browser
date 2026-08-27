// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AEGIS_TORRENT_CLIENT_H_
#define CHROME_BROWSER_AEGIS_AEGIS_TORRENT_CLIENT_H_

#include <cstdint>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/no_destructor.h"
#include "chrome/services/aegis_torrent/public/mojom/aegis_torrent_service.mojom.h"
#include "mojo/public/cpp/bindings/remote.h"

namespace aegis {

// Browser-process owner for the sandboxed torrent service. Keeping the Remote
// outside chrome://aegis lets downloads continue when the settings tab closes.
class AegisTorrentClient {
 public:
  static AegisTorrentClient* GetInstance();

  AegisTorrentClient(const AegisTorrentClient&) = delete;
  AegisTorrentClient& operator=(const AegisTorrentClient&) = delete;

  void ValidateTorrent(
      std::vector<uint8_t> torrent_data,
      mojom::AegisTorrentService::ValidateTorrentCallback callback);
  void ValidateMagnet(
      std::string magnet_uri,
      mojom::AegisTorrentService::ValidateMagnetCallback callback);
  void StartTorrent(std::vector<uint8_t> torrent_data,
                    std::string magnet_uri,
                    const base::FilePath& destination,
                    std::vector<uint32_t> selected_files,
                    mojom::TorrentOptionsPtr options,
                    mojom::AegisTorrentService::StartTorrentCallback callback);
  void GetStatus(std::string task_id,
                 mojom::AegisTorrentService::GetStatusCallback callback);
  void Pause(std::string task_id,
             mojom::AegisTorrentService::PauseCallback callback);
  void Resume(std::string task_id,
              mojom::AegisTorrentService::ResumeCallback callback);
  void Cancel(std::string task_id,
              bool delete_files,
              mojom::AegisTorrentService::CancelCallback callback);

 private:
  friend class base::NoDestructor<AegisTorrentClient>;

  AegisTorrentClient();
  ~AegisTorrentClient();

  mojom::AegisTorrentService* GetRemote();

  mojo::Remote<mojom::AegisTorrentService> remote_;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_TORRENT_CLIENT_H_
