// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_SHARE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_SHARE_H_

#include <memory>
#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/weak_ptr.h"
#include "base/threading/sequence_bound.h"

namespace aegis::access {
// Write only inside a freshly created private directory owned by the caller.
bool WriteCoreLogArchive(const base::FilePath& directory,
                         const std::string& text);
inline constexpr char kCoreLogArchive[] = "Aegis-Access.log.gz";

// UI owns the operation. Its worker owns the temporary directory from the
// first write until cleanup; only a path, never file ownership, crosses to UI.
class CoreLogShareSession {
 public:
  using Ready =
      base::OnceCallback<void(base::FilePath, base::ScopedClosureRunner)>;
  CoreLogShareSession();
  ~CoreLogShareSession();
  void Start(std::string preview, Ready ready);
  void ShutDown();
  // Runs cleanup on writer sequences and completes without a UI reply. Also
  // includes writers whose UI owner is already awaiting asynchronous destruction.
  static void StopAllForSessionEnding(base::OnceClosure completion);
  void StartForTesting(std::string preview,
                       Ready ready,
                       scoped_refptr<base::SequencedTaskRunner> runner,
                       base::FilePath parent);

 private:
  class Writer;
  class ShutdownHandle;
  void StartOn(std::string preview,
               Ready ready,
               scoped_refptr<base::SequencedTaskRunner> runner,
               base::FilePath parent);
  void OnWritten(Ready ready, base::FilePath path);
  void Finish();

  bool shutting_down_ = false;
  std::shared_ptr<ShutdownHandle> shutdown_;
  base::SequenceBound<Writer> writer_;
  base::WeakPtrFactory<CoreLogShareSession> weak_{this};
};
}  // namespace aegis::access
#endif
