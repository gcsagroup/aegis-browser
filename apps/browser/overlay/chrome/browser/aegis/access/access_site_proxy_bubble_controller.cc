// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"

#include <utility>

#include "base/strings/string_number_conversions.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/access/access_service_coordinator.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/channel_info.h"
#include "components/aegis_access/access_proxy_route_adapter.h"
#include "components/version_info/channel.h"
#include "content/public/browser/browser_thread.h"

namespace aegis::access {
namespace {

const void* const kAccessSiteProxyBubbleControllerKey =
    &kAccessSiteProxyBubbleControllerKey;

bool IsNumericLoopbackHost(std::string_view host) {
  return host == "127.0.0.1" || host == "::1" || host == "[::1]";
}

AccessSiteProxySessionError MutationStatusToSessionError(
    AccessMutationTransactionStatus status) {
  switch (status) {
    case AccessMutationTransactionStatus::kCommitted:
      return AccessSiteProxySessionError::kOk;
    case AccessMutationTransactionStatus::kBusy:
      return AccessSiteProxySessionError::kBusy;
    case AccessMutationTransactionStatus::kInvalidRequest:
    case AccessMutationTransactionStatus::kUnsupportedTransportScope:
      return AccessSiteProxySessionError::kMutationFailed;
    case AccessMutationTransactionStatus::kStoreReadFailed:
    case AccessMutationTransactionStatus::kPrepareFailed:
    case AccessMutationTransactionStatus::kCandidateBuildFailed:
      return AccessSiteProxySessionError::kPrepareFailed;
    case AccessMutationTransactionStatus::kMissingRuntime:
    case AccessMutationTransactionStatus::kMissingDispatchState:
    case AccessMutationTransactionStatus::kMissingTransport:
      return AccessSiteProxySessionError::kServiceUnavailable;
    case AccessMutationTransactionStatus::kProxySelectionUnavailable:
      return AccessSiteProxySessionError::kLocalProxyNotReady;
    case AccessMutationTransactionStatus::kPublicationTrackerRejected:
    case AccessMutationTransactionStatus::kRuntimePublicationFailed:
      return AccessSiteProxySessionError::kPublishFailed;
    case AccessMutationTransactionStatus::kNetworkPublicationFailed:
      return AccessSiteProxySessionError::kAckFailed;
    case AccessMutationTransactionStatus::kCommitFailed:
      return AccessSiteProxySessionError::kMutationFailed;
  }
  return AccessSiteProxySessionError::kMutationFailed;
}

std::string MutationStatusReadableMessage(
    AccessMutationTransactionStatus status) {
  return AccessSiteProxySessionErrorReadableMessage(
      MutationStatusToSessionError(status),
      base::NumberToString(static_cast<int>(status)));
}

}  // namespace

AccessSiteProxyBubbleController::AccessSiteProxyBubbleController(
    Profile* profile)
    : profile_(profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessSiteProxyBubbleController::~AccessSiteProxyBubbleController() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessSiteProxyBubbleController* AccessSiteProxyBubbleController::Get(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessSiteProxyBubbleController*>(
      profile->GetUserData(kAccessSiteProxyBubbleControllerKey));
}

AccessSiteProxyBubbleController* AccessSiteProxyBubbleController::GetOrCreate(
    Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  if (AccessSiteProxyBubbleController* existing = Get(profile)) {
    return existing;
  }
  auto controller = std::unique_ptr<AccessSiteProxyBubbleController>(
      new AccessSiteProxyBubbleController(profile));
  AccessSiteProxyBubbleController* raw = controller.get();
  profile->SetUserData(kAccessSiteProxyBubbleControllerKey,
                       std::move(controller));
  return raw;
}

AccessSiteProxyBubbleSnapshot
AccessSiteProxyBubbleController::SnapshotForCommittedUrl(
    const GURL& committed_url) const {
  return BuildSiteProxyBubbleSnapshot(committed_url, intent_store_,
                                      connection_state_, failure_reason_);
}

bool AccessSiteProxyBubbleController::ApplyHostProxyToggle(
    const AccessSiteHost& host,
    bool enabled) {
  return ApplySiteProxyToggle(&intent_store_, host, enabled);
}

bool AccessSiteProxyBubbleController::IsDevAllowBlockPanelRegistered() const {
  return IsAccessDevAllowBlockPanelAdmitted(chrome::GetChannel()) &&
         !IsGeneralAccessRuleEditorRegistered(chrome::GetChannel());
}

AccessDevAllowBlockPanelSnapshot
AccessSiteProxyBubbleController::DevAllowBlockSnapshotForCommittedUrl(
    const GURL& committed_url) const {
  return BuildAccessDevAllowBlockPanelSnapshot(chrome::GetChannel(),
                                               intent_store_, committed_url);
}

AccessDevAllowBlockApplyResult
AccessSiteProxyBubbleController::ApplyDevAllowBlock(
    std::string_view raw_host,
    AccessDevAllowBlockAction action) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  AccessDevAllowBlockApplyResult result = ApplyAccessDevAllowBlock(
      &intent_store_, chrome::GetChannel(), raw_host, action);
  if (result.status != AccessDevAllowBlockApplyStatus::kApplied) {
    return result;
  }
  // Keep connection line honest: block/off never claim Access readiness.
  // Allow leaves connection untouched so the product session path can advance.
  if (action == AccessDevAllowBlockAction::kBlock ||
      action == AccessDevAllowBlockAction::kOff) {
    connection_state_ = AccessSiteConnectionState::kIdle;
    failure_reason_.clear();
  }
  return result;
}

bool AccessSiteProxyBubbleController::RequestHostProxySession(
    const AccessSiteHost& host,
    bool enabled) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk) {
    failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kInvalidHost);
    connection_state_ = AccessSiteConnectionState::kUnavailable;
    return false;
  }
  if (publication_in_flight_) {
    failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kBusy);
    return false;
  }

  if (!enabled) {
    // Local commit first — disable stays allowed when the service is down.
    ApplySiteProxyToggle(&intent_store_, host, false);
    connection_state_ = AccessSiteConnectionState::kIdle;
    failure_reason_.clear();
    BeginDisablePublication(host);
    return true;
  }

  ApplySiteProxyToggle(&intent_store_, host, true);
  connection_state_ = AccessSiteConnectionState::kConnecting;
  failure_reason_.clear();

  AccessSiteProxyLocalProxyReadyInfo ready;
  const AccessSiteProxySessionError ready_status =
      EnsureLocalProxyReady(host, &ready);
  if (ready_status != AccessSiteProxySessionError::kOk) {
    connection_state_ = AccessSiteConnectionState::kUnavailable;
    failure_reason_ =
        AccessSiteProxySessionErrorReadableMessage(ready_status);
    return true;
  }

  BeginEnablePublication(host, std::move(ready));
  return true;
}

