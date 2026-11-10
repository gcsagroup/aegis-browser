// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"

#include <utility>
#include "base/command_line.h"
#include "chrome/browser/aegis/access/access_identity_generation_source.h"
#include "chrome/browser/aegis/access/access_published_request_runtime.h"
#include "chrome/browser/aegis/access/access_proxy_selection_generation_source.h"

#include "base/strings/string_number_conversions.h"
#include "base/uuid.h"
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
    case AccessMutationTransactionStatus::kCommittedUnavailable:
      return AccessSiteProxySessionError::kRuntimeFault;
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
  const auto host = ResolveTrustedNavigationHost(committed_url);
  const auto found = host.host ? host_states_.find(*host.host) : host_states_.end();
  const HostState state = found == host_states_.end() ? HostState() : found->second;
  return BuildSiteProxyBubbleSnapshot(committed_url, intent_store_,
                                      state.connection, state.failure_reason);
}

bool AccessSiteProxyBubbleController::ApplyHostProxyToggle(
    const AccessSiteHost& host,
    bool enabled) {
  ++state_revision_;
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
  const auto host = *result.host;
  ++state_revision_;
  // Keep connection line honest: block/off never claim Access readiness.
  // Allow leaves connection untouched so the product session path can advance.
  if (action == AccessDevAllowBlockAction::kBlock ||
      action == AccessDevAllowBlockAction::kOff) {
    host_states_[host].connection = AccessSiteConnectionState::kIdle;
    host_states_[host].failure_reason.clear();
  }
  return result;
}

bool AccessSiteProxyBubbleController::RequestHostProxySession(
    const AccessSiteHost& host,
    bool enabled) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  ++state_revision_;
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk) {
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kInvalidHost);
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    return false;
  }
  if (publication_in_flight_) {
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kBusy);
    return false;
  }

  if (!enabled) {
    // DIRECT publication does not need a live proxy endpoint. Keep the
    // committed choice until the local transaction actually succeeds.
    host_states_[host].connection = AccessSiteConnectionState::kConnecting;
    host_states_[host].failure_reason.clear();
    BeginDisablePublication(host);
    return true;
  }

  host_states_[host].connection = AccessSiteConnectionState::kConnecting;
  host_states_[host].failure_reason.clear();

  publication_in_flight_ = true;
  PrepareLocalCore(host);
  return true;
}

