// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_phase1_evidence_fixture.h"

#include <cctype>

namespace aegis::access {

std::string_view AccessSiteProxyPhase1EvidenceStepIdToString(
    AccessSiteProxyPhase1EvidenceStepId step) {
  switch (step) {
    case AccessSiteProxyPhase1EvidenceStepId::kOn:
      return "on";
    case AccessSiteProxyPhase1EvidenceStepId::kLoad:
      return "load";
    case AccessSiteProxyPhase1EvidenceStepId::kFault:
      return "fault";
    case AccessSiteProxyPhase1EvidenceStepId::kRecovery:
      return "recovery";
    case AccessSiteProxyPhase1EvidenceStepId::kOff:
      return "off";
  }
  return "on";
}

std::string_view AccessSiteProxyPhase1EvidenceStepAcceptanceId(
    AccessSiteProxyPhase1EvidenceStepId step) {
  switch (step) {
    case AccessSiteProxyPhase1EvidenceStepId::kOn:
      return "B2-1";
    case AccessSiteProxyPhase1EvidenceStepId::kLoad:
      return "B2-2";
    case AccessSiteProxyPhase1EvidenceStepId::kFault:
      return "B2-3";
    case AccessSiteProxyPhase1EvidenceStepId::kRecovery:
      return "B2-4";
    case AccessSiteProxyPhase1EvidenceStepId::kOff:
      return "B2-5";
  }
  return "B2-1";
}

namespace {

bool IsHexLower(std::string_view value) {
  if (value.empty()) {
    return false;
  }
  for (char c : value) {
    if (!std::isxdigit(static_cast<unsigned char>(c)) ||
        (std::isalpha(static_cast<unsigned char>(c)) &&
         !std::islower(static_cast<unsigned char>(c)))) {
      return false;
    }
  }
  return true;
}

bool IsRunToken(std::string_view value) {
  if (value.empty() || value.size() > 64) {
    return false;
  }
  for (char c : value) {
    const unsigned char uc = static_cast<unsigned char>(c);
    if (!(std::isalnum(uc) || c == '-' || c == '_')) {
      return false;
    }
  }
  return true;
}

AccessSiteProxyPhase1EvidenceStep MakeStep(
    AccessSiteProxyPhase1EvidenceStepId step_id,
    AccessSiteProxySessionSnapshot snapshot,
    std::string_view candidate_sha,
    std::string_view run_id,
    aegis_access::RouteAction expected_action,
    bool forbid_direct) {
  AccessSiteProxyPhase1EvidenceStep step;
  step.step = step_id;
  step.correlation_id =
      BuildPhase1EvidenceCorrelationId(candidate_sha, run_id, step_id);
  step.snapshot = std::move(snapshot);
  step.expected_action = expected_action;
  step.forbid_direct = forbid_direct;
  return step;
}

}  // namespace

std::string BuildPhase1EvidenceCorrelationId(
    std::string_view candidate_sha,
    std::string_view run_id,
    AccessSiteProxyPhase1EvidenceStepId step) {
  std::string candidate8(candidate_sha.substr(0, 8));
  if (candidate8.size() < 8) {
    candidate8.append(8 - candidate8.size(), '0');
  }
  for (char& c : candidate8) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  std::string out = "aegis-mac-p1/";
  out.append(candidate8);
  out.push_back('/');
  out.append(run_id);
  out.push_back('/');
  out.append(AccessSiteProxyPhase1EvidenceStepIdToString(step));
  return out;
}

bool IsValidPhase1EvidenceCorrelationId(std::string_view correlation_id) {
  // aegis-mac-p1/<8 hex>/<run>/<step>
  constexpr std::string_view kPrefix = "aegis-mac-p1/";
  if (!correlation_id.starts_with(kPrefix)) {
    return false;
  }
  const std::string_view rest = correlation_id.substr(kPrefix.size());
  const size_t first = rest.find('/');
  if (first == std::string_view::npos) {
    return false;
  }
  const std::string_view candidate8 = rest.substr(0, first);
  if (candidate8.size() != 8 || !IsHexLower(candidate8)) {
    return false;
  }
  const std::string_view after_candidate = rest.substr(first + 1);
  const size_t second = after_candidate.find('/');
  if (second == std::string_view::npos) {
    return false;
  }
  const std::string_view run_id = after_candidate.substr(0, second);
  const std::string_view step = after_candidate.substr(second + 1);
  if (!IsRunToken(run_id)) {
    return false;
  }
  return step == "on" || step == "load" || step == "fault" ||
         step == "recovery" || step == "off";
}

AccessSiteProxyPhase1EvidenceRun RunSiteProxyPhase1EvidenceDrill(
    AccessSiteProxySessionController* controller,
    const AccessSiteHost& host,
    AccessSiteProxyFaultMode fault_mode,
    const AccessSiteProxyFaultRouteContext& route_context,
    std::string_view candidate_sha,
    std::string_view run_id) {
  AccessSiteProxyPhase1EvidenceRun run;
  run.candidate_sha = std::string(candidate_sha);
  run.run_id = std::string(run_id);
  if (!controller) {
    return run;
  }

  // B2-1 enable
  const auto on = controller->Enable(host);
  run.steps.push_back(MakeStep(AccessSiteProxyPhase1EvidenceStepId::kOn, on,
                               candidate_sha, run_id,
                               aegis_access::RouteAction::kUseRegisteredProxy,
                               /*forbid_direct=*/true));

  // B2-2 load observation: same ready session must still plan PROXY (never
  // DIRECT). Real page-load proof on a launchable macOS build is required for
  // B4 PASS; this fixture locks the session/route contract.
  const auto load_snap = controller->SnapshotFor(host);
  run.steps.push_back(
      MakeStep(AccessSiteProxyPhase1EvidenceStepId::kLoad, load_snap,
               candidate_sha, run_id,
               aegis_access::RouteAction::kUseRegisteredProxy,
               /*forbid_direct=*/true));
  (void)PlanSiteProxySessionRequestRoute(load_snap, route_context);

  // B2-3 fault
  const auto fault =
      controller->NotifyRuntimeFault(host, fault_mode, "phase1 evidence fault");
  const aegis_access::RouteAction fault_action =
      fault_mode == AccessSiteProxyFaultMode::kWait
          ? aegis_access::RouteAction::kWait
          : aegis_access::RouteAction::kFail;
  run.steps.push_back(MakeStep(AccessSiteProxyPhase1EvidenceStepId::kFault,
                               fault, candidate_sha, run_id, fault_action,
                               /*forbid_direct=*/true));

  // B2-4 recovery
  const auto recovery = controller->RecoverFromFault(host);
  run.steps.push_back(
      MakeStep(AccessSiteProxyPhase1EvidenceStepId::kRecovery, recovery,
               candidate_sha, run_id,
               aegis_access::RouteAction::kUseRegisteredProxy,
               /*forbid_direct=*/true));

  // B2-5 off → native
  const auto off = controller->Disable(host);
  run.steps.push_back(MakeStep(AccessSiteProxyPhase1EvidenceStepId::kOff, off,
                               candidate_sha, run_id,
                               aegis_access::RouteAction::kPreserveNative,
                               /*forbid_direct=*/false));
  return run;
}

}  // namespace aegis::access
