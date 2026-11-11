// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_session.h"

#include <utility>

#include "base/strings/strcat.h"
#include "components/aegis_access/access_route_planner.h"

namespace aegis::access {
namespace {

std::string DetailOr(std::string_view detail, std::string_view fallback) {
  return detail.empty() ? std::string(fallback) : std::string(detail);
}

}  // namespace

std::string_view AccessSiteProxyFaultModeToString(
    AccessSiteProxyFaultMode mode) {
  switch (mode) {
    case AccessSiteProxyFaultMode::kNone:
      return "none";
    case AccessSiteProxyFaultMode::kFailClosed:
      return "fail-closed";
    case AccessSiteProxyFaultMode::kWait:
      return "wait";
  }
  return "fail-closed";
}

std::string_view AccessSiteProxySessionErrorToString(
    AccessSiteProxySessionError error) {
  switch (error) {
    case AccessSiteProxySessionError::kOk:
      return "ok";
    case AccessSiteProxySessionError::kInvalidHost:
      return "invalid-host";
    case AccessSiteProxySessionError::kLocalProxyUnavailable:
      return "local-proxy-unavailable";
    case AccessSiteProxySessionError::kLocalProxyNotReady:
      return "local-proxy-not-ready";
    case AccessSiteProxySessionError::kMissingOwner:
      return "missing-owner";
    case AccessSiteProxySessionError::kMissingCoordinator:
      return "missing-coordinator";
    case AccessSiteProxySessionError::kMissingStore:
      return "missing-store";
    case AccessSiteProxySessionError::kMissingProxyGroup:
      return "missing-proxy-group";
    case AccessSiteProxySessionError::kPrepareFailed:
      return "prepare-failed";
    case AccessSiteProxySessionError::kPublishFailed:
      return "publish-failed";
    case AccessSiteProxySessionError::kAckFailed:
      return "ack-failed";
    case AccessSiteProxySessionError::kMutationFailed:
      return "mutation-failed";
    case AccessSiteProxySessionError::kServiceUnavailable:
      return "service-unavailable";
    case AccessSiteProxySessionError::kBusy:
      return "busy";
    case AccessSiteProxySessionError::kDirectFallbackNotAdmitted:
      return "direct-fallback-not-admitted";
    case AccessSiteProxySessionError::kTearDownFailed:
      return "tear-down-failed";
    case AccessSiteProxySessionError::kRuntimeFault:
      return "runtime-fault";
    case AccessSiteProxySessionError::kNetworkServiceRebuildFailed:
      return "network-service-rebuild-failed";
  }
  return "mutation-failed";
}

std::string AccessSiteProxySessionErrorReadableMessage(
    AccessSiteProxySessionError error,
    std::string_view detail) {
  switch (error) {
    case AccessSiteProxySessionError::kOk:
      return std::string();
    case AccessSiteProxySessionError::kInvalidHost:
      return "Site host is not a trusted exact host for Access.";
    case AccessSiteProxySessionError::kLocalProxyUnavailable:
      return "Local Access proxy is unavailable for this profile.";
    case AccessSiteProxySessionError::kLocalProxyNotReady:
      return base::StrCat(
          {"Local Access proxy is not ready: ",
           DetailOr(detail, "no loopback endpoint published")});
    case AccessSiteProxySessionError::kMissingOwner:
      return "Access ownership for this profile partition is missing.";
    case AccessSiteProxySessionError::kMissingCoordinator:
      return "Access service coordinator is unavailable.";
    case AccessSiteProxySessionError::kMissingStore:
      return "Access rule store could not be opened.";
    case AccessSiteProxySessionError::kMissingProxyGroup:
      return "No Access proxy group is bound for publication.";
    case AccessSiteProxySessionError::kPrepareFailed:
      return base::StrCat(
          {"Failed to prepare Access candidate: ", DetailOr(detail, "prepare")});
    case AccessSiteProxySessionError::kPublishFailed:
      return base::StrCat(
          {"Failed to publish Access session: ", DetailOr(detail, "publish")});
    case AccessSiteProxySessionError::kAckFailed:
      return base::StrCat(
          {"Access session acknowledgement failed: ",
           DetailOr(detail, "ack")});
    case AccessSiteProxySessionError::kMutationFailed:
      return base::StrCat(
          {"Access site mutation failed: ", DetailOr(detail, "mutation")});
    case AccessSiteProxySessionError::kServiceUnavailable:
      return base::StrCat(
          {"Access service is unavailable: ",
           DetailOr(detail, "service down")});
    case AccessSiteProxySessionError::kBusy:
      return "Another Access site mutation is already in progress.";
    case AccessSiteProxySessionError::kDirectFallbackNotAdmitted:
      return "Direct fallback is not admitted on the allow path.";
    case AccessSiteProxySessionError::kTearDownFailed:
      return base::StrCat(
          {"Failed to tear down Access session: ",
           DetailOr(detail, "tear-down")});
    case AccessSiteProxySessionError::kRuntimeFault:
      return base::StrCat(
          {"Access node or runtime fault: ",
           DetailOr(detail, "new requests fail closed without DIRECT")});
    case AccessSiteProxySessionError::kNetworkServiceRebuildFailed:
      return base::StrCat(
          {"Failed to rebuild Access proxy after Network Service restart: ",
           DetailOr(detail, "rebuild")});
  }
  return "Access session failed.";
}

std::string_view AccessSiteProxySessionPhaseToString(
    AccessSiteProxySessionPhase phase) {
  switch (phase) {
    case AccessSiteProxySessionPhase::kIdle:
      return "idle";
    case AccessSiteProxySessionPhase::kPreparingCandidate:
      return "preparing-candidate";
    case AccessSiteProxySessionPhase::kPublishing:
      return "publishing";
    case AccessSiteProxySessionPhase::kAwaitingAck:
      return "awaiting-ack";
    case AccessSiteProxySessionPhase::kReady:
      return "ready";
    case AccessSiteProxySessionPhase::kUnavailable:
      return "unavailable";
  }
  return "unavailable";
}

AccessSiteProxySessionMutationPlan BuildSiteProxySessionMutationPlan(
    const AccessSiteHost& host,
    AccessSiteIntent intent,
    const OwnershipKey& owner,
    std::string_view proxy_group_id,
    std::string_view operation_suffix) {
  AccessSiteProxySessionMutationPlan plan;
  AccessSiteIntentMutationInput input;
  input.intent = intent;
  input.host = host;
  input.owner = owner;
  input.site_toggle_id = base::StrCat({"bubble:", host.value});
  input.operation_id =
      base::StrCat({"bubble-session:", host.value, ":", operation_suffix});
  input.request_fingerprint = input.operation_id;
  input.proxy_group_id =
      intent == AccessSiteIntent::kAllow ? std::string(proxy_group_id)
                                         : std::string();
  plan.mutation = BuildOrdinarySiteGroupMutation(input);

  plan.selector.owner = owner;
  plan.selector.document_token =
      base::StrCat({"bubble-session-doc:", host.value});
  plan.selector.top_level_site = base::StrCat({"https://", host.value});
  plan.selector.exact_host = host.value;
  plan.selector.scheme = RequestScheme::kHttps;
  plan.selector.port = 443;
  return plan;
}

AccessSiteProxySessionController::AccessSiteProxySessionController(
    AccessSiteProxySessionOrchestrating* orchestrator)
    : orchestrator_(orchestrator) {}

AccessSiteProxySessionSnapshot AccessSiteProxySessionController::SnapshotFor(
    const AccessSiteHost& host) const {
  const auto it = snapshots_.find(host);
  if (it != snapshots_.end()) {
    return it->second;
  }
  AccessSiteProxySessionSnapshot snapshot;
  snapshot.host = host;
  snapshot.intent = intent_store_.Get(host);
  snapshot.phase = snapshot.intent == AccessSiteIntent::kOff
                       ? AccessSiteProxySessionPhase::kIdle
                       : AccessSiteProxySessionPhase::kUnavailable;
  snapshot.connection = AccessSiteConnectionState::kIdle;
  return snapshot;
}

AccessSiteProxySessionSnapshot AccessSiteProxySessionController::Enable(
    const AccessSiteHost& host) {
  return RepublishAllow(host, "enable");
}

AccessSiteProxySessionSnapshot
AccessSiteProxySessionController::NotifyRuntimeFault(
    const AccessSiteHost& host,
    AccessSiteProxyFaultMode mode,
    std::string_view detail) {
  if (mode == AccessSiteProxyFaultMode::kNone) {
    return SnapshotFor(host);
  }
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk) {
    return MarkUnavailable(host, AccessSiteIntent::kAllow,
                           AccessSiteProxySessionError::kInvalidHost);
  }

