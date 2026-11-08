// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_session.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

OwnershipKey TestOwner() {
  return {ChannelNamespace::kDev, "profile-token", "partition-token"};
}

AccessSiteHost Host(std::string_view value) {
  const auto result = MakeAccessSiteHost(value);
  EXPECT_EQ(result.status, AccessSiteHostStatus::kOk);
  return *result.host;
}

class FakeOrchestrator : public AccessSiteProxySessionOrchestrating {
 public:
  enum class Stage {
    kEnsure,
    kPublish,
    kTearDown,
  };

  bool local_proxy_ready = true;
  bool admit_direct_fallback = false;
  std::optional<Stage> fail_at;
  AccessSiteProxySessionError ensure_error =
      AccessSiteProxySessionError::kLocalProxyNotReady;
  AccessSiteProxySessionError publish_error =
      AccessSiteProxySessionError::kPublishFailed;
  int ensure_count = 0;
  int publish_count = 0;
  int tear_down_count = 0;
  uint64_t next_generation = 7;
  std::optional<AccessSiteHost> last_torn_down;

  AccessSiteProxySessionError EnsureLocalProxyReady(
      const AccessSiteHost& host,
      AccessSiteProxyLocalProxyReadyInfo* out) override {
    ++ensure_count;
    EXPECT_TRUE(out);
    if (fail_at == Stage::kEnsure || !local_proxy_ready) {
      return ensure_error;
    }
    out->owner = TestOwner();
    out->proxy_group_id = "proxy-group";
    (void)host;
    return AccessSiteProxySessionError::kOk;
  }

  AccessSiteProxySessionError PublishAndAcknowledge(
      const SiteGroupMutationRequest& request,
      const aegis_access::RequestCancellationSelector& selector,
      AccessSiteProxySessionPublicationInfo* out) override {
    ++publish_count;
    EXPECT_TRUE(out);
    EXPECT_EQ(selector.exact_host, request.candidate_group.canonical_host);
    if (admit_direct_fallback) {
      return AccessSiteProxySessionError::kDirectFallbackNotAdmitted;
    }
    if (fail_at == Stage::kPublish) {
      return publish_error;
    }
    out->policy_generation = next_generation++;
    return AccessSiteProxySessionError::kOk;
  }

  AccessSiteProxySessionError TearDownPublishedHost(
      const AccessSiteHost& host) override {
    ++tear_down_count;
    last_torn_down = host;
    if (fail_at == Stage::kTearDown) {
      return AccessSiteProxySessionError::kTearDownFailed;
    }
    return AccessSiteProxySessionError::kOk;
  }
};

TEST(AccessSiteProxySessionTest, EnableRunsPreparePublishAckReady) {
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");

  const auto snap = controller.Enable(host);

  EXPECT_EQ(snap.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(snap.phase, AccessSiteProxySessionPhase::kReady);
  EXPECT_EQ(snap.connection, AccessSiteConnectionState::kReady);
  EXPECT_TRUE(snap.failure_reason.empty());
  EXPECT_EQ(snap.policy_generation, 7u);
  EXPECT_EQ(orchestrator.ensure_count, 1);
  EXPECT_EQ(orchestrator.publish_count, 1);
  EXPECT_EQ(controller.intent_store().Get(host), AccessSiteIntent::kAllow);
}

TEST(AccessSiteProxySessionTest, DisableCommitsLocallyEvenWhenServiceDown) {
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");
  ASSERT_EQ(controller.Enable(host).phase, AccessSiteProxySessionPhase::kReady);

  orchestrator.local_proxy_ready = false;
  orchestrator.ensure_error = AccessSiteProxySessionError::kServiceUnavailable;
  const auto snap = controller.Disable(host);

  EXPECT_EQ(snap.intent, AccessSiteIntent::kOff);
  EXPECT_EQ(snap.phase, AccessSiteProxySessionPhase::kIdle);
  EXPECT_EQ(snap.connection, AccessSiteConnectionState::kIdle);
  EXPECT_EQ(controller.intent_store().Get(host), AccessSiteIntent::kOff);
  // Tear-down still attempted when ensure cannot publish DIRECT.
  EXPECT_GE(orchestrator.tear_down_count, 1);
}

TEST(AccessSiteProxySessionTest, EnableWithoutLocalProxyFailsClosedReadable) {
  FakeOrchestrator orchestrator;
  orchestrator.local_proxy_ready = false;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");

  const auto snap = controller.Enable(host);

  EXPECT_EQ(snap.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(snap.phase, AccessSiteProxySessionPhase::kUnavailable);
  EXPECT_EQ(snap.connection, AccessSiteConnectionState::kUnavailable);
  EXPECT_FALSE(snap.failure_reason.empty());
  EXPECT_EQ(snap.failure_reason.find("Direct success"), std::string::npos);
  EXPECT_EQ(orchestrator.publish_count, 0);
}

TEST(AccessSiteProxySessionTest, PublishFailureDoesNotClaimReady) {
  FakeOrchestrator orchestrator;
  orchestrator.fail_at = FakeOrchestrator::Stage::kPublish;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("news.example");

  const auto snap = controller.Enable(host);

  EXPECT_EQ(snap.phase, AccessSiteProxySessionPhase::kUnavailable);
  EXPECT_EQ(snap.connection, AccessSiteConnectionState::kUnavailable);
  EXPECT_NE(snap.failure_reason.find("publish"), std::string::npos);
  EXPECT_EQ(orchestrator.tear_down_count, 1);
}

TEST(AccessSiteProxySessionTest, DirectFallbackRejectedOnAllowPath) {
  FakeOrchestrator orchestrator;
  orchestrator.admit_direct_fallback = true;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");

  const auto snap = controller.Enable(host);

  EXPECT_EQ(snap.phase, AccessSiteProxySessionPhase::kUnavailable);
  EXPECT_EQ(
      snap.failure_reason,
      AccessSiteProxySessionErrorReadableMessage(
          AccessSiteProxySessionError::kDirectFallbackNotAdmitted));
}

TEST(AccessSiteProxySessionTest, BuildsOrdinaryAllowAndOffMutationPlans) {
  const AccessSiteHost host = Host("news.example");
  auto allow = BuildSiteProxySessionMutationPlan(
      host, AccessSiteIntent::kAllow, TestOwner(), "proxy-group", "on");
  EXPECT_EQ(allow.mutation.status, AccessSiteIntentMutationStatus::kReady);
  ASSERT_TRUE(allow.mutation.request);
  EXPECT_EQ(allow.mutation.request->candidate_members[0].mode,
            AccessMode::kProxy);
  EXPECT_EQ(allow.selector.exact_host, "news.example");

  auto off = BuildSiteProxySessionMutationPlan(
      host, AccessSiteIntent::kOff, TestOwner(), "", "off");
  EXPECT_EQ(off.mutation.status, AccessSiteIntentMutationStatus::kReady);
  ASSERT_TRUE(off.mutation.request);
  EXPECT_EQ(off.mutation.request->candidate_members[0].mode,
            AccessMode::kDirect);
}

}  // namespace
}  // namespace aegis::access
