// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_rule_store.h"

#include <array>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "components/aegis_access/access_route_planner.h"
#include "components/aegis_access/request_policy_context.h"
#include "sql/database.h"
#include "sql/meta_table.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis::access {

using aegis_access::BrowserOwnedRequestMetadata;
using aegis_access::CanonicalizeBrowserOwnedRequest;
using aegis_access::EvaluateAccessPolicy;
using aegis_access::GenerationTuple;
using aegis_access::GroupSelection;
using aegis_access::ManagedRestriction;
using aegis_access::PlanAccessRoute;
using aegis_access::PolicyMatchReason;
using aegis_access::PolicyMatchResult;
using aegis_access::PolicyState;
using aegis_access::ProtectionRestriction;
using aegis_access::ProxyRuntimeState;
using aegis_access::PublishedAccessPolicySnapshot;
using aegis_access::RegisteredProxyEntry;
using aegis_access::RequestAttributionKind;
using aegis_access::RequestContextError;
using aegis_access::RequestPolicyContext;
using aegis_access::RequestPolicyContextResult;
using aegis_access::RouteAction;
using aegis_access::RouteInput;
using aegis_access::RoutePlan;
using aegis_access::RulePortSelector;
using aegis_access::SnapshotState;

class AccessRuleStoreTestPeer {
 public:
  static AccessStoreBinding Persistent(
      const base::FilePath& profile_path,
      ChannelNamespace channel = ChannelNamespace::kBeta,
      std::string durable_profile_id = "durable-profile-A",
      std::string runtime_profile_token = "profile-A") {
    return AccessStoreBinding(AccessStoreKind::kPersistentProfile, channel,
                              std::move(durable_profile_id),
                              std::move(runtime_profile_token), profile_path,
                              profile_path.AppendASCII("access.db"));
  }

  static AccessStoreBinding Ephemeral(
      ChannelNamespace channel = ChannelNamespace::kBeta,
      std::string durable_profile_id = "ephemeral-A",
      std::string runtime_profile_token = "ephemeral-A") {
    return AccessStoreBinding(AccessStoreKind::kEphemeralProfile, channel,
                              std::move(durable_profile_id),
                              std::move(runtime_profile_token), {}, {});
  }

  static AccessStoreBinding System() {
    return AccessStoreBinding(AccessStoreKind::kSystemProfile,
                              ChannelNamespace::kBeta, "system", "system", {},
                              {});
  }

  static AccessStoreBinding WithDatabasePath(
      const base::FilePath& profile_path,
      const base::FilePath& database_path) {
    return AccessStoreBinding(AccessStoreKind::kPersistentProfile,
                              ChannelNamespace::kBeta, "durable-profile-A",
                              "profile-A", profile_path, database_path);
  }

  static StoreStatus Import(AccessRuleStore* store,
                            const StoredAccessRule& rule) {
    return store->ImportIndependentRuleForTesting(rule);
  }

  static bool Sql(AccessRuleStore* store, const std::string& sql) {
    return store->ExecuteSqlForTesting(sql);
  }

  static void FailAt(AccessRuleStore* store,
                     AccessRuleStore::FailurePointForTesting point) {
    store->SetFailurePointForTesting(point);
  }

  static void Close(AccessRuleStore* store) { store->CloseForTesting(); }
};