  // Keep product intent on allow. Do not publish DIRECT and do not tear down
  // the PROXY selection — new requests must Fail or Wait against that policy.
  intent_store_.Set(host, AccessSiteIntent::kAllow);
  const auto prior = SnapshotFor(host);
  AccessSiteProxySessionSnapshot snap;
  snap.host = host;
  snap.intent = AccessSiteIntent::kAllow;
  snap.fault_mode = mode;
  snap.policy_generation = prior.policy_generation;
  snap.failure_reason = AccessSiteProxySessionErrorReadableMessage(
      AccessSiteProxySessionError::kRuntimeFault, detail);
  if (mode == AccessSiteProxyFaultMode::kWait) {
    snap.phase = AccessSiteProxySessionPhase::kPreparingCandidate;
    snap.connection = AccessSiteConnectionState::kConnecting;
  } else {
    snap.phase = AccessSiteProxySessionPhase::kUnavailable;
    snap.connection = AccessSiteConnectionState::kUnavailable;
  }
  return Write(std::move(snap));
}

AccessSiteProxySessionSnapshot
AccessSiteProxySessionController::RecoverFromFault(
    const AccessSiteHost& host) {
  return RepublishAllow(host, "recover");
}

AccessSiteProxySessionSnapshot
AccessSiteProxySessionController::RebuildAfterNetworkServiceRestart(
    const AccessSiteHost& host) {
  if (intent_store_.Get(host) != AccessSiteIntent::kAllow) {
    return SnapshotFor(host);
  }
  AccessSiteProxySessionSnapshot snap =
      RepublishAllow(host, "network-service-rebuild");
  if (snap.phase != AccessSiteProxySessionPhase::kReady) {
    snap.failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kNetworkServiceRebuildFailed,
        snap.failure_reason);
    return Write(std::move(snap));
  }
  return snap;
}

