// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_local_core_manager.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/task/sequenced_task_runner.h"

namespace aegis::access {

std::optional<AccessLocalCoreInput> ResolveAccessLocalCoreInput() {
  return std::nullopt;
}

// Complete the private type for the empty SequenceBound. Unsupported builds
// create neither a worker thread nor a child process.
class AccessLocalCoreManager::Worker {};

AccessLocalCoreManager::AccessLocalCoreManager(AccessLocalCoreInput) {}
AccessLocalCoreManager::~AccessLocalCoreManager() = default;

void AccessLocalCoreManager::Prepare(
    base::OnceCallback<void(AccessLocalCoreReady)> completion) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(std::move(completion), AccessLocalCoreReady{
          .error = "The local proxy is unavailable on this platform."}));
}

void AccessLocalCoreManager::Verify(
    base::OnceCallback<void(AccessLocalCoreReady)> completion) {
  Prepare(std::move(completion));
}

void AccessLocalCoreManager::Stop(base::OnceClosure completion) {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, std::move(completion));
}

void AccessLocalCoreManager::StopAllForSessionEnding(base::OnceClosure completion) {
  std::move(completion).Run();
}

void AccessLocalCoreManager::SetStoppedCallback(
    base::RepeatingCallback<void(std::string)>) {}

}  // namespace aegis::access
