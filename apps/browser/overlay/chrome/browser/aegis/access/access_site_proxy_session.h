// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_SESSION_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_SESSION_H_

#include <map>
#include <string>
#include <string_view>

#include <optional>

#include "chrome/browser/aegis/access/access_site_intent.h"
#include "chrome/browser/aegis/access/access_site_proxy_bubble_model.h"
#include "components/aegis_access/access_route_types.h"
#include "components/aegis_access/request_ownership_registry.h"

namespace aegis::access {

// Readable fail-closed errors for bubble → publish/ACK (P-mac-3) and the
// P-mac-5 fault / Network Service rebuild path.
// Callers must surface ReadableMessage(); never treat these as DIRECT success.
enum class AccessSiteProxySessionError {
  kOk,
  kInvalidHost,
  kLocalProxyUnavailable,
  kLocalProxyNotReady,
  kMissingOwner,
  kMissingCoordinator,
  kMissingStore,
  kMissingProxyGroup,
  kPrepareFailed,
  kPublishFailed,
  kAckFailed,
  kMutationFailed,
  kServiceUnavailable,
  kBusy,
  kDirectFallbackNotAdmitted,
  kTearDownFailed,
  kRuntimeFault,
  kNetworkServiceRebuildFailed,
};

// Product fault disposition while intent remains allow (P-mac-5).
// Fail-closed aborts new requests; wait holds them until recovery.
enum class AccessSiteProxyFaultMode {
  kNone,
  kFailClosed,
  kWait,
};

std::string_view AccessSiteProxyFaultModeToString(
    AccessSiteProxyFaultMode mode);

std::string_view AccessSiteProxySessionErrorToString(
    AccessSiteProxySessionError error);
std::string AccessSiteProxySessionErrorReadableMessage(
    AccessSiteProxySessionError error,
    std::string_view detail = {});

enum class AccessSiteProxySessionPhase {
  kIdle,
  kPreparingCandidate,
  kPublishing,
  kAwaitingAck,
  kReady,
  kUnavailable,
};

std::string_view AccessSiteProxySessionPhaseToString(
    AccessSiteProxySessionPhase phase);

struct AccessSiteProxySessionSnapshot {
  AccessSiteHost host;
  AccessSiteIntent intent = AccessSiteIntent::kOff;
  AccessSiteProxySessionPhase phase = AccessSiteProxySessionPhase::kIdle;
  AccessSiteConnectionState connection = AccessSiteConnectionState::kIdle;
  AccessSiteProxyFaultMode fault_mode = AccessSiteProxyFaultMode::kNone;
  std::string failure_reason;
  uint64_t policy_generation = 0;
};

struct AccessSiteProxyLocalProxyReadyInfo {
  OwnershipKey owner;
  std::string proxy_group_id;
};

struct AccessSiteProxySessionPublicationInfo {
  uint64_t policy_generation = 0;
};

// Injectable PrepareCandidate → Publish → ACK (+ local proxy readiness) seam.
// Production hosts wire AccessServiceCoordinator + localhost proxy selection.
// Unit tests supply doubles. Implementations must never report DIRECT success
// on the allow path.
class AccessSiteProxySessionOrchestrating {
 public:
  virtual ~AccessSiteProxySessionOrchestrating() = default;

  // Confirms a published loopback proxy endpoint is ready for this host.
  virtual AccessSiteProxySessionError EnsureLocalProxyReady(
      const AccessSiteHost& host,
      AccessSiteProxyLocalProxyReadyInfo* out) = 0;

  // Runs PrepareCandidate → Publish → wait ACK for an ordinary mutation.
  virtual AccessSiteProxySessionError PublishAndAcknowledge(
      const SiteGroupMutationRequest& request,
      const aegis_access::RequestCancellationSelector& selector,
      AccessSiteProxySessionPublicationInfo* out) = 0;