namespace {

OwnershipKey Owner(ChannelNamespace channel = ChannelNamespace::kBeta,
                   std::string profile = "profile-A",
                   std::string partition = "partition-A") {
  return {channel, std::move(profile), std::move(partition)};
}

std::vector<RequestScheme> AllSchemes() {
  return {RequestScheme::kHttp, RequestScheme::kHttps, RequestScheme::kWs,
          RequestScheme::kWss};
}

SiteGroupMutationRequest Mutation(std::string operation_id,
                                  AccessMode mode,
                                  uint64_t expected_revision = 0,
                                  OwnershipKey owner = Owner(),
                                  std::string host = "news.example") {
  const std::string http_site = "http://" + host;
  const std::string https_site = "https://" + host;
  const std::string toggle = "toggle-" + host;
  const std::string proxy = mode == AccessMode::kProxy ? "proxy-profile-A" : "";
  SiteGroupMutationRequest request;
  request.operation_id = std::move(operation_id);
  request.request_fingerprint = "fingerprint-" + request.operation_id;
  request.expected_revision = expected_revision;
  request.candidate_group = {
      .site_toggle_id = toggle,
      .canonical_host = host,
      .owner = owner,
      .http_top_level_site = http_site,
      .https_top_level_site = https_site,
      .member_rule_ids = {toggle + ":http", toggle + ":https"},
  };
  request.candidate_members = {
      SiteProxyRuleMember{
          .rule_id = toggle + ":http",
          .owner = owner,
          .site_toggle_id = toggle,
          .top_level_site = http_site,
          .exact_host = host,
          .schemes = AllSchemes(),
          .ports = PortScope::kAllBrowserPermitted,
          .mode = mode,
          .proxy_group_id = proxy,
          .protection_override = ProtectionOverride::kNone,
      },
      SiteProxyRuleMember{
          .rule_id = toggle + ":https",
          .owner = owner,
          .site_toggle_id = toggle,
          .top_level_site = https_site,
          .exact_host = host,
          .schemes = AllSchemes(),
          .ports = PortScope::kAllBrowserPermitted,
          .mode = mode,
          .proxy_group_id = proxy,
          .protection_override = ProtectionOverride::kNone,
      },
  };
  return request;
}

PendingMutationRecord Prepare(AccessRuleStore* store,
                              const SiteGroupMutationRequest& request) {
  StoreResult<PendingMutationRecord> result =
      store->PrepareSiteGroupMutation(request);
  EXPECT_EQ(result.status, StoreStatus::kValid) << result.detail;
  EXPECT_TRUE(result.value.has_value());
  return result.value.value_or(PendingMutationRecord{});
}

PendingMutationRecord Commit(AccessRuleStore* store,
                             const PendingMutationRecord& pending,
                             uint64_t generation) {
  StoreResult<PendingMutationRecord> result =
      store->CommitPreparedMutation(pending, generation);
  EXPECT_EQ(result.status, StoreStatus::kValid) << result.detail;
  EXPECT_TRUE(result.value.has_value());
  return result.value.value_or(PendingMutationRecord{});
}

const StoredSiteGroup* FindGroup(const StoredPolicySnapshot& snapshot,
                                 const std::string& host) {
  for (const StoredSiteGroup& group : snapshot.site_groups) {
    if (group.group.canonical_host == host) {
      return &group;
    }
  }
  return nullptr;
}

GroupSelection Selection(const StoredSiteGroup& group) {
  std::vector<SiteProxyRuleMember> members;
  for (const StoredAccessRule& rule : group.members) {
    members.push_back({
        rule.policy.rule_id,
        rule.policy.owner,
        rule.site_toggle_id,
        rule.site_toggle_revision,
        rule.policy.top_level_site,
        rule.policy.destination_host,
        rule.policy.schemes,
        rule.policy.ports.scope,
        rule.policy.include_subdomains,
        rule.policy.mode,
        rule.policy.proxy_group_id,
        rule.policy.protection_override,
        rule.policy.last_operation_sequence,
    });
  }
  return ValidateSiteProxyRuleGroup(group.group.owner, &group.group, members)
      .selection;
}

StoredAccessRule IndependentRule(std::string id,
                                 AccessMode mode,
                                 std::string host,
                                 std::string top_site,
                                 std::vector<RequestScheme> schemes,
                                 RulePortSelector ports,
                                 uint64_t revision) {
  StoredAccessRule rule;
  rule.policy = {
      .rule_id = std::move(id),
      .owner = Owner(),
      .scope = PolicyScope::kSite,
      .top_level_site = std::move(top_site),
      .destination_host = std::move(host),
      .include_subdomains = false,
      .schemes = std::move(schemes),
      .ports = std::move(ports),
      .mode = mode,
      .proxy_group_id = mode == AccessMode::kProxy ? "independent-proxy" : "",
      .protection_override = ProtectionOverride::kNone,
      .row_revision = revision,
      .last_operation_sequence = revision,
  };
  rule.source = StoredRuleSource::kTestFixture;
  rule.lifetime = StoredRuleLifetime::kPersistent;
  return rule;
}

StoredPolicySnapshot StoredSnapshotForAdapter(
    uint64_t group_generation = 7,
    uint64_t snapshot_generation = 7) {
  SiteGroupMutationRequest request = Mutation("adapter", AccessMode::kProxy);
  StoredSiteGroup stored_group;
  stored_group.group = request.candidate_group;
  stored_group.group.revision = 1;
  stored_group.group.last_operation_sequence = 1;
  stored_group.policy_generation = group_generation;
  for (const SiteProxyRuleMember& member : request.candidate_members) {
    StoredAccessRule rule;
    rule.policy = {
        .rule_id = member.rule_id,
        .owner = member.owner,
        .scope = PolicyScope::kSite,
        .top_level_site = member.top_level_site,
        .destination_host = member.exact_host,
        .include_subdomains = member.include_subdomains,
        .schemes = member.schemes,
        .ports = {member.ports, {}},
        .mode = member.mode,
        .proxy_group_id = member.proxy_group_id,
        .protection_override = member.protection_override,
        .row_revision = 1,
        .last_operation_sequence = 1,
    };
    rule.site_toggle_id = request.candidate_group.site_toggle_id;
    rule.site_toggle_revision = 1;
    rule.source = StoredRuleSource::kUserAction;
    rule.lifetime = StoredRuleLifetime::kPersistent;
    stored_group.members.push_back(std::move(rule));
  }
  return {
      .owner = Owner(),
      .policy_generation = snapshot_generation,
      .site_groups = {std::move(stored_group)},
  };
}

TEST(AccessRuleStoreTest, RejectsSystemAndUntrustedPersistentPaths) {
  AccessRuleStore system(AccessRuleStoreTestPeer::System());
  EXPECT_EQ(system.Open(), StoreStatus::kInvalidArgument);

  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  AccessRuleStore wrong_name(AccessRuleStoreTestPeer::WithDatabasePath(
      temp.GetPath(), temp.GetPath().AppendASCII("other.db")));
  EXPECT_EQ(wrong_name.Open(), StoreStatus::kInvalidArgument);

  const base::FilePath relative(FILE_PATH_LITERAL("relative-profile"));
  AccessRuleStore relative_path(AccessRuleStoreTestPeer::WithDatabasePath(
      relative, relative.AppendASCII("access.db")));
  EXPECT_EQ(relative_path.Open(), StoreStatus::kInvalidArgument);
}

TEST(AccessRuleStoreTest, EmptyPersistentDatabaseIsMissingAndOwnerBound) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  const AccessStoreBinding binding =
      AccessRuleStoreTestPeer::Persistent(temp.GetPath());
  {
    AccessRuleStore store(binding);
    ASSERT_EQ(store.Open(), StoreStatus::kValid);
    StoreResult<StoredPolicySnapshot> empty =
        store.ReadCommittedSnapshot("partition-A");
    EXPECT_EQ(empty.status, StoreStatus::kMissing);
    ASSERT_TRUE(empty.value);
    EXPECT_EQ(empty.value->owner, Owner());
  }
  EXPECT_TRUE(base::PathExists(temp.GetPath().AppendASCII("access.db")));

  AccessRuleStore wrong_owner(AccessRuleStoreTestPeer::Persistent(
      temp.GetPath(), ChannelNamespace::kBeta, "durable-profile-B",
      "profile-B"));
  EXPECT_EQ(wrong_owner.Open(), StoreStatus::kConflict);
}

