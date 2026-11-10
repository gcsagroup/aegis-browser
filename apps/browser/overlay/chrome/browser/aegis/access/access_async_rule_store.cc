// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_async_rule_store.h"
#include <set>
#include "base/task/thread_pool.h"

namespace aegis::access {
class AccessAsyncRuleStore::Worker {
 public:
  explicit Worker(AccessStoreBinding binding) : store_(std::move(binding)) {}
  AsyncAccessStoreRestoration InitializeAndRestore(const std::string& partition) {
    if (initialized_.contains(partition))
      return {.status = StoreStatus::kConflict, .detail = "already_initialized"};
    if (!store_.is_open()) {
      const auto opened = store_.Open();
      if (opened != StoreStatus::kValid) return {.status = opened};
    }
    auto recovery = store_.LoadRecoveryState();
    if (!recovery.value) return {.status = recovery.status, .detail = recovery.detail};
    size_t count = 0;
    for (const auto& pending : recovery.value->pending) {
      if (pending.owner.storage_partition_token != partition) continue;
      const auto status = store_.SupersedePreparedMutation(
          pending.operation_id, pending.request_fingerprint);
      if (status != StoreStatus::kValid) return {.status = status};
      ++count;
    }
    auto restored = ReserveCommitted(partition);
    restored.recovered_prepared = count;
    if (restored.status == StoreStatus::kValid) initialized_.insert(partition);
    return restored;
  }
  AsyncAccessStorePrepared Prepare(const SiteGroupMutationRequest& request) {
    const auto& partition = request.candidate_group.owner.storage_partition_token;
    if (!initialized_.contains(partition))
      return {.status = StoreStatus::kMissing, .detail = "partition_not_initialized"};
    auto previous = store_.ReadCommittedSnapshot(partition);
    if (!previous.value || (previous.status != StoreStatus::kValid &&
                            previous.status != StoreStatus::kMissing))
      return {.status = previous.status, .detail = previous.detail};
    auto prepared = store_.PrepareSiteGroupMutation(request);
    AsyncAccessStorePrepared result{.status = prepared.status,
        .previous = std::move(previous.value), .pending = std::move(prepared.value),
        .detail = prepared.detail};
    if (!result.pending || result.pending->phase == MutationPhase::kCommitted)
      return result;
    if (result.pending->phase != MutationPhase::kPrepared) {
      result.status = StoreStatus::kConflict;
      return result;
    }
    auto built = store_.BuildPreparedCandidateSnapshot(*result.pending);
    result.status = built.status;
    result.candidate = std::move(built.value);
    result.detail = built.detail;
    return result;
  }
  StoreResult<PendingMutationRecord> Commit(const PendingMutationRecord& expected) {
    return store_.CommitPreparedMutation(expected);
  }
  AsyncAccessStoreRestoration RecoverFailedMutation(
      const PendingMutationRecord& expected) {
    const auto& partition = expected.owner.storage_partition_token;
    if (!initialized_.contains(partition) ||
        expected.owner.channel != store_.binding().channel() ||
        expected.owner.profile_token != store_.binding().runtime_profile_token())
      return {.status = StoreStatus::kConflict, .detail = "mutation_owner_mismatch"};
    const auto status = store_.SupersedePreparedMutation(expected.operation_id,
                                                        expected.request_fingerprint);
    if (status != StoreStatus::kValid) return {.status = status};
    return ReserveCommitted(partition);
  }
  StoreResult<StoredPolicySnapshot> ReadCommitted(const std::string& partition) {
    return store_.ReadCommittedSnapshot(partition);
  }
  void SetFailurePointForTesting(AccessRuleStore::FailurePointForTesting point) {
    store_.SetFailurePointForTesting(point);
  }
 private:
  AsyncAccessStoreRestoration ReserveCommitted(const std::string& partition) {
    auto publication = store_.ReserveCommittedPolicyForPublication(partition);
    if (!publication.value)
      return {.status = publication.status, .detail = publication.detail};
    auto committed = store_.ReadCommittedSnapshot(partition);
    if (!committed.value)
      return {.status = committed.status, .detail = committed.detail};
    return {.status = StoreStatus::kValid, .committed = std::move(committed.value),
            .publication = std::move(publication.value)};
  }
  AccessRuleStore store_;
  std::set<std::string> initialized_;
};
AccessAsyncRuleStore::AccessAsyncRuleStore(AccessStoreBinding binding)
    : worker_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN}), std::move(binding)) {}
AccessAsyncRuleStore::~AccessAsyncRuleStore() = default;
void AccessAsyncRuleStore::InitializeAndRestore(std::string partition,
    base::OnceCallback<void(AsyncAccessStoreRestoration)> completion) {
  worker_.AsyncCall(&Worker::InitializeAndRestore).WithArgs(std::move(partition))
      .Then(std::move(completion));
}
void AccessAsyncRuleStore::Prepare(SiteGroupMutationRequest request,
    base::OnceCallback<void(AsyncAccessStorePrepared)> completion) {
  worker_.AsyncCall(&Worker::Prepare).WithArgs(std::move(request))
      .Then(std::move(completion));
}
void AccessAsyncRuleStore::Commit(PendingMutationRecord expected,
    base::OnceCallback<void(StoreResult<PendingMutationRecord>)> completion) {
  worker_.AsyncCall(&Worker::Commit).WithArgs(std::move(expected))
      .Then(std::move(completion));
}
void AccessAsyncRuleStore::RecoverFailedMutation(PendingMutationRecord expected,
    base::OnceCallback<void(AsyncAccessStoreRestoration)> completion) {
  worker_.AsyncCall(&Worker::RecoverFailedMutation).WithArgs(std::move(expected))
      .Then(std::move(completion));
}
void AccessAsyncRuleStore::ReadCommitted(std::string partition,
    base::OnceCallback<void(StoreResult<StoredPolicySnapshot>)> completion) {
  worker_.AsyncCall(&Worker::ReadCommitted).WithArgs(std::move(partition))
      .Then(std::move(completion));
}
void AccessAsyncRuleStore::SetFailurePointForTesting(
    AccessRuleStore::FailurePointForTesting point) {
  worker_.AsyncCall(&Worker::SetFailurePointForTesting).WithArgs(point);
}
}  // namespace aegis::access