void AccessSiteProxyBubbleController::RequestFailedNavigationProxy(
    const GURL& original_url, base::OnceCallback<void(bool)> completion) {
  const auto host = ResolveTrustedNavigationHost(original_url);
  if (!host.host || publication_in_flight_) {
    std::move(completion).Run(false);
    return;
  }
  retry_completion_ = std::move(completion);
  if (!RequestHostProxySession(*host.host, true) && retry_completion_)
    std::move(retry_completion_).Run(false);
}
base::RepeatingCallback<void(const GURL&, base::OnceCallback<void(bool)>)>
AccessSiteProxyBubbleController::GetFailedNavigationRetryHandler() {
  return base::BindRepeating(
      &AccessSiteProxyBubbleController::RequestFailedNavigationProxy,
      weak_factory_.GetWeakPtr());
}
void AccessSiteProxyBubbleController::EnsureProfileRestored(const OwnershipKey& owner) {
  if (auto* coordinator = AccessServiceCoordinator::GetOrCreate(profile_))
    coordinator->InitializeForProfile(owner, base::BindOnce(
        &AccessSiteProxyBubbleController::RestoreSavedIntents,
        weak_factory_.GetWeakPtr(), owner));
}
void AccessSiteProxyBubbleController::RestoreSavedIntents(OwnershipKey owner,
                                                         bool restored) {
  if (!restored) return;
  const auto snapshot = AccessServiceCoordinator::Get(profile_)->ReadCommittedSnapshot(
      owner.storage_partition_token);
  if (!snapshot.value) return;
  for (const auto& group : snapshot.value->site_groups) {
    if (group.members.empty() ||
        group.group.site_toggle_id != "bubble:" + group.group.canonical_host) continue;
    const auto host = MakeAccessSiteHost(group.group.canonical_host);
    if (host.host) intent_store_.Set(*host.host,
        group.members.front().policy.mode == AccessMode::kProxy
            ? AccessSiteIntent::kAllow : AccessSiteIntent::kOff);
  }
  ++state_revision_;
}
void AccessSiteProxyBubbleController::FailCorePreparation(
    const AccessSiteHost& host, std::string error) {
  publication_in_flight_ = false;
  ++state_revision_;
  host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
  host_states_[host].failure_reason = std::move(error);
  if (retry_completion_) std::move(retry_completion_).Run(false);
}
void AccessSiteProxyBubbleController::PrepareLocalCore(const AccessSiteHost& host) {
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto owner = transport
      ? transport->OwnerForPartition(ChannelNamespace::kDev, base::FilePath())
      : std::nullopt;
  if (!owner || !transport->OwnsConfiguredPartition(*owner) ||
      !IsDevAllowBlockPanelRegistered()) {
    FailCorePreparation(host, "An authorized DEV proxy binding is required.");
    return;
  }
  auto* coordinator = AccessServiceCoordinator::GetOrCreate(profile_);
  if (!coordinator) {
    FailCorePreparation(host, "Access rule storage is unavailable.");
    return;
  }
  coordinator->InitializeForProfile(*owner, base::BindOnce(
      &AccessSiteProxyBubbleController::OnProfileRestoredForCore,
      weak_factory_.GetWeakPtr(), host, *owner));
}
void AccessSiteProxyBubbleController::OnProfileRestoredForCore(
    AccessSiteHost host, OwnershipKey owner, bool restored) {
  if (!restored || (retry_completion_ && retry_completion_.IsCancelled())) {
    FailCorePreparation(host, "Access startup restoration was not completed.");
    return;
  }
  RestoreSavedIntents(owner, true);
  if (!local_core_) {
    const auto* command = base::CommandLine::ForCurrentProcess();
    const auto manifest = command->GetSwitchValuePath("aegis-access-dev-core-manifest");
    const auto node = command->GetSwitchValuePath("aegis-access-dev-node-config");
    if (manifest.empty() || node.empty()) {
      FailCorePreparation(host, "The authorized proxy configuration is unavailable.");
      return;
    }
    local_core_ = std::make_unique<AccessLocalCoreManager>(AccessLocalCoreInput{manifest, node});
  }
  local_core_->Prepare(base::BindOnce(
      &AccessSiteProxyBubbleController::OnLocalCorePrepared,
      weak_factory_.GetWeakPtr(), host, owner));
}
void AccessSiteProxyBubbleController::OnLocalCorePrepared(
    AccessSiteHost host, OwnershipKey owner, AccessLocalCoreReady result) {
  if (retry_completion_ && retry_completion_.IsCancelled()) {
    FailCorePreparation(host, "The failed navigation is no longer current.");
    return;
  }
  if (!result.ready) {
    FailCorePreparation(host, std::move(result.error));
    return;
  }
  // Core preparation does not replace actual Profile restoration or policy
  // publication. Missing sources remain a visible failure, never guessed G/S.
  auto* identity = AccessIdentityGenerationSource::GetOrCreate(profile_);
  if (!identity->binding()) identity->CommitIdentity(
      {aegis_access::AccessIdentityKind::kSignedOut, {}, {}, "dev", "authorized-local-node"});
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto common = runtime ? runtime->CaptureCommonGenerationTupleOnUiThread(owner)
                              : std::nullopt;
  if (!common || !result.local_credentials) {
    FailCorePreparation(host, "Access rules have not completed startup restoration.");
    return;
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  auto* selections = AccessProxySelectionGenerationSource::GetOrCreate(profile_);
  const std::string group = "dev-authorized-local-node";
  const auto* old = selections->binding_for_group(group);
  const bool same = old && old->endpoint_id == result.registration_id;
  const auto selected = selections->CommitSelection(
      {group, result.registration_id, "dev-process:" + result.registration_id,
       "dev-binding:" + result.registration_id,
       same ? old->binding_revision : old ? old->binding_revision + 1 : 1});
  if (selected.status != aegis_access::ProxySelectionGenerationCommitStatus::kCommitted &&
      selected.status != aegis_access::ProxySelectionGenerationCommitStatus::kUnchanged) {
    FailCorePreparation(host, "The proxy selection generation could not be committed.");
    return;
  }
  auto generations = *common;
  generations.selection_generation = selected.generation;
  if (!selected.generation || !transport->RegisterPreparedProxy({
          {result.registration_id, group, owner, generations,
           aegis_access::RegisteredProxyTransport::kHttp, "127.0.0.1", result.port},
          result.local_credentials})) {
    FailCorePreparation(host, "The prepared proxy registration could not be installed.");
    return;
  }
  AccessSiteProxyLocalProxyReadyInfo ready;
  if (EnsureLocalProxyReady(host, &ready) != AccessSiteProxySessionError::kOk) {
    FailCorePreparation(host, "The prepared proxy has not been registered with this Profile.");
    return;
  }
  const auto endpoint = transport->CurrentEndpoint(owner);
  if (!endpoint || endpoint->registration_id != result.registration_id ||
      endpoint->port != result.port) {
    FailCorePreparation(host, "The Profile proxy registration is not current.");
    return;
  }
  BeginEnablePublication(host, std::move(ready));
}
void AccessSiteProxyBubbleController::OnCommittedCoreVerified(
    AccessSiteHost host, AccessLocalCoreReady result) {
  if (!result.ready) {
    FailCorePreparation(host, std::move(result.error));
    return;
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto owner = transport
      ? transport->OwnerForPartition(ChannelNamespace::kDev, base::FilePath())
      : std::nullopt;
  const auto endpoint = owner ? transport->CurrentEndpoint(*owner) : std::nullopt;
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  auto live = owner && runtime ? runtime->CaptureCommonGenerationTupleOnUiThread(*owner)
                               : std::nullopt;
  auto registered_common = endpoint ? std::make_optional(endpoint->generations) : std::nullopt;
  if (registered_common) registered_common->selection_generation = 0;
  if (!endpoint || endpoint->registration_id != result.registration_id ||
      endpoint->port != result.port ||
      endpoint->generations.network_epoch != transport->network_epoch() ||
      !transport->HasReadyPrivateContext(*owner) || live != registered_common) {
    FailCorePreparation(host, "The proxy binding changed during verification.");
    return;
  }
  publication_in_flight_ = false;
  ++state_revision_;
  host_states_[host].connection = AccessSiteConnectionState::kReady;
  host_states_[host].failure_reason.clear();
  if (retry_completion_) std::move(retry_completion_).Run(true);
}

bool AccessSiteProxyBubbleController::NotifyHostProxyRuntimeFault(
    const AccessSiteHost& host,
    bool wait) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  ++state_revision_;
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk) {
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kInvalidHost);
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    return false;
  }
  if (intent_store_.Get(host) != AccessSiteIntent::kAllow) {
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kRuntimeFault,
        "site proxy is not enabled");
    return false;
  }
  // Keep allow intent and the published PROXY selection. Do not ClearProxy
  // or publish DIRECT — new requests fail or wait against the PROXY policy.
  host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
      AccessSiteProxySessionError::kRuntimeFault,
      wait ? "waiting for node recovery" : "node or runtime unavailable");
  host_states_[host].connection = wait ? AccessSiteConnectionState::kConnecting
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
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kMissingCoordinator);
    FailCorePreparation(host, host_states_[host].failure_reason);
    return;
  }

  std::unique_ptr<AccessRuleStore> store;
  if (!coordinator->has_retained_store()) {
    store = OpenSessionStore(ready.owner);
    if (!store) {
      host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
      host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
          AccessSiteProxySessionError::kMissingStore);
      FailCorePreparation(host, host_states_[host].failure_reason);
    return;
    }
  }

  const auto committed = store
      ? store->ReadCommittedSnapshot(ready.owner.storage_partition_token)
      : coordinator->ReadCommittedSnapshot(ready.owner.storage_partition_token);
  if (committed.status != StoreStatus::kMissing &&
      (committed.status != StoreStatus::kValid || !committed.value)) {
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    host_states_[host].failure_reason = "Access rule store requires recovery.";
    FailCorePreparation(host, host_states_[host].failure_reason);
    return;
  }
  uint64_t expected_revision = 0;
  if (committed.value) {
    for (const auto& group : committed.value->site_groups) {
      if (group.group.site_toggle_id == "bubble:" + host.value) {
        expected_revision = group.group.revision;
        break;
      }
    }
  }
  const AccessSiteProxySessionMutationPlan plan =
      BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kAllow,
                                        ready.owner, ready.proxy_group_id,
                                        base::Uuid::GenerateRandomV4().AsLowercaseString(),
                                        expected_revision);
  if (plan.mutation.status != AccessSiteIntentMutationStatus::kReady ||
      !plan.mutation.request) {
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        plan.mutation.status ==
                AccessSiteIntentMutationStatus::kMissingProxyGroup
            ? AccessSiteProxySessionError::kMissingProxyGroup
            : AccessSiteProxySessionError::kPrepareFailed);
    FailCorePreparation(host, host_states_[host].failure_reason);
    return;
  }

  publication_in_flight_ = true;
  coordinator->CommitSiteGroupMutation(
      std::move(store), std::move(*plan.mutation.request), plan.selector,
      base::BindOnce(&AccessSiteProxyBubbleController::OnPublicationComplete,
                     weak_factory_.GetWeakPtr(), host, /*enabling=*/true));
}