AccessSiteProxySessionSnapshot
AccessSiteProxySessionController::RepublishAllow(
    const AccessSiteHost& host,
    std::string_view operation_suffix) {
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk ||
      !orchestrator_) {
    return MarkUnavailable(host, AccessSiteIntent::kAllow,
                           !orchestrator_
                               ? AccessSiteProxySessionError::kServiceUnavailable
                               : AccessSiteProxySessionError::kInvalidHost);
  }

  intent_store_.Set(host, AccessSiteIntent::kAllow);
  Write({.host = host,
         .intent = AccessSiteIntent::kAllow,
         .phase = AccessSiteProxySessionPhase::kPreparingCandidate,
         .connection = AccessSiteConnectionState::kConnecting,
         .fault_mode = AccessSiteProxyFaultMode::kNone});

  AccessSiteProxyLocalProxyReadyInfo ready_info;
  const AccessSiteProxySessionError ready_status =
      orchestrator_->EnsureLocalProxyReady(host, &ready_info);
  if (ready_status != AccessSiteProxySessionError::kOk) {
    return MarkUnavailable(host, AccessSiteIntent::kAllow, ready_status);
  }
  if (ready_info.proxy_group_id.empty()) {
    return MarkUnavailable(host, AccessSiteIntent::kAllow,
                           AccessSiteProxySessionError::kMissingProxyGroup);
  }

  Write({.host = host,
         .intent = AccessSiteIntent::kAllow,
         .phase = AccessSiteProxySessionPhase::kPublishing,
         .connection = AccessSiteConnectionState::kConnecting,
         .fault_mode = AccessSiteProxyFaultMode::kNone});

  const AccessSiteProxySessionMutationPlan plan =
      BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kAllow,
                                        ready_info.owner,
                                        ready_info.proxy_group_id,
                                        operation_suffix);
  if (plan.mutation.status != AccessSiteIntentMutationStatus::kReady ||
      !plan.mutation.request.has_value()) {
    return MarkUnavailable(
        host, AccessSiteIntent::kAllow,
        plan.mutation.status ==
                AccessSiteIntentMutationStatus::kMissingProxyGroup
            ? AccessSiteProxySessionError::kMissingProxyGroup
            : AccessSiteProxySessionError::kPrepareFailed);
  }

  // Allow-path mutations must stay PROXY. Reject any accidental DIRECT plan.
  for (const auto& member : plan.mutation.request->candidate_members) {
    if (member.mode != AccessMode::kProxy) {
      return MarkUnavailable(
          host, AccessSiteIntent::kAllow,
          AccessSiteProxySessionError::kDirectFallbackNotAdmitted);
    }
  }

  Write({.host = host,
         .intent = AccessSiteIntent::kAllow,
         .phase = AccessSiteProxySessionPhase::kAwaitingAck,
         .connection = AccessSiteConnectionState::kConnecting,
         .fault_mode = AccessSiteProxyFaultMode::kNone});

  AccessSiteProxySessionPublicationInfo publication;
  const AccessSiteProxySessionError publish_status =
      orchestrator_->PublishAndAcknowledge(*plan.mutation.request,
                                           plan.selector, &publication);
  if (publish_status != AccessSiteProxySessionError::kOk) {
    (void)orchestrator_->TearDownPublishedHost(host);
    return MarkUnavailable(host, AccessSiteIntent::kAllow, publish_status);
  }

  return Write({.host = host,
                .intent = AccessSiteIntent::kAllow,
                .phase = AccessSiteProxySessionPhase::kReady,
                .connection = AccessSiteConnectionState::kReady,
                .fault_mode = AccessSiteProxyFaultMode::kNone,
                .policy_generation = publication.policy_generation});
}