  // Best-effort tear-down of a previously published host selection.
  virtual AccessSiteProxySessionError TearDownPublishedHost(
      const AccessSiteHost& host) = 0;
};

// Per-host product session controller: intent stays distinct from connection.
// enable: local-proxy ready → Prepare/Publish/ACK → ready
// disable: local intent commit always; service may be unavailable
class AccessSiteProxySessionController {
 public:
  explicit AccessSiteProxySessionController(
      AccessSiteProxySessionOrchestrating* orchestrator);

  AccessSiteIntentStore& intent_store() { return intent_store_; }
  const AccessSiteIntentStore& intent_store() const { return intent_store_; }

  AccessSiteProxySessionSnapshot SnapshotFor(const AccessSiteHost& host) const;

  // Allow path. On failure: intent remains allow, connection=unavailable,
  // failure_reason is set; never claims ready via DIRECT.
  AccessSiteProxySessionSnapshot Enable(const AccessSiteHost& host);

  // Off path. Local intent/off + idle always commit even when publication
  // tear-down fails (failure_reason may note the service issue).
  AccessSiteProxySessionSnapshot Disable(const AccessSiteHost& host);

  // P-mac-5: node/runtime fault while allow stays allow. Never publishes
  // DIRECT and never clears the PROXY publication intent. New requests must
  // Fail (kFailClosed) or Wait (kWait) — never silent DIRECT.
  AccessSiteProxySessionSnapshot NotifyRuntimeFault(
      const AccessSiteHost& host,
      AccessSiteProxyFaultMode mode,
      std::string_view detail = {});

  // Re-arms the allow path after the node/runtime recovers (Ensure → Publish
  // → ACK). Never claims ready via DIRECT.
  AccessSiteProxySessionSnapshot RecoverFromFault(const AccessSiteHost& host);

  // After Network Service restart: rebuild PROXY publication for an allow
  // host. Must not fall back to DIRECT while intent remains allow.
  AccessSiteProxySessionSnapshot RebuildAfterNetworkServiceRestart(
      const AccessSiteHost& host);

 private:
  AccessSiteProxySessionSnapshot Write(
      AccessSiteProxySessionSnapshot snapshot);
  AccessSiteProxySessionSnapshot MarkUnavailable(
      const AccessSiteHost& host,
      AccessSiteIntent intent,
      AccessSiteProxySessionError error,
      std::string_view detail = {});
  AccessSiteProxySessionSnapshot RepublishAllow(
      const AccessSiteHost& host,
      std::string_view operation_suffix);

  AccessSiteProxySessionOrchestrating* const orchestrator_;
  AccessSiteIntentStore intent_store_;
  std::map<AccessSiteHost, AccessSiteProxySessionSnapshot> snapshots_;
};

// Trusted inputs for evaluating a new request under the current product
// session/fault snapshot. Tests and browser fixtures supply a complete
// generation tuple and (when healthy) the registered loopback entry.
struct AccessSiteProxyFaultRouteContext {
  OwnershipKey owner;
  std::string proxy_group_id;
  aegis_access::GenerationTuple generations;
  std::optional<aegis_access::RegisteredProxyEntry> registered_proxy_entry;
};

// Plans the route a new request would take for |snapshot|. When intent is
// allow, the result is UseRegisteredProxy / Wait / Fail — never
// PreserveNative (DIRECT). Used by P-mac-5 unit and browser fixtures.
aegis_access::RoutePlan PlanSiteProxySessionRequestRoute(
    const AccessSiteProxySessionSnapshot& snapshot,
    const AccessSiteProxyFaultRouteContext& context);

// Builds ordinary mutation + cancellation selector inputs for bubble sessions.
struct AccessSiteProxySessionMutationPlan {
  AccessSiteIntentMutationResult mutation;
  aegis_access::RequestCancellationSelector selector;
};

AccessSiteProxySessionMutationPlan BuildSiteProxySessionMutationPlan(
    const AccessSiteHost& host,
    AccessSiteIntent intent,
    const OwnershipKey& owner,
    std::string_view proxy_group_id,
    std::string_view operation_suffix);

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_SESSION_H_
