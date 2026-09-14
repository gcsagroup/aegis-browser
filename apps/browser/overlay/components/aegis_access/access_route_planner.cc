// Copyright 2026 GCSA

#include "components/aegis_access/access_route_planner.h"

namespace aegis_access {
namespace {

bool IsKnownChannel(ChannelNamespace channel) {
  switch (channel) {
    case ChannelNamespace::kDev:
    case ChannelNamespace::kAlpha:
    case ChannelNamespace::kBeta:
    case ChannelNamespace::kRelease:
      return true;
    case ChannelNamespace::kInvalid:
      return false;
  }
  return false;
}

bool IsComplete(const OwnershipKey& owner) {
  return IsKnownChannel(owner.channel) && !owner.profile_token.empty() &&
         !owner.storage_partition_token.empty();
}

bool IsComplete(const GenerationTuple& generations) {
  return generations.policy_generation != 0 &&
         generations.identity_generation != 0 &&
         generations.selection_generation != 0 &&
         generations.network_epoch != 0 &&
         generations.base_proxy_config_generation != 0;
}

bool IsKnown(ProtectionRestriction restriction) {
  switch (restriction) {
    case ProtectionRestriction::kNone:
    case ProtectionRestriction::kDeny:
      return true;
    case ProtectionRestriction::kInvalid:
      return false;
  }
  return false;
}

bool IsKnown(ManagedRestriction restriction) {
  switch (restriction) {
    case ManagedRestriction::kNone:
    case ManagedRestriction::kForceProxy:
    case ManagedRestriction::kForceDirect:
    case ManagedRestriction::kCustomProxyForbidden:
      return true;
    case ManagedRestriction::kInvalid:
      return false;
  }
  return false;
}

bool IsKnown(ProxyRuntimeState state) {
  switch (state) {
    case ProxyRuntimeState::kStopped:
    case ProxyRuntimeState::kPreparing:
    case ProxyRuntimeState::kReady:
    case ProxyRuntimeState::kRecovering:
    case ProxyRuntimeState::kOffline:
    case ProxyRuntimeState::kQuotaExhausted:
    case ProxyRuntimeState::kSignedOut:
    case ProxyRuntimeState::kUnavailable:
      return true;
    case ProxyRuntimeState::kInvalid:
      return false;
  }
  return false;
}

bool IsKnown(SnapshotState state) {
  switch (state) {
    case SnapshotState::kMissing:
    case SnapshotState::kRestoring:
    case SnapshotState::kPublished:
    case SnapshotState::kCorrupt:
      return true;
    case SnapshotState::kInvalid:
      return false;
  }
  return false;
}

bool IsValidPolicyShape(const RouteInput& input) {
  switch (input.policy_state) {
    case PolicyState::kAbsent:
      return input.effective_mode == AccessMode::kNone &&
             input.policy_scope == PolicyScope::kNone &&
             input.effective_proxy_group_id.empty();
    case PolicyState::kValid:
      if (input.policy_scope != PolicyScope::kSite &&
          input.policy_scope != PolicyScope::kProfile) {
        return false;
      }
      if (input.effective_mode == AccessMode::kProxy) {
        return !input.effective_proxy_group_id.empty();
      }
      return (input.effective_mode == AccessMode::kDirect ||
              input.effective_mode == AccessMode::kReject) &&
             input.effective_proxy_group_id.empty();
    case PolicyState::kConflict:
    case PolicyState::kInvalid:
      return false;
  }
  return false;
}

RoutePlan MakePlan(const RouteInput& input,
                   RouteAction action,
                   RouteReason reason) {
  return RoutePlan{action, input.effective_mode, reason,
                   input.request_generations, std::nullopt};
}

}  // namespace

RoutePlan PlanAccessRoute(const RouteInput& input) {
  // Fix error precedence before examining any runtime branch. Unknown enum
  // values and contradictory policy shapes never reach a permissive result.
  if (input.policy_state == PolicyState::kConflict) {
    return MakePlan(input, RouteAction::kFail, RouteReason::kPolicyConflict);
  }
  if (!IsValidPolicyShape(input) ||
      !IsKnown(input.protection_restriction) ||
      !IsKnown(input.managed_restriction) || !IsKnown(input.runtime_state) ||
      !IsKnown(input.snapshot_state) ||
      !IsComplete(input.request_generations)) {
    return MakePlan(input, RouteAction::kFail, RouteReason::kInvalidPolicy);
  }
  if (!IsComplete(input.request_owner)) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kOwnershipMismatch);
  }
  if (input.policy_state == PolicyState::kValid &&
      input.policy_scope == PolicyScope::kSite &&
      !input.site_ownership_reliable) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kSiteOwnershipUnavailable);
  }

  // Locally reliable denial is safe even while a runtime snapshot is absent.
  if (input.protection_restriction == ProtectionRestriction::kDeny) {
    return MakePlan(input, RouteAction::kDeny,
                    RouteReason::kProtectionRestriction);
  }
  if (input.policy_state == PolicyState::kValid &&
      input.effective_mode == AccessMode::kReject) {
    return MakePlan(input, RouteAction::kDeny, RouteReason::kNone);
  }

  if (input.snapshot_state == SnapshotState::kMissing) {
    return MakePlan(input, RouteAction::kWait,
                    RouteReason::kMissingSnapshot);
  } else if (input.snapshot_state == SnapshotState::kRestoring) {
    return MakePlan(input, RouteAction::kWait,
                    RouteReason::kSnapshotNotReady);
  } else if (input.snapshot_state == SnapshotState::kCorrupt) {
    return MakePlan(input, RouteAction::kFail, RouteReason::kInvalidPolicy);
  } else {
    if (!IsComplete(input.snapshot_owner) ||
        input.request_owner != input.snapshot_owner) {
      return MakePlan(input, RouteAction::kFail,
                      RouteReason::kOwnershipMismatch);
    }
    if (!IsComplete(input.snapshot_generations) ||
        input.request_generations != input.snapshot_generations) {
      return MakePlan(input, RouteAction::kFail,
                      RouteReason::kStaleGeneration);
    }
  }

  if (input.require_proxy_intent &&
      (input.policy_state != PolicyState::kValid ||
       input.effective_mode != AccessMode::kProxy)) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kInvalidPolicy);
  }

  if (input.policy_state == PolicyState::kAbsent ||
      input.effective_mode == AccessMode::kDirect) {
    return MakePlan(input, RouteAction::kPreserveNative, RouteReason::kNone);
  }

  // Only PROXY reaches this point. Managed restrictions preserve the selected
  // mode while stopping the affected business operation.
  if (input.managed_restriction != ManagedRestriction::kNone) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kManagedRestriction);
  }

  switch (input.runtime_state) {
    case ProxyRuntimeState::kPreparing:
    case ProxyRuntimeState::kRecovering:
      return MakePlan(input, RouteAction::kWait,
                      RouteReason::kProxyUnavailable);
    case ProxyRuntimeState::kQuotaExhausted:
      return MakePlan(input, RouteAction::kFail,
                      RouteReason::kQuotaExhausted);
    case ProxyRuntimeState::kSignedOut:
      return MakePlan(input, RouteAction::kFail, RouteReason::kSignedOut);
    case ProxyRuntimeState::kStopped:
    case ProxyRuntimeState::kOffline:
    case ProxyRuntimeState::kUnavailable:
      return MakePlan(input, RouteAction::kFail,
                      RouteReason::kProxyUnavailable);
    case ProxyRuntimeState::kReady:
      break;
    case ProxyRuntimeState::kInvalid:
      return MakePlan(input, RouteAction::kFail,
                      RouteReason::kInvalidPolicy);
  }

  if (!input.registered_proxy_entry.has_value() ||
      input.registered_proxy_entry->registration_id.empty() ||
      input.registered_proxy_entry->proxy_group_id.empty()) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kProxyUnavailable);
  }
  if (!IsComplete(input.registered_proxy_entry->owner) ||
      input.registered_proxy_entry->owner != input.request_owner) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kOwnershipMismatch);
  }
  if (!IsComplete(input.registered_proxy_entry->generations) ||
      input.registered_proxy_entry->generations !=
          input.request_generations) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kStaleGeneration);
  }
  if (input.registered_proxy_entry->proxy_group_id !=
      input.effective_proxy_group_id) {
    return MakePlan(input, RouteAction::kFail,
                    RouteReason::kProxyUnavailable);
  }

  RoutePlan plan = MakePlan(input, RouteAction::kUseRegisteredProxy,
                            RouteReason::kNone);
  plan.registered_proxy_entry = input.registered_proxy_entry;
  return plan;
}

}  // namespace aegis_access
