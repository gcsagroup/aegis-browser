// Copyright 2026 GCSA

#include <string>

#include "components/aegis_access/request_ownership_registry_contract_test.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis_access::test {
namespace {

class GtestOwnershipObserver : public RequestOwnershipRegistryTestObserver {
 public:
  void Expect(bool condition, const std::string& label) override {
    EXPECT_TRUE(condition) << label;
  }
};

TEST(RequestOwnershipRegistryTest, SharedUnitContract) {
  GtestOwnershipObserver observer;
  RunRequestOwnershipRegistryUnitTests(observer);
}

TEST(RequestOwnershipRegistryRegressionTest, SharedRegressionContract) {
  GtestOwnershipObserver observer;
  RunRequestOwnershipRegistryRegressionTests(observer);
}

TEST(TargetedRequestCancellationTest, SharedUnitContract) {
  GtestOwnershipObserver observer;
  RunTargetedRequestCancellationUnitTests(observer);
}

TEST(TargetedRequestCancellationRegressionTest, SharedRegressionContract) {
  GtestOwnershipObserver observer;
  RunTargetedRequestCancellationRegressionTests(observer);
}

TEST(RequestDispatchBarrierTest, SharedUnitContract) {
  GtestOwnershipObserver observer;
  RunRequestDispatchBarrierUnitTests(observer);
}

TEST(RequestDispatchBarrierRegressionTest, SharedRegressionContract) {
  GtestOwnershipObserver observer;
  RunRequestDispatchBarrierRegressionTests(observer);
}

TEST(RequestOwnershipRegistryTest, NativeRequestHasNoInventedProxySelection) {
  auto record = DocumentOwnershipRecord();
  record.generations.selection_generation = 0;
  RequestOwnershipRegistry registry(2);
  // The existing proxy contract still rejects an absent selection.
  EXPECT_EQ(registry.Register(record), RequestOwnershipStatus::kInvalidRecord);
  record.route = RequestOwnershipRoute::kNative;
  ASSERT_EQ(registry.Register(record), RequestOwnershipStatus::kOk);
  int terminated = 0;
  EXPECT_EQ(registry.MarkDispatched(record.request_id, record.owner,
      record.generations, std::make_unique<RecordingTerminationHandle>(&terminated)),
      RequestOwnershipStatus::kOk);
  EXPECT_EQ(registry.MarkStreaming(record.request_id, record.owner, record.generations),
            RequestOwnershipStatus::kOk);
  EXPECT_EQ(registry.Complete(record.request_id, record.owner, record.generations).status,
            RequestOwnershipStatus::kOk);
  EXPECT_EQ(terminated, 0);
  record.generations.selection_generation = 1;
  EXPECT_EQ(registry.Register(record), RequestOwnershipStatus::kInvalidRecord);
  record.generations.selection_generation = 0;
  record.generations.identity_generation = 0;
  EXPECT_EQ(registry.Register(record), RequestOwnershipStatus::kInvalidRecord);
}

TEST(RequestDispatchBarrierTest, NativeTrackingStillHonorsBlockAndCancellation) {
  auto record = DocumentOwnershipRecord();
  record.route = RequestOwnershipRoute::kNative;
  record.generations.selection_generation = 0;
  RequestDispatchBarrierRegistry barriers(2);
  EXPECT_EQ(barriers.EvaluateRequest(record).decision, RequestDispatchDecision::kAllow);
  ASSERT_EQ(barriers.InstallBlockBarrier({"block", 1, DocumentCancellationSelector()}),
            RequestDispatchBarrierStatus::kOk);
  EXPECT_EQ(barriers.EvaluateRequest(record).decision, RequestDispatchDecision::kBlock);
  RequestOwnershipRegistry registry(2);
  ASSERT_EQ(registry.Register(record), RequestOwnershipStatus::kOk);
  int terminated = 0;
  ASSERT_EQ(registry.MarkDispatched(record.request_id, record.owner,
      record.generations, std::make_unique<RecordingTerminationHandle>(&terminated)),
      RequestOwnershipStatus::kOk);
  const auto cancelled = registry.CancelMatchingPageTarget(DocumentCancellationSelector());
  EXPECT_EQ(cancelled.status, RequestOwnershipStatus::kOk);
  EXPECT_EQ(cancelled.cancellations.size(), 1u);
  EXPECT_EQ(terminated, 1);
}

TEST(RequestDispatchBarrierTest, WebsiteScopeCoversResourcesWithoutCrossSiteOrOwnerLeak) {
  auto selector = DocumentCancellationSelector();
  selector.website_context = true;
  selector.exact_host = "example.test";
  selector.top_level_site = "https://example.test";
  RequestDispatchBarrierRegistry barriers(2);
  ASSERT_EQ(barriers.InstallBlockBarrier({"website-off", 2, selector}),
            RequestDispatchBarrierStatus::kOk);
  auto resource = DocumentOwnershipRecord();
  resource.owner = selector.owner;
  resource.document_token = "another-tab-document";
  resource.top_level_site = "http://example.test";
  resource.exact_host = "cdn.other.test";
  resource.scheme = RequestScheme::kHttp;
  resource.port = 8080;
  EXPECT_EQ(barriers.EvaluateRequest(resource).decision, RequestDispatchDecision::kBlock);
  resource.top_level_site = "https://another.test";
  EXPECT_EQ(barriers.EvaluateRequest(resource).decision, RequestDispatchDecision::kAllow);
  resource.top_level_site = "https://example.test";
  resource.owner.profile_token += "-other";
  EXPECT_EQ(barriers.EvaluateRequest(resource).decision, RequestDispatchDecision::kAllow);
  auto legacy = selector;
  legacy.website_context = false;
  EXPECT_FALSE(SameRequestCancellationSelector(legacy, selector));
}

}  // namespace
}  // namespace aegis_access::test