AccessSiteProxySessionSnapshot AccessSiteProxySessionController::Disable(
    const AccessSiteHost& host) {
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk) {
    AccessSiteProxySessionSnapshot snap;
    snap.host = host;
    snap.intent = AccessSiteIntent::kOff;
    snap.phase = AccessSiteProxySessionPhase::kIdle;
    snap.connection = AccessSiteConnectionState::kIdle;
    snap.fault_mode = AccessSiteProxyFaultMode::kNone;
    snap.failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kInvalidHost);
    intent_store_.Set(host, AccessSiteIntent::kOff);
    return Write(std::move(snap));
  }

  // Local commit first — disable must succeed even when the service is down.
  intent_store_.Set(host, AccessSiteIntent::kOff);
  AccessSiteProxySessionSnapshot local = {
      .host = host,
      .intent = AccessSiteIntent::kOff,
      .phase = AccessSiteProxySessionPhase::kIdle,
      .connection = AccessSiteConnectionState::kIdle,
      .fault_mode = AccessSiteProxyFaultMode::kNone,
  };

  if (!orchestrator_) {
    local.failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kServiceUnavailable);
    return Write(std::move(local));
  }

  AccessSiteProxyLocalProxyReadyInfo ready_info;
  const AccessSiteProxySessionError ready_status =
      orchestrator_->EnsureLocalProxyReady(host, &ready_info);
  if (ready_status == AccessSiteProxySessionError::kOk &&
      !ready_info.proxy_group_id.empty()) {
    const AccessSiteProxySessionMutationPlan plan =
        BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kOff,
                                          ready_info.owner,
                                          /*proxy_group_id=*/"", "disable");
    if (plan.mutation.status == AccessSiteIntentMutationStatus::kReady &&
        plan.mutation.request.has_value()) {
      AccessSiteProxySessionPublicationInfo publication;
      const AccessSiteProxySessionError publish_status =
          orchestrator_->PublishAndAcknowledge(*plan.mutation.request,
                                               plan.selector, &publication);
      if (publish_status != AccessSiteProxySessionError::kOk) {
        local.failure_reason =
            AccessSiteProxySessionErrorReadableMessage(publish_status);
      }
    }
  } else {
    const AccessSiteProxySessionError tear_down =
        orchestrator_->TearDownPublishedHost(host);
    if (tear_down != AccessSiteProxySessionError::kOk &&
        tear_down != AccessSiteProxySessionError::kServiceUnavailable &&
        tear_down != AccessSiteProxySessionError::kLocalProxyUnavailable &&
        tear_down != AccessSiteProxySessionError::kLocalProxyNotReady) {
      local.failure_reason =
          AccessSiteProxySessionErrorReadableMessage(tear_down);
    }
  }

  return Write(std::move(local));
}