TEST(AccessRuleStoreTest, ReopenRebindsStoredRowsToCurrentRuntimeOwner) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  const AccessStoreBinding old_binding = AccessRuleStoreTestPeer::Persistent(
      temp.GetPath(), ChannelNamespace::kBeta, "durable-profile-A",
      "runtime-old");
  {
    AccessRuleStore store(old_binding);
    ASSERT_EQ(store.Open(), StoreStatus::kValid);
    Commit(&store,
           Prepare(&store,
                   Mutation("old-runtime", AccessMode::kProxy, 0,
                            Owner(ChannelNamespace::kBeta, "runtime-old"))),
           1);
  }

  const AccessStoreBinding new_binding = AccessRuleStoreTestPeer::Persistent(
      temp.GetPath(), ChannelNamespace::kBeta, "durable-profile-A",
      "runtime-new");
  AccessRuleStore reopened(new_binding);
  ASSERT_EQ(reopened.Open(), StoreStatus::kValid);
  StoreResult<StoredPolicySnapshot> stored =
      reopened.ReadCommittedSnapshot("partition-A");
  ASSERT_EQ(stored.status, StoreStatus::kValid) << stored.detail;
  ASSERT_TRUE(stored.value);
  const OwnershipKey new_owner = Owner(ChannelNamespace::kBeta, "runtime-new");
  EXPECT_EQ(stored.value->owner, new_owner);
  ASSERT_EQ(stored.value->site_groups.size(), 1u);
  EXPECT_EQ(stored.value->site_groups[0].group.owner, new_owner);
  for (const StoredAccessRule& rule : stored.value->site_groups[0].members) {
    EXPECT_EQ(rule.policy.owner, new_owner);
  }
  StoreResult<MatcherRuleSetCandidate> candidate =
      AccessRuleStore::AdaptMatcherSnapshot(*stored.value);
  ASSERT_EQ(candidate.status, StoreStatus::kValid) << candidate.detail;
  ASSERT_TRUE(candidate.value);
  PublishedAccessPolicySnapshot published{
      candidate.value->owner, candidate.value->committed_policy_generation,
      candidate.value->rules};

  BrowserOwnedRequestMetadata new_metadata{
      "new-request",
      new_owner,
      RequestAttributionKind::kDocument,
      "new-document",
      {},
      net::SchemefulSite(GURL("https://news.example/"))};
  RequestPolicyContextResult new_context = CanonicalizeBrowserOwnedRequest(
      new_metadata, GURL("https://news.example/"));
  ASSERT_TRUE(new_context.context);
  EXPECT_EQ(EvaluateAccessPolicy(*new_context.context, published).policy_state,
            PolicyState::kValid);

  BrowserOwnedRequestMetadata old_metadata{
      "old-request",
      Owner(ChannelNamespace::kBeta, "runtime-old"),
      RequestAttributionKind::kDocument,
      "old-document",
      {},
      net::SchemefulSite(GURL("https://news.example/"))};
  RequestPolicyContextResult old_context = CanonicalizeBrowserOwnedRequest(
      old_metadata, GURL("https://news.example/"));
  ASSERT_TRUE(old_context.context);
  PolicyMatchResult rejected =
      EvaluateAccessPolicy(*old_context.context, published);
  EXPECT_EQ(rejected.policy_state, PolicyState::kInvalid);
  EXPECT_EQ(rejected.reason, PolicyMatchReason::kOwnershipMismatch);
}

TEST(AccessRuleStoreTest, EphemeralProfileNeverCreatesAccessDb) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral());
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  EXPECT_EQ(store.ReadCommittedSnapshot("partition-A").status,
            StoreStatus::kMissing);
  PendingMutationRecord pending =
      Prepare(&store, Mutation("ephemeral-enable", AccessMode::kProxy, 0,
                               Owner(ChannelNamespace::kBeta, "ephemeral-A")));
  Commit(&store, pending, 1);
  EXPECT_TRUE(store.binding().database_path().empty());
  EXPECT_TRUE(store.binding().profile_path().empty());
}

TEST(AccessRuleStoreTest, PrepareIsDurableButDoesNotReplaceCommittedRows) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  const AccessStoreBinding binding =
      AccessRuleStoreTestPeer::Persistent(temp.GetPath());
  PendingMutationRecord pending;
  {
    AccessRuleStore store(binding);
    ASSERT_EQ(store.Open(), StoreStatus::kValid);
    pending = Prepare(&store, Mutation("enable", AccessMode::kProxy));
    EXPECT_EQ(pending.operation_sequence, 1u);
    EXPECT_EQ(pending.committed_policy_generation, 0u);
    EXPECT_EQ(pending.candidate.policy_generation, 0u);
    EXPECT_EQ(store.ReadCommittedSnapshot("partition-A").status,
              StoreStatus::kRecoveryRequired);
  }
  AccessRuleStore reopened(binding);
  ASSERT_EQ(reopened.Open(), StoreStatus::kValid);
  StoreResult<RecoveryState> recovery = reopened.LoadRecoveryState();
  ASSERT_EQ(recovery.status, StoreStatus::kRecoveryRequired);
  ASSERT_TRUE(recovery.value);
  ASSERT_EQ(recovery.value->pending.size(), 1u);
  EXPECT_EQ(recovery.value->pending[0], pending);
  ASSERT_EQ(reopened.SupersedePreparedMutation(pending.operation_id,
                                               pending.request_fingerprint),
            StoreStatus::kValid);
  EXPECT_EQ(reopened.ReadCommittedSnapshot("partition-A").status,
            StoreStatus::kMissing);
}

