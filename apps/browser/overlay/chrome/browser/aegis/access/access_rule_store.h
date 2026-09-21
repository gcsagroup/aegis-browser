// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_RULE_STORE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_RULE_STORE_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/sequence_checker.h"
#include "components/aegis_access/access_policy_evaluator.h"
#include "components/aegis_access/site_proxy_rule_group.h"
#include "sql/database.h"
#include "sql/meta_table.h"

namespace aegis::access {

using aegis_access::AccessMode;
using aegis_access::AccessPolicyRule;
using aegis_access::ChannelNamespace;
using aegis_access::GroupValidationError;
using aegis_access::OwnershipKey;
using aegis_access::PolicyScope;
using aegis_access::PortScope;
using aegis_access::ProtectionOverride;
using aegis_access::RequestScheme;
using aegis_access::SiteProxyRuleGroup;
using aegis_access::SiteProxyRuleMember;

// This binding is produced by a trusted native Profile/storage adapter. The
// durable owner id must be stable across BrowserContext incarnations; an
// in-process BrowserContext token is not a durable owner id.
enum class AccessStoreKind {
  kPersistentProfile,
  kEphemeralProfile,
  kSystemProfile,
};

class AccessStoreBinding {
 public:
  AccessStoreBinding(const AccessStoreBinding&);
  AccessStoreBinding(AccessStoreBinding&&);
  AccessStoreBinding& operator=(const AccessStoreBinding&);
  AccessStoreBinding& operator=(AccessStoreBinding&&);
  ~AccessStoreBinding();

  AccessStoreKind kind() const { return kind_; }
  ChannelNamespace channel() const { return channel_; }
  const std::string& durable_profile_id() const { return durable_profile_id_; }
  const std::string& runtime_profile_token() const {
    return runtime_profile_token_;
  }
  const base::FilePath& profile_path() const { return profile_path_; }
  const base::FilePath& database_path() const { return database_path_; }

  friend bool operator==(const AccessStoreBinding&,
                         const AccessStoreBinding&) = default;

 private:
  friend class TrustedAccessStoreBindingFactory;
  friend class AccessRuleStoreTestPeer;

  AccessStoreBinding(AccessStoreKind kind,
                     ChannelNamespace channel,
                     std::string durable_profile_id,
                     std::string runtime_profile_token,
                     base::FilePath profile_path,
                     base::FilePath database_path);

  AccessStoreKind kind_ = AccessStoreKind::kSystemProfile;
  ChannelNamespace channel_ = ChannelNamespace::kInvalid;
  std::string durable_profile_id_;
  std::string runtime_profile_token_;
  base::FilePath profile_path_;
  base::FilePath database_path_;
};

enum class StoreStatus {
  kMissing,
  kValid,
  kRecoveryRequired,
  kCorrupt,
  kIncompatible,
  kIoError,
  kConflict,
  kCapacity,
  kInvalidArgument,
};

template <typename T>
struct StoreResult {
  StoreStatus status = StoreStatus::kIoError;
  std::optional<T> value;
  std::string detail;

  friend bool operator==(const StoreResult&, const StoreResult&) = default;
};

enum class StoredRuleSource {
  kUserAction,
  kUserEdit,
  kRestored,
  kTestFixture,
  kInvalid,
};

enum class StoredRuleLifetime {
  kPersistent,
  kProfileSession,
  kUntil,
  kInvalid,
};

struct StoredAccessRule {
  AccessPolicyRule policy;
  std::string site_toggle_id;
  uint64_t site_toggle_revision = 0;
  StoredRuleSource source = StoredRuleSource::kInvalid;
  StoredRuleLifetime lifetime = StoredRuleLifetime::kInvalid;
  int64_t expires_at_micros = 0;
  std::string created_by_batch_id;

  friend bool operator==(const StoredAccessRule&,
                         const StoredAccessRule&) = default;
};

struct StoredSiteGroup {
  SiteProxyRuleGroup group;
  std::vector<StoredAccessRule> members;
  uint64_t policy_generation = 0;

  friend bool operator==(const StoredSiteGroup&,
                         const StoredSiteGroup&) = default;
};

// A database read is deliberately called "stored", never "published". A
// caller must separately publish/acknowledge it before a network consumer may
// treat it as authoritative.
struct StoredPolicySnapshot {
  OwnershipKey owner;
  uint64_t policy_generation = 0;
  std::vector<StoredSiteGroup> site_groups;
  std::vector<StoredAccessRule> independent_rules;

  friend bool operator==(const StoredPolicySnapshot&,
                         const StoredPolicySnapshot&) = default;
};

// A validated, non-authoritative matcher input candidate. The browser-side
// publisher must explicitly wrap these rules in its separately acknowledged
// PublishedAccessPolicySnapshot; database reads never perform that promotion.
struct MatcherRuleSetCandidate {
  OwnershipKey owner;
  uint64_t committed_policy_generation = 0;
  std::vector<AccessPolicyRule> rules;
};

enum class MutationPhase {
  kPrepared,
  kCommitted,
  kSuperseded,
  kInvalid,
};

struct SiteGroupMutationRequest {
  std::string operation_id;
  std::string request_fingerprint;
  uint64_t expected_revision = 0;
  SiteProxyRuleGroup candidate_group;
  std::vector<SiteProxyRuleMember> candidate_members;

