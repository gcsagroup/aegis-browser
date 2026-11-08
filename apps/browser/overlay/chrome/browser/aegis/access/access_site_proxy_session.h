// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_SESSION_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_PROXY_SESSION_H_

#include <map>
#include <string>
#include <string_view>

#include "chrome/browser/aegis/access/access_site_intent.h"
#include "chrome/browser/aegis/access/access_site_proxy_bubble_model.h"
#include "components/aegis_access/request_ownership_registry.h"

namespace aegis::access {

// Readable fail-closed errors for bubble → publish/ACK (P-mac-3).
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
};

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

 private:
  AccessSiteProxySessionSnapshot Write(
      AccessSiteProxySessionSnapshot snapshot);
  AccessSiteProxySessionSnapshot MarkUnavailable(
      const AccessSiteHost& host,
      AccessSiteIntent intent,
      AccessSiteProxySessionError error,
      std::string_view detail = {});

  AccessSiteProxySessionOrchestrating* const orchestrator_;
  AccessSiteIntentStore intent_store_;
  std::map<AccessSiteHost, AccessSiteProxySessionSnapshot> snapshots_;
};

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