bool AccessSiteProxyBubbleController::NotifyHostProxyRuntimeFault(
    const AccessSiteHost& host,
    bool wait) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk) {
    failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kInvalidHost);
    connection_state_ = AccessSiteConnectionState::kUnavailable;
    return false;
  }
  if (intent_store_.Get(host) != AccessSiteIntent::kAllow) {
    failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kRuntimeFault,
        "site proxy is not enabled");
    return false;
  }
  // Keep allow intent and the published PROXY selection. Do not ClearProxy
  // or publish DIRECT — new requests fail or wait against the PROXY policy.
  failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
      AccessSiteProxySessionError::kRuntimeFault,
      wait ? "waiting for node recovery" : "node or runtime unavailable");
  connection_state_ = wait ? AccessSiteConnectionState::kConnecting
                           : AccessSiteConnectionState::kUnavailable;
  return true;
}

bool AccessSiteProxyBubbleController::RecoverHostProxySession(
    const AccessSiteHost& host) {
  return RequestHostProxySession(host, true);
}

bool AccessSiteProxyBubbleController::
    RebuildHostProxyAfterNetworkServiceRestart(const AccessSiteHost& host) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (intent_store_.Get(host) != AccessSiteIntent::kAllow) {
    return false;
  }
  // Republish PROXY for the allow host. RequestHostProxySession never admits
  // DIRECT on the enable path.
  return RequestHostProxySession(host, true);
}

