// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOCAL_CORE_MANAGER_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOCAL_CORE_MANAGER_H_

#include <optional>
#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/threading/sequence_bound.h"
#include "base/threading/thread.h"
#include "net/base/auth.h"

namespace aegis::access {
// Supplied by Browser's explicitly admitted DEV command-line binding. Neither
// a page nor the retry IPC supplies an executable, node, URL or credential.
struct AccessLocalCoreInput {
  base::FilePath manifest;
  base::FilePath node_config;
};
struct AccessLocalCoreReady {
  bool ready = false;
  uint16_t port = 0;
  std::string registration_id;
  std::optional<net::AuthCredentials> local_credentials;
  std::string error;
};

// One independently authenticated child per owning Browser service. File and
// process operations and the TLS canary run on a dedicated IO thread. Ready
// means a certificate-validated HTTPS 204 through the authenticated child, not
// merely a listening socket. NetworkContext publication must still be ACKed.
class AccessLocalCoreManager {
 public:
  explicit AccessLocalCoreManager(AccessLocalCoreInput input);
  ~AccessLocalCoreManager();
  AccessLocalCoreManager(const AccessLocalCoreManager&) = delete;
  AccessLocalCoreManager& operator=(const AccessLocalCoreManager&) = delete;

  void Prepare(base::OnceCallback<void(AccessLocalCoreReady)> completion);
  void Verify(base::OnceCallback<void(AccessLocalCoreReady)> completion);
  void Stop(base::OnceClosure completion);

 private:
  class Worker;
  std::unique_ptr<base::Thread> thread_;
  base::SequenceBound<Worker> worker_;
};
}  // namespace aegis::access
#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOCAL_CORE_MANAGER_H_