void AccessSiteProxyBubbleController::BeginDisablePublication(
    const AccessSiteHost& host) {
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto owner = transport
      ? transport->OwnerForPartition(ChannelNamespace::kDev, base::FilePath())
      : std::nullopt;
  auto* coordinator = AccessServiceCoordinator::GetOrCreate(profile_);
  if (!owner || !transport->OwnsConfiguredPartition(*owner) || !coordinator) {
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kServiceUnavailable);
    return;
  }
  AccessSiteProxyLocalProxyReadyInfo ready;
  ready.owner = *owner;

  std::unique_ptr<AccessRuleStore> store;
  if (!coordinator->has_retained_store()) {
    store = OpenSessionStore(ready.owner);
    if (!store) {
      return;
    }
  }

  const auto committed = store
      ? store->ReadCommittedSnapshot(ready.owner.storage_partition_token)
      : coordinator->ReadCommittedSnapshot(ready.owner.storage_partition_token);
  if (committed.status != StoreStatus::kMissing &&
      (committed.status != StoreStatus::kValid || !committed.value)) {
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    host_states_[host].failure_reason = "Access rule store requires recovery.";
    return;
  }
  uint64_t expected_revision = 0;
  if (committed.value) {
    for (const auto& group : committed.value->site_groups) {
      if (group.group.site_toggle_id == "bubble:" + host.value) {
        expected_revision = group.group.revision;
        break;
      }
    }
  }
  const AccessSiteProxySessionMutationPlan plan =
      BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kOff,
                                        ready.owner, /*proxy_group_id=*/"",
                                        base::Uuid::GenerateRandomV4().AsLowercaseString(),
                                        expected_revision);
  if (plan.mutation.status != AccessSiteIntentMutationStatus::kReady ||
      !plan.mutation.request) {
    return;
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
  ++state_revision_;
  if (result.status == AccessMutationTransactionStatus::kCommitted ||
      result.status == AccessMutationTransactionStatus::kCommittedUnavailable) {
    ApplySiteProxyToggle(&intent_store_, host, enabling);
  }

  if (enabling) {
    if (result.status == AccessMutationTransactionStatus::kCommitted) {
      publication_in_flight_ = true;
      local_core_->Verify(base::BindOnce(
          &AccessSiteProxyBubbleController::OnCommittedCoreVerified,
          weak_factory_.GetWeakPtr(), host));
      return;
    }
    // Preserve the last committed choice; preparation is not a commit.
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    host_states_[host].failure_reason = MutationStatusReadableMessage(result.status);
    if (retry_completion_) std::move(retry_completion_).Run(false);
    return;
  }

  // A failed disable must not display an uncommitted OFF choice.
  host_states_[host].connection = result.status == AccessMutationTransactionStatus::kCommitted
      ? AccessSiteConnectionState::kIdle : AccessSiteConnectionState::kUnavailable;
  if (result.status != AccessMutationTransactionStatus::kCommitted) {
    host_states_[host].failure_reason = MutationStatusReadableMessage(result.status);
  } else {
    host_states_[host].failure_reason.clear();
  }
  (void)host;
}

}  // namespace aegis::access
