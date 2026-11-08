// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_FAULT_FIXTURE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_FAULT_FIXTURE_H_

#include <string>
#include <string_view>
#include <vector>

#include "chrome/browser/aegis/access/access_site_proxy_session.h"
#include "components/aegis_access/access_route_types.h"

namespace aegis::access {

// Product fault drill stages for P-mac-5 (B2-3/B2-4). Mirrors the browser
// lifecycle fixture ControlledOnFaultRecoveryOffPreservesRoute while staying
// usable from session unit tests without a full InProcessBrowserTest host.
enum class AccessSiteProxyFaultDrillStage {
  kHealthy,
  kOn,
  kFault,
  kRecovery,
  kOff,
};

std::string_view AccessSiteProxyFaultDrillStageToString(
    AccessSiteProxyFaultDrillStage stage);

struct AccessSiteProxyFaultDrillStep {
  AccessSiteProxyFaultDrillStage stage =
      AccessSiteProxyFaultDrillStage::kHealthy;
  AccessSiteProxySessionSnapshot snapshot;
  aegis_access::RouteAction expected_action =
      aegis_access::RouteAction::kPreserveNative;
  // True when the allow path must reject PreserveNative / DIRECT success.
  bool forbid_direct = false;
};

// Runs healthy → on → fault → recovery → off against |controller|.
// |fault_mode| selects Fail vs Wait during the fault stage.
std::vector<AccessSiteProxyFaultDrillStep> RunSiteProxyFaultProductDrill(
    AccessSiteProxySessionController* controller,
    const AccessSiteHost& host,
    AccessSiteProxyFaultMode fault_mode,
    const AccessSiteProxyFaultRouteContext& route_context);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_FAULT_FIXTURE_H_