TEST(AccessRuleStoreTest, CommitReopensAsCompleteNewVersion) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  const AccessStoreBinding binding =
      AccessRuleStoreTestPeer::Persistent(temp.GetPath());
  {
    AccessRuleStore store(binding);
    ASSERT_EQ(store.Open(), StoreStatus::kValid);
    PendingMutationRecord pending =
        Prepare(&store, Mutation("enable", AccessMode::kProxy));
    PendingMutationRecord committed = Commit(&store, pending, 7);
    EXPECT_EQ(committed.phase, MutationPhase::kCommitted);
    EXPECT_EQ(committed.committed_policy_generation, 7u);
  }
  AccessRuleStore reopened(binding);
  ASSERT_EQ(reopened.Open(), StoreStatus::kValid);
  StoreResult<StoredPolicySnapshot> snapshot =
      reopened.ReadCommittedSnapshot("partition-A");
  ASSERT_EQ(snapshot.status, StoreStatus::kValid) << snapshot.detail;
  ASSERT_TRUE(snapshot.value);
  ASSERT_EQ(snapshot.value->site_groups.size(), 1u);
  EXPECT_EQ(snapshot.value->policy_generation, 7u);
  EXPECT_EQ(Selection(snapshot.value->site_groups[0]),
            GroupSelection::kEnabled);
  EXPECT_EQ(reopened.LoadRecoveryState().status, StoreStatus::kValid);
}

TEST(AccessRuleStoreTest, EveryPrepareBoundaryRollsBackOnReopen) {
  constexpr std::array points = {
      AccessRuleStore::FailurePointForTesting::kPrepareAfterRetentionCleanup,
      AccessRuleStore::FailurePointForTesting::kPrepareAfterCounterUpdate,
      AccessRuleStore::FailurePointForTesting::kPrepareBeforeJournalInsert,
      AccessRuleStore::FailurePointForTesting::kPrepareAfterJournalInsert,
  };
  for (size_t i = 0; i < points.size(); ++i) {
    SCOPED_TRACE(i);
    base::ScopedTempDir temp;
    ASSERT_TRUE(temp.CreateUniqueTempDir());
    const AccessStoreBinding binding =
        AccessRuleStoreTestPeer::Persistent(temp.GetPath());
    {
      AccessRuleStore store(binding);
      ASSERT_EQ(store.Open(), StoreStatus::kValid);
      AccessRuleStoreTestPeer::FailAt(&store, points[i]);
      EXPECT_EQ(store
                    .PrepareSiteGroupMutation(
                        Mutation("prepare-failure", AccessMode::kProxy))
                    .status,
                StoreStatus::kIoError);
    }
    AccessRuleStore reopened(binding);
    ASSERT_EQ(reopened.Open(), StoreStatus::kValid);
    EXPECT_EQ(reopened.LoadRecoveryState().status, StoreStatus::kValid);
    EXPECT_EQ(reopened.ReadCommittedSnapshot("partition-A").status,
              StoreStatus::kMissing);
    EXPECT_EQ(Prepare(&reopened, Mutation("after-rollback", AccessMode::kProxy))
                  .operation_sequence,
              1u);
  }
}

TEST(AccessRuleStoreTest, EveryCommitBoundaryKeepsCompleteOldVersion) {
  constexpr std::array points = {
      AccessRuleStore::FailurePointForTesting::kCommitAfterRuleDelete,
      AccessRuleStore::FailurePointForTesting::kCommitAfterGroupDelete,
      AccessRuleStore::FailurePointForTesting::kCommitAfterGroupInsert,
      AccessRuleStore::FailurePointForTesting::kCommitAfterFirstMemberInsert,
      AccessRuleStore::FailurePointForTesting::kCommitBeforeJournalUpdate,
      AccessRuleStore::FailurePointForTesting::kCommitAfterJournalUpdate,
  };
  for (size_t i = 0; i < points.size(); ++i) {
    SCOPED_TRACE(i);
    base::ScopedTempDir temp;
    ASSERT_TRUE(temp.CreateUniqueTempDir());
    const AccessStoreBinding binding =
        AccessRuleStoreTestPeer::Persistent(temp.GetPath());
    PendingMutationRecord closing;
    {
      AccessRuleStore store(binding);
      ASSERT_EQ(store.Open(), StoreStatus::kValid);
      Commit(&store, Prepare(&store, Mutation("seed", AccessMode::kProxy)), 3);
      closing = Prepare(&store, Mutation("close", AccessMode::kDirect, 1));
      AccessRuleStoreTestPeer::FailAt(&store, points[i]);
      EXPECT_EQ(store.CommitPreparedMutation(closing, 4).status,
                StoreStatus::kIoError);
    }
    AccessRuleStore reopened(binding);
    ASSERT_EQ(reopened.Open(), StoreStatus::kValid);
    StoreResult<RecoveryState> recovery = reopened.LoadRecoveryState();
    ASSERT_EQ(recovery.status, StoreStatus::kRecoveryRequired);
    ASSERT_TRUE(recovery.value);
    ASSERT_EQ(recovery.value->pending.size(), 1u);
    ASSERT_EQ(reopened.SupersedePreparedMutation(closing.operation_id,
                                                 closing.request_fingerprint),
              StoreStatus::kValid);
    StoreResult<StoredPolicySnapshot> old =
        reopened.ReadCommittedSnapshot("partition-A");
    ASSERT_EQ(old.status, StoreStatus::kValid) << old.detail;
    ASSERT_TRUE(old.value);
    const StoredSiteGroup* group = FindGroup(*old.value, "news.example");
    ASSERT_NE(group, nullptr);
    EXPECT_EQ(group->members.size(), 2u);
    EXPECT_EQ(Selection(*group), GroupSelection::kEnabled);
    EXPECT_EQ(group->policy_generation, 3u);
  }
}

TEST(AccessRuleStoreTest, RevisionSequenceFingerprintAndGenerationAreBound) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  PendingMutationRecord pending =
      Prepare(&store, Mutation("bound", AccessMode::kProxy));

  PendingMutationRecord altered = pending;
  altered.request_fingerprint = "other";
  EXPECT_EQ(store.CommitPreparedMutation(altered, 1).status,
            StoreStatus::kConflict);
  EXPECT_EQ(store.CommitPreparedMutation(pending, 0).status,
            StoreStatus::kInvalidArgument);
  Commit(&store, pending, 5);

  EXPECT_EQ(
      store.PrepareSiteGroupMutation(Mutation("stale", AccessMode::kDirect, 0))
          .status,
      StoreStatus::kConflict);
  PendingMutationRecord next =
      Prepare(&store, Mutation("next", AccessMode::kDirect, 1));
  EXPECT_EQ(store.CommitPreparedMutation(next, 5).status,
            StoreStatus::kConflict);
  Commit(&store, next, 6);
}

