// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_PUBLISHED_REQUEST_RUNTIME_H_
#define COMPONENTS_AEGIS_ACCESS_PUBLISHED_REQUEST_RUNTIME_H_

#include <cstdint>
#include <optional>
#include <string>

#include "components/aegis_access/access_route_types.h"
#include "components/aegis_access/request_dispatch_gate.h"

namespace aegis_access {

enum class PublishedRequestRuntimeStatus {
  kDispatchRegistered,
  kWait,
  kDeny,
  kFail,
  kBlockedByBarrier,
  kRegistrationFailed,
  kStalePolicyGeneration,
};

// Browser-owned request identity plus a policy decision that was evaluated from
// one immutable published snapshot. This neutral layer deliberately receives
// no URL, renderer identity, storage or network handles.
struct PublishedRequestRuntimeInput {
  RequestOwnershipRecord request;

  PolicyState policy_state = PolicyState::kInvalid;
  AccessMode effective_mode = AccessMode::kInvalid;
  PolicyScope policy_scope = PolicyScope::kInvalid;
  std::string effective_proxy_group_id;
  uint64_t matched_policy_generation = 0;
  bool require_proxy_intent = false;

  SnapshotState snapshot_state = SnapshotState::kInvalid;
  OwnershipKey snapshot_owner;
  GenerationTuple snapshot_generations;

  ProtectionRestriction protection_restriction =
      ProtectionRestriction::kInvalid;
  ManagedRestriction managed_restriction = ManagedRestriction::kInvalid;
  ProxyRuntimeState runtime_state = ProxyRuntimeState::kInvalid;
  std::optional<RegisteredProxyEntry> registered_proxy_entry;

  friend bool operator==(const PublishedRequestRuntimeInput&,
                         const PublishedRequestRuntimeInput&) = default;
};

struct PublishedRequestRuntimeResult {
  PublishedRequestRuntimeStatus status = PublishedRequestRuntimeStatus::kFail;
  RoutePlan route_plan;
  RequestDispatchGateResult dispatch_gate;
};

// Resolves the final route from already trusted/published inputs. A route that
// could send bytes is returned as dispatchable only after the synchronous BLOCK
// barrier check and ownership registration both succeed. WAIT/DENY/FAIL never
// mutate the ownership registry.
PublishedRequestRuntimeResult EvaluatePublishedRequestForDispatch(
    const PublishedRequestRuntimeInput& input,
    const RequestDispatchBarrierRegistry& barriers,
    RequestOwnershipRegistry& ownership_registry);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_PUBLISHED_REQUEST_RUNTIME_H_
