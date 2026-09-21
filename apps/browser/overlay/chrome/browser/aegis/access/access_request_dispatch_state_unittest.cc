// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_request_dispatch_state.h"

#include <memory>
#include <string>

#include "chrome/test/base/testing_profile.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessRequestDispatchStateTest : public testing::Test {
 protected:
  content::BrowserTaskEnvironment task_environment_;
};

class FlagTerminationHandle final
    : public aegis_access::RequestTerminationHandle {
 public:
  explicit FlagTerminationHandle(bool* terminated) : terminated_(terminated) {}
  ~FlagTerminationHandle() override = default;

  void Terminate() override { *terminated_ = true; }

 private:
  bool* terminated_;
};

aegis_access::RequestOwnershipRecord TestRecord() {
  return {
      "request-0136",
      {aegis_access::ChannelNamespace::kDev, "profile-0136", "partition-0136"},
      {1, 2, 3, 4, 5},
      "document-0136",
      "",
      true,
      "https://top.example",
      "target.example",
      aegis_access::RequestScheme::kHttps,
      443,
  };
}

aegis_access::RequestCancellationSelector SelectorFor(
    const aegis_access::RequestOwnershipRecord& record) {
  return {record.owner,
          record.document_token,
          record.pending_navigation_token,
          record.top_level_site,
          record.exact_host,
          record.scheme,
          record.port};
}

aegis_access::PolicyPublicationAckRequirements PublicationFor(
    const aegis_access::RequestOwnershipRecord& record,
    uint64_t operation_sequence,
    uint64_t policy_generation,
    const std::string& operation_id) {
  return {
      {operation_id,
       operation_sequence,
       policy_generation,
       0,
       record.generations.network_epoch,
       SelectorFor(record)},
      {"browser-runtime", "network-context"},
      true,
  };
}

TEST_F(AccessRequestDispatchStateTest, RejectsNullProfile) {
  EXPECT_EQ(AccessRequestDispatchState::Get(nullptr), nullptr);
  EXPECT_EQ(AccessRequestDispatchState::GetOrCreate(nullptr), nullptr);
}

TEST_F(AccessRequestDispatchStateTest, ProfileOwnsOneStableState) {
  auto profile = TestingProfile::Builder().Build();
  auto* first = AccessRequestDispatchState::GetOrCreate(profile.get());
  ASSERT_NE(first, nullptr);
  EXPECT_EQ(first, AccessRequestDispatchState::Get(profile.get()));
  EXPECT_EQ(first, AccessRequestDispatchState::GetOrCreate(profile.get()));
}

TEST_F(AccessRequestDispatchStateTest, ProfilesAreIsolated) {
  auto first_profile = TestingProfile::Builder().Build();
  auto second_profile = TestingProfile::Builder().Build();

  auto* first = AccessRequestDispatchState::GetOrCreate(first_profile.get());
  auto* second = AccessRequestDispatchState::GetOrCreate(second_profile.get());
  ASSERT_NE(first, nullptr);
  ASSERT_NE(second, nullptr);
  EXPECT_NE(first, second);
}

TEST_F(AccessRequestDispatchStateTest,
       BlockBarrierTerminatesMatchingDispatchedRequest) {
  auto profile = TestingProfile::Builder().Build();
  auto* state = AccessRequestDispatchState::GetOrCreate(profile.get());
  ASSERT_NE(state, nullptr);

  const aegis_access::RequestOwnershipRecord record = TestRecord();
  ASSERT_EQ(state->ownership().Register(record),
            aegis_access::RequestOwnershipStatus::kOk);
  bool terminated = false;
  ASSERT_EQ(state->ownership().MarkDispatched(
                record.request_id, record.owner, record.generations,
                std::make_unique<FlagTerminationHandle>(&terminated)),
            aegis_access::RequestOwnershipStatus::kOk);

  const AccessBlockAndCancelResult result =
      state->InstallBlockBarrierAndCancelMatching(
          {"block-0136", 1, SelectorFor(record)});
  EXPECT_EQ(result.barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kOk);
  EXPECT_EQ(result.cancellation_status,
            aegis_access::RequestOwnershipStatus::kOk);
  EXPECT_EQ(result.matched_requests, 1u);
  EXPECT_EQ(result.terminated_requests, 1u);
  EXPECT_TRUE(terminated);
  EXPECT_EQ(state->ownership().size(), 0u);
  EXPECT_EQ(state->barriers().EvaluateRequest(record).decision,
            aegis_access::RequestDispatchDecision::kBlock);
}

TEST_F(AccessRequestDispatchStateTest,
       InvalidBarrierDoesNotConsumeMatchingRequest) {
  auto profile = TestingProfile::Builder().Build();
  auto* state = AccessRequestDispatchState::GetOrCreate(profile.get());
  ASSERT_NE(state, nullptr);

  const aegis_access::RequestOwnershipRecord record = TestRecord();
  ASSERT_EQ(state->ownership().Register(record),
            aegis_access::RequestOwnershipStatus::kOk);

  const AccessBlockAndCancelResult result =
      state->InstallBlockBarrierAndCancelMatching(
          {"", 1, SelectorFor(record)});
  EXPECT_EQ(result.barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kInvalidBarrier);
  EXPECT_EQ(state->ownership().size(), 1u);
  EXPECT_EQ(state->barriers().size(), 0u);
}