  friend bool operator==(const SiteGroupMutationRequest&,
                         const SiteGroupMutationRequest&) = default;
};

struct PendingMutationRecord {
  MutationPhase phase = MutationPhase::kInvalid;
  std::string operation_id;
  std::string request_fingerprint;
  OwnershipKey owner;
  uint64_t expected_revision = 0;
  uint64_t target_revision = 0;
  uint64_t operation_sequence = 0;
  // Prepare reserves candidate.policy_generation from the durable operation
  // sequence. committed_policy_generation stays zero until that exact reserved
  // value is durably committed after publication/ACK.
  uint64_t committed_policy_generation = 0;
  int64_t created_at_micros = 0;
  int64_t completed_at_micros = 0;
  std::string before_image;
  std::string after_image;
  StoredSiteGroup candidate;

  friend bool operator==(const PendingMutationRecord&,
                         const PendingMutationRecord&) = default;
};

struct RecoveryState {
  std::vector<PendingMutationRecord> pending;

  friend bool operator==(const RecoveryState&, const RecoveryState&) = default;
};

class AccessRuleStore {
 public:
  // Faults occur before the named durable boundary. The surrounding SQL
  // transaction must roll back, so a reopen sees the complete old or new
  // committed snapshot and never a partial member pair.
  enum class FailurePointForTesting {
    kNone,
    kPrepareAfterRetentionCleanup,
    kPrepareAfterCounterUpdate,
    kPrepareBeforeJournalInsert,
    kPrepareAfterJournalInsert,
    kCommitAfterRuleDelete,
    kCommitAfterGroupDelete,
    kCommitAfterGroupInsert,
    kCommitAfterFirstMemberInsert,
    kCommitBeforeJournalUpdate,
    kCommitAfterJournalUpdate,
  };

  explicit AccessRuleStore(AccessStoreBinding binding);
  AccessRuleStore(const AccessRuleStore&) = delete;
  AccessRuleStore& operator=(const AccessRuleStore&) = delete;
  ~AccessRuleStore();

  StoreStatus Open();
  bool is_open() const { return is_open_; }
  const AccessStoreBinding& binding() const { return binding_; }

  StoreResult<StoredPolicySnapshot> ReadCommittedSnapshot(
      const std::string& storage_partition_token);
  StoreResult<PendingMutationRecord> PrepareSiteGroupMutation(
      const SiteGroupMutationRequest& request);
  // Builds the full in-memory candidate represented by one exact PREPARED
  // journal record without advancing durable state. Unrelated committed groups
  // and independent rules are preserved; only the candidate site group is
  // replaced at the reserved operation/policy generation.
  StoreResult<StoredPolicySnapshot> BuildPreparedCandidateSnapshot(
      const PendingMutationRecord& expected);
  StoreResult<PendingMutationRecord> CommitPreparedMutation(
      const PendingMutationRecord& expected);
  StoreStatus SupersedePreparedMutation(const std::string& operation_id,
                                        const std::string& fingerprint);
  StoreResult<RecoveryState> LoadRecoveryState();

  // Converts a fully validated stored snapshot into the existing matcher
  // input shape. The returned value is a candidate for a later publication;
  // this adapter itself performs no publication and grants no authority.
  static StoreResult<MatcherRuleSetCandidate> AdaptMatcherSnapshot(
      const StoredPolicySnapshot& stored);

 private:
  friend class AccessRuleStoreTestPeer;

  // Restricted friend-only fixture seam for persistence/matcher regressions.
  // It is intentionally unavailable to production callers.
  StoreStatus ImportIndependentRuleForTesting(const StoredAccessRule& rule);
  void SetFailurePointForTesting(FailurePointForTesting point) {
    DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
    failure_point_for_testing_ = point;
  }
  bool ExecuteSqlForTesting(const std::string& sql) {
    DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
    return database_.Execute(sql);
  }
  void CloseForTesting() {
    DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
    database_.Close();
    is_open_ = false;
    terminal_status_ = StoreStatus::kIoError;
  }
  StoreResult<StoredPolicySnapshot> ReadCommittedSnapshotInternal(
      const std::string& storage_partition_token,
      bool check_recovery);
  StoreResult<PendingMutationRecord> LoadMutation(
      const std::string& operation_id,
      bool prepared_only);
  bool IsBindingValid() const;
  bool ShouldFail(FailurePointForTesting point) const;

  AccessStoreBinding binding_;
  sql::Database database_;
  sql::MetaTable meta_table_;
  bool is_open_ = false;
  StoreStatus terminal_status_ = StoreStatus::kIoError;
  FailurePointForTesting failure_point_for_testing_ =
      FailurePointForTesting::kNone;
  SEQUENCE_CHECKER(sequence_checker_);
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_RULE_STORE_H_