TEST(AccessRuleStoreTest, CounterOverflowFailsWithoutJournal) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  ASSERT_TRUE(AccessRuleStoreTestPeer::Sql(
      &store,
      "UPDATE access_store_counters SET operation_sequence="
      "9223372036854775807 WHERE singleton=1"));
  EXPECT_EQ(
      store.PrepareSiteGroupMutation(Mutation("overflow", AccessMode::kProxy))
          .status,
      StoreStatus::kConflict);
  EXPECT_EQ(store.LoadRecoveryState().status, StoreStatus::kValid);
}

TEST(AccessRuleStoreTest, CanonicalizesUnsortedSchemesAndRejectsDuplicates) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  SiteGroupMutationRequest unsorted = Mutation("unsorted", AccessMode::kProxy);
  for (SiteProxyRuleMember& member : unsorted.candidate_members) {
    member.schemes = {RequestScheme::kWss, RequestScheme::kHttp,
                      RequestScheme::kWs, RequestScheme::kHttps};
  }
  PendingMutationRecord canonical = Prepare(&store, unsorted);
  for (const StoredAccessRule& member : canonical.candidate.members) {
    EXPECT_EQ(member.policy.schemes, AllSchemes());
  }
  ASSERT_EQ(store.SupersedePreparedMutation(canonical.operation_id,
                                            canonical.request_fingerprint),
            StoreStatus::kValid);

  SiteGroupMutationRequest duplicate =
      Mutation("duplicate", AccessMode::kProxy);
  duplicate.candidate_members[0].schemes = {
      RequestScheme::kHttp, RequestScheme::kHttps, RequestScheme::kWs,
      RequestScheme::kWs};
  EXPECT_EQ(store.PrepareSiteGroupMutation(duplicate).status,
            StoreStatus::kInvalidArgument);
}

TEST(AccessRuleStoreTest, AdapterRejectsInvalidAtomicSiteGroups) {
  auto expect_rejected = [](const StoredPolicySnapshot& snapshot) {
    StoreResult<MatcherRuleSetCandidate> result =
        AccessRuleStore::AdaptMatcherSnapshot(snapshot);
    EXPECT_EQ(result.status, StoreStatus::kCorrupt);
    EXPECT_FALSE(result.value.has_value());
  };

  StoredPolicySnapshot missing_member = StoredSnapshotForAdapter();
  missing_member.site_groups[0].members.pop_back();
  expect_rejected(missing_member);

  StoredPolicySnapshot mixed_mode = StoredSnapshotForAdapter();
  mixed_mode.site_groups[0].members[1].policy.mode = AccessMode::kDirect;
  mixed_mode.site_groups[0].members[1].policy.proxy_group_id.clear();
  expect_rejected(mixed_mode);

  StoredPolicySnapshot mixed_owner = StoredSnapshotForAdapter();
  mixed_owner.site_groups[0].members[1].policy.owner.profile_token =
      "other-runtime";
  expect_rejected(mixed_owner);

  StoredPolicySnapshot mixed_revision = StoredSnapshotForAdapter();
  mixed_revision.site_groups[0].members[1].site_toggle_revision = 2;
  mixed_revision.site_groups[0].members[1].policy.row_revision = 2;
  expect_rejected(mixed_revision);

  StoredPolicySnapshot mismatched_toggle = StoredSnapshotForAdapter();
  mismatched_toggle.site_groups[0].members[1].site_toggle_id = "other-toggle";
  expect_rejected(mismatched_toggle);
}

TEST(AccessRuleStoreTest, AdapterRejectsSnapshotGenerationMismatch) {
  StoredPolicySnapshot stale_group = StoredSnapshotForAdapter(7, 8);
  StoreResult<MatcherRuleSetCandidate> result =
      AccessRuleStore::AdaptMatcherSnapshot(stale_group);
  EXPECT_EQ(result.status, StoreStatus::kCorrupt);
  EXPECT_FALSE(result.value.has_value());

  StoredPolicySnapshot future_group = StoredSnapshotForAdapter(8, 7);
  result = AccessRuleStore::AdaptMatcherSnapshot(future_group);
  EXPECT_EQ(result.status, StoreStatus::kCorrupt);
  EXPECT_FALSE(result.value.has_value());
}

TEST(AccessRuleStoreTest, CompletionTimeNeverPrecedesCreatedTime) {
  constexpr int64_t kFutureMicros = std::numeric_limits<int64_t>::max() - 1000;
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);

  SiteGroupMutationRequest supersede_request =
      Mutation("future-supersede", AccessMode::kProxy);
  PendingMutationRecord supersede = Prepare(&store, supersede_request);
  ASSERT_TRUE(AccessRuleStoreTestPeer::Sql(
      &store, "UPDATE access_mutation_journal SET created_at_micros=" +
                  std::to_string(kFutureMicros) +
                  " WHERE operation_id='future-supersede'"));
  ASSERT_EQ(store.SupersedePreparedMutation(supersede.operation_id,
                                            supersede.request_fingerprint),
            StoreStatus::kValid);
  StoreResult<PendingMutationRecord> superseded =
      store.PrepareSiteGroupMutation(supersede_request);
  ASSERT_EQ(superseded.status, StoreStatus::kValid) << superseded.detail;
  ASSERT_TRUE(superseded.value);
  EXPECT_EQ(superseded.value->phase, MutationPhase::kSuperseded);
  EXPECT_EQ(superseded.value->created_at_micros, kFutureMicros);
  EXPECT_EQ(superseded.value->completed_at_micros, kFutureMicros);

  SiteGroupMutationRequest commit_request =
      Mutation("future-commit", AccessMode::kProxy);
  Prepare(&store, commit_request);
  ASSERT_TRUE(AccessRuleStoreTestPeer::Sql(
      &store, "UPDATE access_mutation_journal SET created_at_micros=" +
                  std::to_string(kFutureMicros) +
                  " WHERE operation_id='future-commit'"));
  StoreResult<RecoveryState> recovery = store.LoadRecoveryState();
  ASSERT_EQ(recovery.status, StoreStatus::kRecoveryRequired);
  ASSERT_TRUE(recovery.value);
  ASSERT_EQ(recovery.value->pending.size(), 1u);
  PendingMutationRecord committed =
      Commit(&store, recovery.value->pending[0], 1);
  EXPECT_EQ(committed.created_at_micros, kFutureMicros);
  EXPECT_EQ(committed.completed_at_micros, kFutureMicros);
  StoreResult<PendingMutationRecord> replay =
      store.PrepareSiteGroupMutation(commit_request);
  ASSERT_EQ(replay.status, StoreStatus::kValid) << replay.detail;
  ASSERT_TRUE(replay.value);
  EXPECT_EQ(replay.value->phase, MutationPhase::kCommitted);
  EXPECT_EQ(replay.value->completed_at_micros, kFutureMicros);
}

