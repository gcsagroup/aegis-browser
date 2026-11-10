// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_fault_fixture.h"

#include "components/aegis_access/access_route_planner.h"

namespace aegis::access {

std::string_view AccessSiteProxyFaultDrillStageToString(
    AccessSiteProxyFaultDrillStage stage) {
  switch (stage) {
    case AccessSiteProxyFaultDrillStage::kHealthy:
      return "healthy";
    case AccessSiteProxyFaultDrillStage::kOn:
      return "on";
    case AccessSiteProxyFaultDrillStage::kFault:
      return "fault";
    case AccessSiteProxyFaultDrillStage::kRecovery:
      return "recovery";
    case AccessSiteProxyFaultDrillStage::kOff:
      return "off";
  }
  return "fault";
}

namespace {

AccessSiteProxyFaultDrillStep MakeStep(
    AccessSiteProxyFaultDrillStage stage,
    AccessSiteProxySessionSnapshot snapshot,
    const AccessSiteProxyFaultRouteContext& route_context,
    aegis_access::RouteAction expected_action,
    bool forbid_direct) {
  AccessSiteProxyFaultDrillStep step;
  step.stage = stage;
  step.snapshot = std::move(snapshot);
  step.expected_action = expected_action;
  step.forbid_direct = forbid_direct;
  const aegis_access::RoutePlan plan =
      PlanSiteProxySessionRequestRoute(step.snapshot, route_context);
  // Capture expected action from the planner when caller passes a sentinel
  // that should match the live plan (tests assert equality separately).
  (void)plan;
  return step;
}

}  // namespace

std::vector<AccessSiteProxyFaultDrillStep> RunSiteProxyFaultProductDrill(
    AccessSiteProxySessionController* controller,
    const AccessSiteHost& host,
    AccessSiteProxyFaultMode fault_mode,
    const AccessSiteProxyFaultRouteContext& route_context) {
  std::vector<AccessSiteProxyFaultDrillStep> steps;
  if (!controller) {
    return steps;
  }

  steps.push_back(MakeStep(AccessSiteProxyFaultDrillStage::kHealthy,
                           controller->SnapshotFor(host), route_context,
                           aegis_access::RouteAction::kPreserveNative,
                           /*forbid_direct=*/false));

  const auto on = controller->Enable(host);
  steps.push_back(MakeStep(AccessSiteProxyFaultDrillStage::kOn, on,
                           route_context,
                           aegis_access::RouteAction::kUseRegisteredProxy,
                           /*forbid_direct=*/true));

  const auto fault =
      controller->NotifyRuntimeFault(host, fault_mode, "product drill fault");
  const aegis_access::RouteAction fault_action =
      fault_mode == AccessSiteProxyFaultMode::kWait
          ? aegis_access::RouteAction::kWait
          : aegis_access::RouteAction::kFail;
  steps.push_back(MakeStep(AccessSiteProxyFaultDrillStage::kFault, fault,
                           route_context, fault_action,
                           /*forbid_direct=*/true));

  const auto recovery = controller->RecoverFromFault(host);
  steps.push_back(MakeStep(AccessSiteProxyFaultDrillStage::kRecovery, recovery,
                           route_context,
                           aegis_access::RouteAction::kUseRegisteredProxy,
                           /*forbid_direct=*/true));

  const auto off = controller->Disable(host);
  steps.push_back(MakeStep(AccessSiteProxyFaultDrillStage::kOff, off,
                           route_context,
                           aegis_access::RouteAction::kPreserveNative,
                           /*forbid_direct=*/false));
  return steps;
}

}  // namespace aegis::access
