// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AEGIS_TORRENT_CLIENT_H_
#define CHROME_BROWSER_AEGIS_AEGIS_TORRENT_CLIENT_H_

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/no_destructor.h"
#include "chrome/services/aegis_torrent/public/mojom/aegis_torrent_service.mojom.h"
#include "mojo/public/cpp/bindings/remote.h"

namespace aegis {

// Browser-side ownership policy for torrent tasks. Owner identifiers are
// random, Profile-scoped session capabilities and are never sent to the
// sandboxed service.
class TorrentTaskRegistry {
 public:
  TorrentTaskRegistry();
  ~TorrentTaskRegistry();

  enum class StartDisposition {
    kDeliver,
    kCancel,
  };

  bool BeginStart(const std::string& owner_id);
  StartDisposition CompleteStart(const std::string& owner_id,
                                 bool ok,
                                 const std::string& task_id);
  std::vector<std::string> RevokeOwner(const std::string& owner_id);
  bool OwnsTask(const std::string& owner_id, const std::string& task_id) const;
  std::string CurrentTaskId(const std::string& owner_id) const;
  void ForgetTask(const std::string& owner_id, const std::string& task_id);

 private:
  struct OwnerState {
    bool accepting = true;
    size_t pending_starts = 0;
    std::string task_id;
  };

  std::map<std::string, OwnerState> owners_;
};

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
  void StartTorrent(const std::string& owner_id,
                    std::vector<uint8_t> torrent_data,
                    std::string magnet_uri,
                    const base::FilePath& destination,
                    std::vector<uint32_t> selected_files,
                    mojom::TorrentOptionsPtr options,
                    mojom::AegisTorrentService::StartTorrentCallback callback);
  void GetStatus(const std::string& owner_id,
                 std::string task_id,
                 mojom::AegisTorrentService::GetStatusCallback callback);
  void Pause(const std::string& owner_id,
             std::string task_id,
             mojom::AegisTorrentService::PauseCallback callback);
  void Resume(const std::string& owner_id,
              std::string task_id,
              mojom::AegisTorrentService::ResumeCallback callback);
  void Cancel(const std::string& owner_id,
              std::string task_id,
              bool delete_files,
              mojom::AegisTorrentService::CancelCallback callback);

  // Stops and forgets every transfer owned by a Profile session. Existing
  // bytes are retained unless the caller separately requested deletion.
  void RevokeOwnerTasks(const std::string& owner_id);
  std::string CurrentTaskId(const std::string& owner_id) const;

 private:
  friend class base::NoDestructor<AegisTorrentClient>;

  AegisTorrentClient();
  ~AegisTorrentClient();

  mojom::AegisTorrentService* GetRemote();
  void OnTorrentStarted(
      std::string owner_id,
      mojom::AegisTorrentService::StartTorrentCallback callback,
      bool ok,
      const std::string& error,
      const std::string& task_id);
  void OnTorrentStatus(std::string owner_id,
                       std::string task_id,
                       mojom::AegisTorrentService::GetStatusCallback callback,
                       mojom::TorrentStatusPtr status);
  void OnTorrentCancelled(std::string owner_id,
                          std::string task_id,
                          mojom::AegisTorrentService::CancelCallback callback,
                          bool ok);

  mojo::Remote<mojom::AegisTorrentService> remote_;
  TorrentTaskRegistry task_registry_;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_TORRENT_CLIENT_H_