AccessSiteProxySessionSnapshot AccessSiteProxySessionController::Write(
    AccessSiteProxySessionSnapshot snapshot) {
  snapshots_[snapshot.host] = snapshot;
  return snapshot;
}

AccessSiteProxySessionSnapshot
AccessSiteProxySessionController::MarkUnavailable(
    const AccessSiteHost& host,
    AccessSiteIntent intent,
    AccessSiteProxySessionError error,
    std::string_view detail) {
  intent_store_.Set(host, intent);
  return Write({.host = host,
                .intent = intent,
                .phase = AccessSiteProxySessionPhase::kUnavailable,
                .connection = AccessSiteConnectionState::kUnavailable,
                .fault_mode = AccessSiteProxyFaultMode::kNone,
                .failure_reason = AccessSiteProxySessionErrorReadableMessage(
                    error, detail)});
}

aegis_access::RoutePlan PlanSiteProxySessionRequestRoute(
    const AccessSiteProxySessionSnapshot& snapshot,
    const AccessSiteProxyFaultRouteContext& context) {
  using aegis_access::AccessMode;
  using aegis_access::PolicyScope;
  using aegis_access::PolicyState;
  using aegis_access::ProxyRuntimeState;
  using aegis_access::RouteAction;
  using aegis_access::RouteInput;
  using aegis_access::RoutePlan;
  using aegis_access::SnapshotState;

  RouteInput input;
  input.request_owner = context.owner;
  input.snapshot_owner = context.owner;
  input.request_generations = context.generations;
  input.snapshot_generations = context.generations;
  input.snapshot_state = SnapshotState::kPublished;
  input.protection_restriction =
      aegis_access::ProtectionRestriction::kNone;
  input.managed_restriction = aegis_access::ManagedRestriction::kNone;
  input.site_ownership_reliable = true;

  if (snapshot.intent != AccessSiteIntent::kAllow) {
    input.policy_state = PolicyState::kAbsent;
    input.effective_mode = AccessMode::kNone;
    input.policy_scope = PolicyScope::kNone;
    input.require_proxy_intent = false;
    input.runtime_state = ProxyRuntimeState::kStopped;
    return aegis_access::PlanAccessRoute(input);
  }

  // Allow intent requires PROXY. Fault must Fail or Wait — never DIRECT.
  input.policy_state = PolicyState::kValid;
  input.effective_mode = AccessMode::kProxy;
  input.policy_scope = PolicyScope::kSite;
  input.effective_proxy_group_id = context.proxy_group_id;
  input.require_proxy_intent = true;

  if (snapshot.fault_mode == AccessSiteProxyFaultMode::kWait) {
    input.runtime_state = ProxyRuntimeState::kRecovering;
    input.registered_proxy_entry = context.registered_proxy_entry;
    return aegis_access::PlanAccessRoute(input);
  }
  if (snapshot.fault_mode == AccessSiteProxyFaultMode::kFailClosed ||
      snapshot.phase == AccessSiteProxySessionPhase::kUnavailable ||
      snapshot.connection == AccessSiteConnectionState::kUnavailable) {
    input.runtime_state = ProxyRuntimeState::kOffline;
    input.registered_proxy_entry = context.registered_proxy_entry;
    return aegis_access::PlanAccessRoute(input);
  }
  if (snapshot.phase == AccessSiteProxySessionPhase::kReady &&
      snapshot.connection == AccessSiteConnectionState::kReady) {
    input.runtime_state = ProxyRuntimeState::kReady;
    input.registered_proxy_entry = context.registered_proxy_entry;
    return aegis_access::PlanAccessRoute(input);
  }

  // Connecting / preparing without an explicit wait fault still waits.
  input.runtime_state = ProxyRuntimeState::kPreparing;
  input.registered_proxy_entry = context.registered_proxy_entry;
  const RoutePlan plan = aegis_access::PlanAccessRoute(input);
  // Secondary guard: allow-path plans must never preserve native DIRECT.
  if (plan.action == RouteAction::kPreserveNative) {
    RoutePlan denied = plan;
    denied.action = RouteAction::kFail;
    denied.reason = aegis_access::RouteReason::kProxyUnavailable;
    return denied;
  }
  return plan;
}

}  // namespace aegis::access