TEST(AccessRuleStoreTest, JournalRetentionNeverDeletesPreparedAndIsBounded) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  PendingMutationRecord completed = Commit(
      &store,
      Prepare(&store, Mutation("expired-completed", AccessMode::kProxy)), 1);
  ASSERT_TRUE(AccessRuleStoreTestPeer::Sql(
      &store,
      "UPDATE access_mutation_journal SET completed_at_micros=1 WHERE "
      "operation_id='expired-completed'"));
  SiteGroupMutationRequest reuse = Mutation(
      "expired-completed", AccessMode::kDirect, 0, Owner(), "fresh.example");
  reuse.request_fingerprint = "fresh-fingerprint";
  PendingMutationRecord fresh = Prepare(&store, reuse);
  EXPECT_GT(fresh.operation_sequence, completed.operation_sequence);

  ASSERT_TRUE(AccessRuleStoreTestPeer::Sql(
      &store,
      "UPDATE access_mutation_journal SET created_at_micros=1 WHERE "
      "operation_id='expired-completed'"));
  StoreResult<RecoveryState> retained = store.LoadRecoveryState();
  ASSERT_EQ(retained.status, StoreStatus::kRecoveryRequired);
  ASSERT_TRUE(retained.value);
  ASSERT_EQ(retained.value->pending.size(), 1u);
  EXPECT_EQ(retained.value->pending[0].operation_id, "expired-completed");

  AccessRuleStore bounded(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-bounded", "runtime-bounded"));
  ASSERT_EQ(bounded.Open(), StoreStatus::kValid);
  PendingMutationRecord first;
  for (size_t i = 0; i < 128; ++i) {
    const std::string suffix = std::to_string(i);
    SiteGroupMutationRequest request =
        Mutation("pending-" + suffix, AccessMode::kProxy, 0,
                 Owner(ChannelNamespace::kBeta, "runtime-bounded",
                       "partition-" + suffix),
                 "site-" + suffix + ".example");
    PendingMutationRecord pending = Prepare(&bounded, request);
    if (i == 0) {
      first = pending;
    }
  }
  SiteGroupMutationRequest overflow = Mutation(
      "capacity-overflow", AccessMode::kProxy, 0,
      Owner(ChannelNamespace::kBeta, "runtime-bounded", "partition-new"),
      "new.example");
  EXPECT_EQ(bounded.PrepareSiteGroupMutation(overflow).status,
            StoreStatus::kCapacity);
  ASSERT_EQ(bounded.SupersedePreparedMutation(first.operation_id,
                                              first.request_fingerprint),
            StoreStatus::kValid);
  ASSERT_TRUE(AccessRuleStoreTestPeer::Sql(
      &bounded,
      "UPDATE access_mutation_journal SET completed_at_micros=1 WHERE "
      "operation_id='pending-0'"));
  EXPECT_EQ(Prepare(&bounded, overflow).operation_sequence, 129u);
}

TEST(AccessRuleStoreTest, DetectsMissingOrphanMixedRevisionOwnerAndJournal) {
  struct Corruption {
    const char* sql;
    StoreStatus expected;
    bool journal;
  };
  constexpr Corruption corruptions[] = {
      {"DELETE FROM access_rules WHERE rule_id='toggle-news.example:http'",
       StoreStatus::kCorrupt, false},
      {"DELETE FROM access_site_groups", StoreStatus::kCorrupt, false},
      {"UPDATE access_rules SET mode=1 WHERE "
       "rule_id='toggle-news.example:http'",
       StoreStatus::kCorrupt, false},
      {"UPDATE access_rules SET site_toggle_revision=99 WHERE "
       "rule_id='toggle-news.example:http'",
       StoreStatus::kCorrupt, false},
      {"UPDATE access_rules SET durable_profile_id='profile-B' WHERE "
       "rule_id='toggle-news.example:http'",
       StoreStatus::kConflict, false},
      {"UPDATE access_mutation_journal SET after_image='broken' WHERE "
       "operation_id='pending'",
       StoreStatus::kCorrupt, true},
  };
  for (const Corruption& corruption : corruptions) {
    SCOPED_TRACE(corruption.sql);
    AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
        ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
    ASSERT_EQ(store.Open(), StoreStatus::kValid);
    Commit(&store, Prepare(&store, Mutation("seed", AccessMode::kProxy)), 1);
    if (corruption.journal) {
      Prepare(&store, Mutation("pending", AccessMode::kDirect, 1));
    }
    ASSERT_TRUE(AccessRuleStoreTestPeer::Sql(&store, corruption.sql));
    if (corruption.journal) {
      EXPECT_EQ(store.LoadRecoveryState().status, corruption.expected);
    } else {
      EXPECT_EQ(store.ReadCommittedSnapshot("partition-A").status,
                corruption.expected);
    }
  }
}

