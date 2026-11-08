// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_fault_fixture.h"
#include "chrome/browser/aegis/access/access_site_proxy_phase1_evidence_fixture.h"
#include "chrome/browser/aegis/access/access_site_proxy_session.h"

#include <vector>

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
  std::vector<AccessMode> published_modes;

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
    for (const auto& member : request.candidate_members) {
      published_modes.push_back(member.mode);
    }
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

AccessSiteProxyFaultRouteContext HealthyRouteContext(
    uint64_t policy_generation) {
  AccessSiteProxyFaultRouteContext ctx;
  ctx.owner = TestOwner();
  ctx.proxy_group_id = "proxy-group";
  ctx.generations = {policy_generation, 2, 3, 4, 5};
  ctx.registered_proxy_entry = aegis_access::RegisteredProxyEntry{
      "reg-1", "proxy-group", TestOwner(), ctx.generations};
  return ctx;
}

TEST(AccessSiteProxySessionTest, RuntimeFaultFailClosedKeepsAllowWithoutDirect) {
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");
  ASSERT_EQ(controller.Enable(host).phase, AccessSiteProxySessionPhase::kReady);
  const int publishes_before_fault = orchestrator.publish_count;
  const int tear_downs_before_fault = orchestrator.tear_down_count;

  const auto fault = controller.NotifyRuntimeFault(
      host, AccessSiteProxyFaultMode::kFailClosed, "node offline");

  EXPECT_EQ(fault.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(fault.fault_mode, AccessSiteProxyFaultMode::kFailClosed);
  EXPECT_EQ(fault.phase, AccessSiteProxySessionPhase::kUnavailable);
  EXPECT_EQ(fault.connection, AccessSiteConnectionState::kUnavailable);
  EXPECT_NE(fault.failure_reason.find("fault"), std::string::npos);
  EXPECT_EQ(fault.failure_reason.find("Direct success"), std::string::npos);
  // Fault must not republish DIRECT or tear down the PROXY selection.
  EXPECT_EQ(orchestrator.publish_count, publishes_before_fault);
  EXPECT_EQ(orchestrator.tear_down_count, tear_downs_before_fault);
  for (AccessMode mode : orchestrator.published_modes) {
    EXPECT_NE(mode, AccessMode::kDirect);
  }

  const auto plan =
      PlanSiteProxySessionRequestRoute(fault, HealthyRouteContext(7));
  EXPECT_EQ(plan.action, aegis_access::RouteAction::kFail);
  EXPECT_EQ(plan.effective_mode, AccessMode::kProxy);
  EXPECT_NE(plan.action, aegis_access::RouteAction::kPreserveNative);
}

TEST(AccessSiteProxySessionTest, RuntimeFaultWaitHoldsRequestsWithoutDirect) {
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");
  ASSERT_EQ(controller.Enable(host).phase, AccessSiteProxySessionPhase::kReady);

  const auto fault = controller.NotifyRuntimeFault(
      host, AccessSiteProxyFaultMode::kWait, "runtime recovering");

  EXPECT_EQ(fault.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(fault.fault_mode, AccessSiteProxyFaultMode::kWait);
  EXPECT_EQ(fault.connection, AccessSiteConnectionState::kConnecting);
  EXPECT_EQ(orchestrator.publish_count, 1);

  const auto plan =
      PlanSiteProxySessionRequestRoute(fault, HealthyRouteContext(7));
  EXPECT_EQ(plan.action, aegis_access::RouteAction::kWait);
  EXPECT_EQ(plan.effective_mode, AccessMode::kProxy);
  EXPECT_NE(plan.action, aegis_access::RouteAction::kPreserveNative);
}

TEST(AccessSiteProxySessionTest, RecoverFromFaultRestoresReadyViaProxy) {
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");
  ASSERT_EQ(controller.Enable(host).phase, AccessSiteProxySessionPhase::kReady);
  ASSERT_EQ(controller
                .NotifyRuntimeFault(host, AccessSiteProxyFaultMode::kFailClosed)
                .fault_mode,
            AccessSiteProxyFaultMode::kFailClosed);

  const auto recovered = controller.RecoverFromFault(host);

  EXPECT_EQ(recovered.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(recovered.phase, AccessSiteProxySessionPhase::kReady);
  EXPECT_EQ(recovered.connection, AccessSiteConnectionState::kReady);
  EXPECT_EQ(recovered.fault_mode, AccessSiteProxyFaultMode::kNone);
  EXPECT_TRUE(recovered.failure_reason.empty());
  EXPECT_EQ(orchestrator.publish_count, 2);
  ASSERT_FALSE(orchestrator.published_modes.empty());
  EXPECT_EQ(orchestrator.published_modes.back(), AccessMode::kProxy);

  const auto plan =
      PlanSiteProxySessionRequestRoute(recovered, HealthyRouteContext(8));
  EXPECT_EQ(plan.action, aegis_access::RouteAction::kUseRegisteredProxy);
  EXPECT_NE(plan.action, aegis_access::RouteAction::kPreserveNative);
}

TEST(AccessSiteProxySessionTest,
     NetworkServiceRestartRebuildsProxyWithoutDirect) {
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("www.example.com");
  ASSERT_EQ(controller.Enable(host).phase, AccessSiteProxySessionPhase::kReady);

  const auto rebuilt = controller.RebuildAfterNetworkServiceRestart(host);

  EXPECT_EQ(rebuilt.intent, AccessSiteIntent::kAllow);
  EXPECT_EQ(rebuilt.phase, AccessSiteProxySessionPhase::kReady);
  EXPECT_EQ(rebuilt.connection, AccessSiteConnectionState::kReady);
  EXPECT_EQ(rebuilt.fault_mode, AccessSiteProxyFaultMode::kNone);
  EXPECT_EQ(orchestrator.publish_count, 2);
  for (AccessMode mode : orchestrator.published_modes) {
    EXPECT_EQ(mode, AccessMode::kProxy);
  }

  const auto plan =
      PlanSiteProxySessionRequestRoute(rebuilt, HealthyRouteContext(8));
  EXPECT_EQ(plan.action, aegis_access::RouteAction::kUseRegisteredProxy);
}

TEST(AccessSiteProxySessionTest,
     ProductFaultDrillHealthyOnFaultRecoveryOff) {
  // Product fixture stages matching the browser lifecycle drill:
  // healthy → on → fault → recovery → off. Off may use DIRECT publication;
  // fault/recovery on the allow path must not.
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("target.example");

  auto steps = RunSiteProxyFaultProductDrill(
      &controller, host, AccessSiteProxyFaultMode::kFailClosed,
      HealthyRouteContext(7));
  ASSERT_EQ(steps.size(), 5u);
  EXPECT_EQ(steps[0].stage, AccessSiteProxyFaultDrillStage::kHealthy);
  EXPECT_EQ(steps[1].stage, AccessSiteProxyFaultDrillStage::kOn);
  EXPECT_EQ(steps[1].snapshot.phase, AccessSiteProxySessionPhase::kReady);
  EXPECT_EQ(steps[2].stage, AccessSiteProxyFaultDrillStage::kFault);
  EXPECT_EQ(steps[2].expected_action, aegis_access::RouteAction::kFail);
  EXPECT_TRUE(steps[2].forbid_direct);
  EXPECT_EQ(PlanSiteProxySessionRequestRoute(steps[2].snapshot,
                                             HealthyRouteContext(7))
                .action,
            aegis_access::RouteAction::kFail);
  EXPECT_EQ(steps[3].stage, AccessSiteProxyFaultDrillStage::kRecovery);
  EXPECT_EQ(steps[3].snapshot.phase, AccessSiteProxySessionPhase::kReady);
  EXPECT_EQ(PlanSiteProxySessionRequestRoute(steps[3].snapshot,
                                             HealthyRouteContext(8))
                .action,
            aegis_access::RouteAction::kUseRegisteredProxy);
  EXPECT_EQ(steps[4].stage, AccessSiteProxyFaultDrillStage::kOff);
  EXPECT_EQ(steps[4].snapshot.intent, AccessSiteIntent::kOff);
  for (AccessMode mode : orchestrator.published_modes) {
    // Enable/recover publish PROXY only; disable may publish DIRECT after.
    if (mode == AccessMode::kDirect) {
      EXPECT_EQ(controller.intent_store().Get(host), AccessSiteIntent::kOff);
    }
  }
}

TEST(AccessSiteProxySessionTest, Phase1EvidenceCorrelationIdConvention) {
  const std::string id = BuildPhase1EvidenceCorrelationId(
      "abcdef0123456789deadbeef", "run-42",
      AccessSiteProxyPhase1EvidenceStepId::kLoad);
  EXPECT_EQ(id, "aegis-mac-p1/abcdef01/run-42/load");
  EXPECT_TRUE(IsValidPhase1EvidenceCorrelationId(id));
  EXPECT_FALSE(IsValidPhase1EvidenceCorrelationId(
      "aegis-mac-p1/ABCDEF01/run-42/load"));
  EXPECT_FALSE(IsValidPhase1EvidenceCorrelationId(
      "aegis-mac-p1/abcdef01/run-42/healthy"));
  EXPECT_EQ(AccessSiteProxyPhase1EvidenceStepAcceptanceId(
                AccessSiteProxyPhase1EvidenceStepId::kOff),
            "B2-5");
}

TEST(AccessSiteProxySessionTest, Phase1EvidenceDrillOnLoadFaultRecoveryOff) {
  // Product exit path B2-1..B2-5 with correlation IDs. This proves the session
  // contract only; B4 PASS still requires a same-candidate launchable macOS
  // build with logs + UI evidence. Do not claim PASS for open DEV-only P-mac-4.
  FakeOrchestrator orchestrator;
  AccessSiteProxySessionController controller(&orchestrator);
  const AccessSiteHost host = Host("target.example");
  constexpr std::string_view kCandidate =
      "8ba3848aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  constexpr std::string_view kRun = "fixture-1";

  const auto run = RunSiteProxyPhase1EvidenceDrill(
      &controller, host, AccessSiteProxyFaultMode::kFailClosed,
      HealthyRouteContext(7), kCandidate, kRun);
  ASSERT_EQ(run.steps.size(), 5u);
  EXPECT_EQ(run.candidate_sha, kCandidate);
  EXPECT_EQ(run.run_id, kRun);

  EXPECT_EQ(run.steps[0].step, AccessSiteProxyPhase1EvidenceStepId::kOn);
  EXPECT_EQ(run.steps[0].correlation_id, "aegis-mac-p1/8ba3848a/fixture-1/on");
  EXPECT_EQ(run.steps[0].snapshot.phase, AccessSiteProxySessionPhase::kReady);
  EXPECT_TRUE(run.steps[0].forbid_direct);
  EXPECT_EQ(PlanSiteProxySessionRequestRoute(run.steps[0].snapshot,
                                             HealthyRouteContext(7))
                .action,
            aegis_access::RouteAction::kUseRegisteredProxy);

  EXPECT_EQ(run.steps[1].step, AccessSiteProxyPhase1EvidenceStepId::kLoad);
  EXPECT_EQ(run.steps[1].correlation_id,
            "aegis-mac-p1/8ba3848a/fixture-1/load");
  EXPECT_EQ(run.steps[1].expected_action,
            aegis_access::RouteAction::kUseRegisteredProxy);
  EXPECT_TRUE(run.steps[1].forbid_direct);
  EXPECT_EQ(PlanSiteProxySessionRequestRoute(run.steps[1].snapshot,
                                             HealthyRouteContext(7))
                .action,
            aegis_access::RouteAction::kUseRegisteredProxy);

  EXPECT_EQ(run.steps[2].step, AccessSiteProxyPhase1EvidenceStepId::kFault);
  EXPECT_EQ(run.steps[2].expected_action, aegis_access::RouteAction::kFail);
  EXPECT_TRUE(run.steps[2].forbid_direct);
  EXPECT_EQ(PlanSiteProxySessionRequestRoute(run.steps[2].snapshot,
                                             HealthyRouteContext(7))
                .action,
            aegis_access::RouteAction::kFail);

  EXPECT_EQ(run.steps[3].step, AccessSiteProxyPhase1EvidenceStepId::kRecovery);
  EXPECT_EQ(run.steps[3].snapshot.phase, AccessSiteProxySessionPhase::kReady);
  EXPECT_EQ(PlanSiteProxySessionRequestRoute(run.steps[3].snapshot,
                                             HealthyRouteContext(8))
                .action,
            aegis_access::RouteAction::kUseRegisteredProxy);

  EXPECT_EQ(run.steps[4].step, AccessSiteProxyPhase1EvidenceStepId::kOff);
  EXPECT_EQ(run.steps[4].snapshot.intent, AccessSiteIntent::kOff);
  EXPECT_EQ(run.steps[4].expected_action,
            aegis_access::RouteAction::kPreserveNative);
  EXPECT_FALSE(run.steps[4].forbid_direct);
  for (const auto& step : run.steps) {
    EXPECT_TRUE(IsValidPhase1EvidenceCorrelationId(step.correlation_id));
  }
}

}  // namespace
}  // namespace aegis::access