TEST_F(AccessRequestDispatchStateTest,
       BarrierReleaseWaitsForAckTerminationAndDurableCommit) {
  auto profile = TestingProfile::Builder().Build();
  auto* state = AccessRequestDispatchState::GetOrCreate(profile.get());
  ASSERT_NE(state, nullptr);

  const auto record = TestRecord();
  const auto publication = PublicationFor(record, 10, 10, "block-0137");
  ASSERT_EQ(state->InstallBlockBarrierAndCancelMatching(
                {"block-0137", 10, SelectorFor(record)})
                .barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kOk);
  ASSERT_EQ(state->BeginPolicyPublication(publication).status,
            aegis_access::PolicyPublicationAckStatus::kPending);
  ASSERT_EQ(state->AcknowledgePolicyPublication(
                publication.identity, "browser-runtime")
                .status,
            aegis_access::PolicyPublicationAckStatus::kPending);
  ASSERT_EQ(state->MarkPolicyPublicationTerminationsComplete(
                publication.identity)
                .status,
            aegis_access::PolicyPublicationAckStatus::kPending);
  ASSERT_EQ(state->MarkPolicyPublicationDurablyCommitted(
                publication.identity)
                .status,
            aegis_access::PolicyPublicationAckStatus::kPending);

  const auto early =
      state->ReleaseBlockBarrierForReadyPublication(publication.identity);
  EXPECT_FALSE(early.released);
  EXPECT_EQ(state->barriers().size(), 1u);

  ASSERT_EQ(state->AcknowledgePolicyPublication(
                publication.identity, "network-context")
                .status,
            aegis_access::PolicyPublicationAckStatus::kReady);
  const auto released =
      state->ReleaseBlockBarrierForReadyPublication(publication.identity);
  EXPECT_TRUE(released.released);
  EXPECT_EQ(released.publication_status,
            aegis_access::PolicyPublicationAckStatus::kFinalized);
  EXPECT_EQ(released.barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kOk);
  EXPECT_EQ(state->barriers().size(), 0u);
}

TEST_F(AccessRequestDispatchStateTest,
       MissingNetworkTransportFailsPublicationImmediately) {
  auto profile = TestingProfile::Builder().Build();
  auto* state = AccessRequestDispatchState::GetOrCreate(profile.get());
  ASSERT_NE(state, nullptr);

  const auto record = TestRecord();
  const auto publication =
      PublicationFor(record, 15, 15, "missing-transport-0137");
  ASSERT_EQ(state->BeginPolicyPublication(publication).status,
            aegis_access::PolicyPublicationAckStatus::kPending);

  const auto result = state->RequestNetworkContextPublicationAck(
      publication.identity, record.owner);
  EXPECT_EQ(result.status, AccessNetworkConfigAckStatus::kMissingTransport);
  EXPECT_EQ(state->AcknowledgePolicyPublication(
                publication.identity, "browser-runtime")
                .status,
            aegis_access::PolicyPublicationAckStatus::kFailed);
  EXPECT_FALSE(
      state->ReleaseBlockBarrierForReadyPublication(publication.identity)
          .released);
}

TEST_F(AccessRequestDispatchStateTest,
       LateAckCannotReleaseNewerBlockBarrier) {
  auto profile = TestingProfile::Builder().Build();
  auto* state = AccessRequestDispatchState::GetOrCreate(profile.get());
  ASSERT_NE(state, nullptr);

  const auto record = TestRecord();
  const auto older = PublicationFor(record, 20, 20, "block-old");
  const auto newer = PublicationFor(record, 21, 21, "block-new");
  ASSERT_EQ(state->InstallBlockBarrierAndCancelMatching(
                {"block-old", 20, SelectorFor(record)})
                .barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kOk);
  ASSERT_EQ(state->BeginPolicyPublication(older).status,
            aegis_access::PolicyPublicationAckStatus::kPending);
  ASSERT_EQ(state->InstallBlockBarrierAndCancelMatching(
                {"block-new", 21, SelectorFor(record)})
                .barrier_status,
            aegis_access::RequestDispatchBarrierStatus::kOk);
  ASSERT_EQ(state->BeginPolicyPublication(newer).status,
            aegis_access::PolicyPublicationAckStatus::kPending);

  EXPECT_EQ(state->AcknowledgePolicyPublication(
                older.identity, "network-context")
                .status,
            aegis_access::PolicyPublicationAckStatus::kStaleOperation);
  const auto old_release =
      state->ReleaseBlockBarrierForReadyPublication(older.identity);
  EXPECT_FALSE(old_release.released);
  EXPECT_EQ(state->barriers().size(), 1u);
  const auto evaluation = state->barriers().EvaluateRequest(record);
  ASSERT_TRUE(evaluation.barrier.has_value());
  EXPECT_EQ(evaluation.barrier->operation_id, "block-new");
}

}  // namespace
}  // namespace aegis::access
