// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_PHASE1_EVIDENCE_FIXTURE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_PHASE1_EVIDENCE_FIXTURE_H_

#include <string>
#include <string_view>
#include <vector>

#include "chrome/browser/aegis/access/access_site_proxy_session.h"
#include "components/aegis_access/access_route_types.h"

namespace aegis::access {

// P-mac-6 product Phase 1 five-step evidence stages (acceptance B2-1..B2-5).
// Distinct from the P-mac-5 fault drill (healthy→on→fault→recovery→off): the
// product exit path starts at enable and inserts an explicit "load via PROXY"
// observation before fault/recovery/off.
enum class AccessSiteProxyPhase1EvidenceStepId {
  kOn,        // B2-1
  kLoad,      // B2-2
  kFault,     // B2-3
  kRecovery,  // B2-4
  kOff,       // B2-5
};

std::string_view AccessSiteProxyPhase1EvidenceStepIdToString(
    AccessSiteProxyPhase1EvidenceStepId step);

std::string_view AccessSiteProxyPhase1EvidenceStepAcceptanceId(
    AccessSiteProxyPhase1EvidenceStepId step);

// Correlation ID convention (B4 / P0-4):
//   aegis-mac-p1/<candidate8>/<run_id>/<step>
// Links browser logs, node-side traces, and optional UI captures for one
// candidate SHA. Never reuse a correlation ID across candidates or runs.
std::string BuildPhase1EvidenceCorrelationId(std::string_view candidate_sha,
                                             std::string_view run_id,
                                             AccessSiteProxyPhase1EvidenceStepId step);

bool IsValidPhase1EvidenceCorrelationId(std::string_view correlation_id);

struct AccessSiteProxyPhase1EvidenceStep {
  AccessSiteProxyPhase1EvidenceStepId step =
      AccessSiteProxyPhase1EvidenceStepId::kOn;
  std::string correlation_id;
  AccessSiteProxySessionSnapshot snapshot;
  aegis_access::RouteAction expected_action =
      aegis_access::RouteAction::kPreserveNative;
  // True on allow-path steps: PreserveNative / DIRECT success is forbidden.
  bool forbid_direct = false;
};

struct AccessSiteProxyPhase1EvidenceRun {
  std::string candidate_sha;
  std::string run_id;
  std::vector<AccessSiteProxyPhase1EvidenceStep> steps;
};

// Runs on → load → fault → recovery → off against |controller|.
// |fault_mode| selects Fail vs Wait during the fault stage.
// Unit / browser fixtures may use this without a full native macOS product
// PASS claim — B4 still requires a launchable build + same-candidate artifacts.
AccessSiteProxyPhase1EvidenceRun RunSiteProxyPhase1EvidenceDrill(
    AccessSiteProxySessionController* controller,
    const AccessSiteHost& host,
    AccessSiteProxyFaultMode fault_mode,
    const AccessSiteProxyFaultRouteContext& route_context,
    std::string_view candidate_sha,
    std::string_view run_id);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_PHASE1_EVIDENCE_FIXTURE_H_
