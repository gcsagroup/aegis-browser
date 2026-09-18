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

}  // namespace
}  // namespace aegis::access