TEST(AccessRuleStoreTest, UnknownSchemaAndIoErrorsRemainDistinct) {
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  const base::FilePath database_path = temp.GetPath().AppendASCII("access.db");
  {
    sql::Database database("AegisAccess");
    ASSERT_TRUE(database.Open(database_path));
    sql::MetaTable meta;
    ASSERT_TRUE(meta.Init(&database, 99, 99));
  }
  AccessRuleStore incompatible(
      AccessRuleStoreTestPeer::Persistent(temp.GetPath()));
  EXPECT_EQ(incompatible.Open(), StoreStatus::kIncompatible);

  base::ScopedTempDir meta_only_dir;
  ASSERT_TRUE(meta_only_dir.CreateUniqueTempDir());
  {
    sql::Database database("AegisAccess");
    ASSERT_TRUE(
        database.Open(meta_only_dir.GetPath().AppendASCII("access.db")));
    sql::MetaTable meta;
    ASSERT_TRUE(meta.Init(&database, 1, 1));
  }
  AccessRuleStore meta_only(
      AccessRuleStoreTestPeer::Persistent(meta_only_dir.GetPath()));
  EXPECT_EQ(meta_only.Open(), StoreStatus::kCorrupt);

  base::ScopedTempDir file_parent;
  ASSERT_TRUE(file_parent.CreateUniqueTempDir());
  const base::FilePath not_directory =
      file_parent.GetPath().AppendASCII("profile-file");
  ASSERT_TRUE(base::WriteFile(not_directory, "not a directory"));
  AccessRuleStore io_error(AccessRuleStoreTestPeer::Persistent(not_directory));
  EXPECT_EQ(io_error.Open(), StoreStatus::kIoError);
}

TEST(AccessRuleStoreTest, IsolatesProfilesPartitionsAndAllChannels) {
  constexpr std::array channels = {
      ChannelNamespace::kDev, ChannelNamespace::kAlpha, ChannelNamespace::kBeta,
      ChannelNamespace::kRelease};
  base::ScopedTempDir root;
  ASSERT_TRUE(root.CreateUniqueTempDir());
  for (size_t i = 0; i < channels.size(); ++i) {
    const std::string profile = "profile-" + std::to_string(i);
    const base::FilePath path =
        root.GetPath().AppendASCII("channel-" + std::to_string(i));
    ASSERT_TRUE(base::CreateDirectory(path));
    AccessRuleStore store(AccessRuleStoreTestPeer::Persistent(
        path, channels[i], "durable-" + profile, profile));
    ASSERT_EQ(store.Open(), StoreStatus::kValid);
    Commit(
        &store,
        Prepare(&store, Mutation("partition-A-op", AccessMode::kProxy, 0,
                                 Owner(channels[i], profile, "partition-A"))),
        10 + i * 2);
    EXPECT_EQ(store.ReadCommittedSnapshot("partition-A").status,
              StoreStatus::kValid);
    EXPECT_EQ(store.ReadCommittedSnapshot("partition-B").status,
              StoreStatus::kMissing);
    Commit(&store,
           Prepare(&store, Mutation("partition-B-op", AccessMode::kDirect, 0,
                                    Owner(channels[i], profile, "partition-B"),
                                    "other.example")),
           11 + i * 2);
    EXPECT_EQ(store.ReadCommittedSnapshot("partition-B").status,
              StoreStatus::kValid);
  }

  const base::FilePath profile_a = root.GetPath().AppendASCII("profile-a");
  const base::FilePath profile_b = root.GetPath().AppendASCII("profile-b");
  ASSERT_TRUE(base::CreateDirectory(profile_a));
  ASSERT_TRUE(base::CreateDirectory(profile_b));
  AccessRuleStore first(AccessRuleStoreTestPeer::Persistent(
      profile_a, ChannelNamespace::kBeta, "durable-first", "first"));
  AccessRuleStore second(AccessRuleStoreTestPeer::Persistent(
      profile_b, ChannelNamespace::kBeta, "durable-second", "second"));
  ASSERT_EQ(first.Open(), StoreStatus::kValid);
  ASSERT_EQ(second.Open(), StoreStatus::kValid);
  Commit(&first,
         Prepare(&first, Mutation("first-only", AccessMode::kProxy, 0,
                                  Owner(ChannelNamespace::kBeta, "first"))),
         1);
  EXPECT_EQ(second.ReadCommittedSnapshot("partition-A").status,
            StoreStatus::kMissing);
}

TEST(AccessRuleStoreTest, ClosingReplacesOnlyGroupOwnedRows) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  Commit(&store, Prepare(&store, Mutation("enable", AccessMode::kProxy)), 1);

  StoredAccessRule reject = IndependentRule(
      "independent-reject", AccessMode::kReject, "cdn.news.example",
      "https://news.example", {RequestScheme::kHttps},
      {PortScope::kExplicitSubset, {443}}, 51);
  StoredAccessRule proxy = IndependentRule(
      "independent-proxy", AccessMode::kProxy, "api.news.example",
      "https://news.example", {RequestScheme::kHttps, RequestScheme::kWss},
      {PortScope::kExplicitSubset, {443, 8443}}, 53);
  ASSERT_EQ(AccessRuleStoreTestPeer::Import(&store, reject),
            StoreStatus::kValid);
  ASSERT_EQ(AccessRuleStoreTestPeer::Import(&store, proxy),
            StoreStatus::kValid);

  Commit(&store, Prepare(&store, Mutation("close", AccessMode::kDirect, 1)), 2);
  StoreResult<StoredPolicySnapshot> snapshot =
      store.ReadCommittedSnapshot("partition-A");
  ASSERT_EQ(snapshot.status, StoreStatus::kValid) << snapshot.detail;
  ASSERT_TRUE(snapshot.value);
  ASSERT_EQ(snapshot.value->site_groups.size(), 1u);
  EXPECT_EQ(Selection(snapshot.value->site_groups[0]),
            GroupSelection::kDisabled);
  ASSERT_EQ(snapshot.value->independent_rules.size(), 2u);
  EXPECT_EQ(snapshot.value->independent_rules[0].policy.mode,
            AccessMode::kProxy);
  EXPECT_EQ(snapshot.value->independent_rules[1].policy.mode,
            AccessMode::kReject);
  EXPECT_EQ(snapshot.value->independent_rules[0].policy.ports.explicit_ports,
            (std::vector<uint16_t>{443, 8443}));
}