AccessSiteProxySessionError
AccessSiteProxyBubbleController::EnsureLocalProxyReady(
    const AccessSiteHost& host,
    AccessSiteProxyLocalProxyReadyInfo* out) const {
  if (!out) {
    return AccessSiteProxySessionError::kLocalProxyUnavailable;
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  if (!transport) {
    return AccessSiteProxySessionError::kLocalProxyUnavailable;
  }
  const std::optional<OwnershipKey> owner =
      transport->OwnerForPartition(ChannelNamespace::kDev, base::FilePath());
  if (!owner || !transport->OwnsConfiguredPartition(*owner)) {
    return AccessSiteProxySessionError::kMissingOwner;
  }
  const std::optional<aegis_access::RegisteredProxyEndpoint> endpoint =
      transport->CurrentEndpoint(*owner);
  if (!endpoint) {
    return AccessSiteProxySessionError::kLocalProxyNotReady;
  }
  if (!IsNumericLoopbackHost(endpoint->host) || endpoint->port == 0 ||
      endpoint->proxy_group_id.empty() ||
      endpoint->generations.selection_generation == 0) {
    return AccessSiteProxySessionError::kLocalProxyNotReady;
  }
  if (endpoint->transport != aegis_access::RegisteredProxyTransport::kHttp &&
      endpoint->transport != aegis_access::RegisteredProxyTransport::kSocks5) {
    return AccessSiteProxySessionError::kLocalProxyNotReady;
  }
  (void)host;
  out->owner = *owner;
  out->proxy_group_id = endpoint->proxy_group_id;
  return AccessSiteProxySessionError::kOk;
}

std::unique_ptr<AccessRuleStore>
AccessSiteProxyBubbleController::OpenSessionStore(
    const OwnershipKey& owner) const {
  auto binding = TrustedAccessStoreBindingFactory::CreateEphemeral(
      owner.channel, "aegis-access-bubble-session", owner.profile_token);
  if (!binding) {
    return nullptr;
  }
  auto store = std::make_unique<AccessRuleStore>(*binding);
  if (store->Open() != StoreStatus::kValid) {
    return nullptr;
  }
  return store;
}

void AccessSiteProxyBubbleController::BeginEnablePublication(
    const AccessSiteHost& host,
    AccessSiteProxyLocalProxyReadyInfo ready) {
  auto* coordinator = AccessServiceCoordinator::GetOrCreate(profile_);
  if (!coordinator) {
    connection_state_ = AccessSiteConnectionState::kUnavailable;
    failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kMissingCoordinator);
    return;
  }

  const AccessSiteProxySessionMutationPlan plan =
      BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kAllow,
                                        ready.owner, ready.proxy_group_id,
                                        "enable");
  if (plan.mutation.status != AccessSiteIntentMutationStatus::kReady ||
      !plan.mutation.request) {
    connection_state_ = AccessSiteConnectionState::kUnavailable;
    failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
        plan.mutation.status ==
                AccessSiteIntentMutationStatus::kMissingProxyGroup
            ? AccessSiteProxySessionError::kMissingProxyGroup
            : AccessSiteProxySessionError::kPrepareFailed);
    return;
  }

  std::unique_ptr<AccessRuleStore> store;
  if (!store_retained_) {
    store = OpenSessionStore(ready.owner);
    if (!store) {
      connection_state_ = AccessSiteConnectionState::kUnavailable;
      failure_reason_ = AccessSiteProxySessionErrorReadableMessage(
          AccessSiteProxySessionError::kMissingStore);
      return;
    }
  }

  publication_in_flight_ = true;
  coordinator->CommitSiteGroupMutation(
      std::move(store), std::move(*plan.mutation.request), plan.selector,
      base::BindOnce(&AccessSiteProxyBubbleController::OnPublicationComplete,
                     weak_factory_.GetWeakPtr(), host, /*enabling=*/true));
}

void AccessSiteProxyBubbleController::BeginDisablePublication(
    const AccessSiteHost& host) {
  AccessSiteProxyLocalProxyReadyInfo ready;
  const AccessSiteProxySessionError ready_status =
      EnsureLocalProxyReady(host, &ready);
  if (ready_status != AccessSiteProxySessionError::kOk) {
    // Local off already committed; service/proxy absence is non-blocking.
    return;
  }

  auto* coordinator = AccessServiceCoordinator::Get(profile_);
  if (!coordinator) {
    return;
  }

  const AccessSiteProxySessionMutationPlan plan =
      BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kOff,
                                        ready.owner, /*proxy_group_id=*/"",
                                        "disable");
  if (plan.mutation.status != AccessSiteIntentMutationStatus::kReady ||
      !plan.mutation.request) {
    return;
  }

  std::unique_ptr<AccessRuleStore> store;
  if (!store_retained_) {
    store = OpenSessionStore(ready.owner);
    if (!store) {
      return;
    }
  }

  publication_in_flight_ = true;
  coordinator->CommitSiteGroupMutation(
      std::move(store), std::move(*plan.mutation.request), plan.selector,
      base::BindOnce(&AccessSiteProxyBubbleController::OnPublicationComplete,
                     weak_factory_.GetWeakPtr(), host, /*enabling=*/false));
}

void AccessSiteProxyBubbleController::OnPublicationComplete(
    AccessSiteHost host,
    bool enabling,
    AccessMutationTransactionResult result) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  publication_in_flight_ = false;
  if (result.status == AccessMutationTransactionStatus::kCommitted) {
    store_retained_ = true;
  }

  if (enabling) {
    if (result.status == AccessMutationTransactionStatus::kCommitted) {
      connection_state_ = AccessSiteConnectionState::kReady;
      failure_reason_.clear();
      return;
    }
    // Keep allow intent; surface readable failure (switch ≠ connectivity).
    connection_state_ = AccessSiteConnectionState::kUnavailable;
    failure_reason_ = MutationStatusReadableMessage(result.status);
    return;
  }

  // Disable: local off already applied. Note service failures without
  // reverting the local commit or claiming Access connectivity.
  connection_state_ = AccessSiteConnectionState::kIdle;
  if (result.status != AccessMutationTransactionStatus::kCommitted) {
    failure_reason_ = MutationStatusReadableMessage(result.status);
  } else {
    failure_reason_.clear();
  }
  (void)host;
}

}  // namespace aegis::access
