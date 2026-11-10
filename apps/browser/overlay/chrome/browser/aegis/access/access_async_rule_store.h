// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ASYNC_RULE_STORE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ASYNC_RULE_STORE_H_

#include <optional>
#include "base/functional/callback.h"
#include "base/threading/sequence_bound.h"
#include "chrome/browser/aegis/access/access_rule_store.h"

namespace aegis::access {
struct AsyncAccessStoreRestoration {
  StoreStatus status = StoreStatus::kIoError;
  std::optional<StoredPolicySnapshot> committed;
  std::optional<aegis_access::PublishedAccessPolicySnapshot> publication;
  size_t recovered_prepared = 0;
  std::string detail;
};
struct AsyncAccessStorePrepared {
  StoreStatus status = StoreStatus::kIoError;
  std::optional<StoredPolicySnapshot> previous;
  std::optional<PendingMutationRecord> pending;
  std::optional<StoredPolicySnapshot> candidate;
  std::string detail;
};
// Owns the SQLite store on one blocking sequenced runner for its entire
// lifetime. Callbacks return to the calling sequence with plain value data.
// Opening a Profile and reserving a restore publication never performs UI I/O.
class AccessAsyncRuleStore {
 public:
  explicit AccessAsyncRuleStore(AccessStoreBinding binding);
  ~AccessAsyncRuleStore();
  void InitializeAndRestore(std::string partition,
      base::OnceCallback<void(AsyncAccessStoreRestoration)> completion);
  void Prepare(SiteGroupMutationRequest request,
      base::OnceCallback<void(AsyncAccessStorePrepared)> completion);
  void Commit(PendingMutationRecord expected,
      base::OnceCallback<void(StoreResult<PendingMutationRecord>)> completion);
  void RecoverFailedMutation(PendingMutationRecord expected,
      base::OnceCallback<void(AsyncAccessStoreRestoration)> completion);
  void ReadCommitted(std::string partition,
      base::OnceCallback<void(StoreResult<StoredPolicySnapshot>)> completion);
  void SetFailurePointForTesting(AccessRuleStore::FailurePointForTesting point);
 private:
  class Worker;
  base::SequenceBound<Worker> worker_;
};
}  // namespace aegis::access
#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ASYNC_RULE_STORE_H_