RequestPolicyContext Context(const GURL& top, const GURL& request) {
  BrowserOwnedRequestMetadata metadata{
      "request",  Owner(), RequestAttributionKind::kDocument,
      "document", {},      net::SchemefulSite(top)};
  RequestPolicyContextResult result =
      CanonicalizeBrowserOwnedRequest(metadata, request);
  EXPECT_EQ(result.error, RequestContextError::kNone);
  return std::move(*result.context);
}

TEST(AccessRuleStoreTest, StoredSnapshotFeedsRealMatcherAndPlanner) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  Commit(&store, Prepare(&store, Mutation("enable", AccessMode::kProxy)), 31);
  StoreResult<StoredPolicySnapshot> stored =
      store.ReadCommittedSnapshot("partition-A");
  ASSERT_EQ(stored.status, StoreStatus::kValid) << stored.detail;
  ASSERT_TRUE(stored.value);
  StoreResult<MatcherRuleSetCandidate> candidate =
      AccessRuleStore::AdaptMatcherSnapshot(*stored.value);
  ASSERT_EQ(candidate.status, StoreStatus::kValid) << candidate.detail;
  ASSERT_TRUE(candidate.value);

  // Publication is deliberately explicit in the fixture, separate from the
  // database read and validation adapter.
  PublishedAccessPolicySnapshot published{
      candidate.value->owner, candidate.value->committed_policy_generation,
      candidate.value->rules};
  const struct {
    const char* top;
    const char* request;
  } matching[] = {
      {"http://news.example/", "http://news.example/path"},
      {"https://news.example/", "https://news.example/path"},
      {"http://news.example/", "ws://news.example/socket"},
      {"https://news.example/", "wss://news.example/socket"},
      {"https://news.example/", "https://news.example:8443/path"},
  };
  for (const auto& test : matching) {
    SCOPED_TRACE(test.request);
    PolicyMatchResult match = EvaluateAccessPolicy(
        Context(GURL(test.top), GURL(test.request)), published);
    ASSERT_EQ(match.policy_state, PolicyState::kValid);
    ASSERT_EQ(match.effective_mode, AccessMode::kProxy);
    const GenerationTuple generations{31, 3, 5, 7, 11};
    RouteInput input{
        .policy_state = match.policy_state,
        .effective_mode = match.effective_mode,
        .policy_scope = match.policy_scope,
        .effective_proxy_group_id = match.effective_proxy_group_id,
        .require_proxy_intent = true,
        .site_ownership_reliable = true,
        .request_owner = Owner(),
        .snapshot_state = SnapshotState::kPublished,
        .snapshot_owner = Owner(),
        .request_generations = generations,
        .snapshot_generations = generations,
        .protection_restriction = ProtectionRestriction::kNone,
        .managed_restriction = ManagedRestriction::kNone,
        .runtime_state = ProxyRuntimeState::kReady,
        .registered_proxy_entry =
            RegisteredProxyEntry{"entry-profile-A", "proxy-profile-A", Owner(),
                                 generations},
    };
    RoutePlan plan = PlanAccessRoute(input);
    EXPECT_EQ(plan.action, RouteAction::kUseRegisteredProxy);
    ASSERT_TRUE(plan.registered_proxy_entry);
    EXPECT_EQ(plan.registered_proxy_entry->registration_id, "entry-profile-A");
  }

  const struct {
    const char* top;
    const char* request;
  } non_matching[] = {
      {"https://news.example/", "https://sub.news.example/"},
      {"https://news.example/", "https://cdn.example/"},
      {"https://other.example/", "https://news.example/"},
  };
  for (const auto& test : non_matching) {
    SCOPED_TRACE(test.request);
    PolicyMatchResult match = EvaluateAccessPolicy(
        Context(GURL(test.top), GURL(test.request)), published);
    EXPECT_EQ(match.policy_state, PolicyState::kAbsent);
    EXPECT_EQ(match.reason, PolicyMatchReason::kNoMatchingRule);
  }
}

TEST(AccessRuleStoreTest, UnsupportedIndependentFixtureShapeIsRejected) {
  AccessRuleStore store(AccessRuleStoreTestPeer::Ephemeral(
      ChannelNamespace::kBeta, "durable-profile-A", "profile-A"));
  ASSERT_EQ(store.Open(), StoreStatus::kValid);
  StoredAccessRule invalid = IndependentRule(
      "invalid", AccessMode::kProxy, "api.news.example", "https://news.example",
      {RequestScheme::kHttps}, {PortScope::kExplicitSubset, {8443}}, 1);
  invalid.source = StoredRuleSource::kUserEdit;
  EXPECT_EQ(AccessRuleStoreTestPeer::Import(&store, invalid),
            StoreStatus::kInvalidArgument);
  invalid.source = StoredRuleSource::kTestFixture;
  invalid.lifetime = StoredRuleLifetime::kUntil;
  invalid.expires_at_micros = 123456789;
  EXPECT_EQ(AccessRuleStoreTestPeer::Import(&store, invalid),
            StoreStatus::kInvalidArgument);
  invalid.lifetime = StoredRuleLifetime::kProfileSession;
  invalid.expires_at_micros = 0;
  EXPECT_EQ(AccessRuleStoreTestPeer::Import(&store, invalid),
            StoreStatus::kInvalidArgument);
}

}  // namespace
}  // namespace aegis::access
