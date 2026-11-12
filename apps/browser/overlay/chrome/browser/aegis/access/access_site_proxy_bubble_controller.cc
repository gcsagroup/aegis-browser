// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_site_proxy_bubble_controller.h"
#include "chrome/browser/aegis/access/access_build_channel.h"

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
#include "chrome/browser/aegis/aegis_prefs.h"
#include "components/prefs/pref_service.h"
#include "build/build_config.h"
#if BUILDFLAG(IS_MAC)
#include "chrome/browser/lifetime/termination_notification.h"
#include "chrome/browser/aegis/access/access_core_log_share.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "third_party/blink/public/mojom/webshare/webshare.mojom.h"
#endif
#include "components/aegis_access/access_proxy_route_adapter.h"
#include "components/version_info/channel.h"
#include "content/public/browser/browser_thread.h"

namespace aegis::access {
namespace {

const void* const kAccessSiteProxyBubbleControllerKey =
    &kAccessSiteProxyBubbleControllerKey;

#if BUILDFLAG(IS_MAC)
const void* const kLogHistoryKey = &kLogHistoryKey;
// Keep both stores on the original profile. Reopening an incognito window
// reuses its own private store even while the previous core is shutting down.
class ProfileLogHistories : public base::SupportsUserData::Data {
 public:
  scoped_refptr<AccessCoreLogStore> regular;
  scoped_refptr<AccessCoreLogStore> private_history;
};
scoped_refptr<AccessCoreLogStore> GetCoreLogHistory(Profile* profile) {
  Profile* original = profile->GetOriginalProfile();
  auto* histories = static_cast<ProfileLogHistories*>(original->GetUserData(kLogHistoryKey));
  if (!histories) {
    auto owned = std::make_unique<ProfileLogHistories>();
    histories = owned.get();
    original->SetUserData(kLogHistoryKey, std::move(owned));
  }
  const bool is_private = profile->IsOffTheRecord();
  auto& target = is_private ? histories->private_history : histories->regular;
  if (!target) {
    const auto level = original->GetPrefs()->GetString(
        is_private ? kAccessPrivateCoreLogLevel : kAccessCoreLogLevel);
    target = AccessCoreLogStore::Open(original->GetPath(),
        is_private ? CoreLogProfile::kPrivate : CoreLogProfile::kRegular, level);
  }
  return target;
}
#endif

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
#if BUILDFLAG(IS_MAC)
  if ((profile_->IsRegularProfile() || profile_->IsPrimaryOTRProfile()) &&
      profile_->GetPrefs()->FindPreference(kAccessCoreLogLevel)) {
    app_terminating_ = browser_shutdown::AddAppTerminatingCallback(
        base::BindOnce(&CoreLogShareSession::ShutDown, base::Unretained(&log_share_)));
    core_logs_ = GetCoreLogHistory(profile_);
  }
#endif
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
  const auto website = host.host ? CanonicalWebsiteHost(*host.host).host : std::nullopt;
  const auto key = website && website_hosts_.contains(*website) ? website : host.host;
  auto found = key ? host_states_.find(*key) : host_states_.end();
  if (publication_in_flight_ && website) {
    const auto pending = host_states_.find(*website);
    if (pending != host_states_.end() &&
        pending->second.connection == AccessSiteConnectionState::kConnecting) found = pending;
  }
  HostState state = found == host_states_.end() ? HostState() : found->second;
  if (state.connection == AccessSiteConnectionState::kReady) {
    auto* transport = AccessNetworkContextTransport::Get(profile_);
    const auto owner = transport ? transport->OwnerForPartition(
        AccessChannelForCurrentBuild(), {}) : std::nullopt;
    auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
    const auto common = owner && runtime
        ? runtime->CaptureCommonGenerationTupleOnUiThread(*owner) : std::nullopt;
    if (!local_core_ready_ || !common || !transport->HasCurrentPrivatePolicy(*owner, *common)) {
      state.connection = AccessSiteConnectionState::kUnavailable;
      state.failure_reason = "Proxy connection is unavailable. Reload to reconnect.";
    }
  }
  AccessSiteIntentStore presentation;
  if (host.host && key) presentation.Set(*host.host, intent_store_.Get(*key));
  return BuildSiteProxyBubbleSnapshot(committed_url, presentation,
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
                                               dev_intent_store_, committed_url);
}

AccessDevAllowBlockApplyResult
AccessSiteProxyBubbleController::ApplyDevAllowBlock(
    std::string_view raw_host,
    AccessDevAllowBlockAction action) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  AccessDevAllowBlockApplyResult result = ApplyAccessDevAllowBlock(
      &dev_intent_store_, chrome::GetChannel(), raw_host, action);
  if (result.status != AccessDevAllowBlockApplyStatus::kApplied) {
    return result;
  }
  ++state_revision_;
  return result;
}

bool AccessSiteProxyBubbleController::RequestHostProxySession(
    const AccessSiteHost& requested_host,
    bool enabled) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  const auto website = CanonicalWebsiteHost(requested_host);
  if (!website.host) return false;
  const auto host = *website.host;
  ++state_revision_;
  if (MakeAccessSiteHost(host.value).status != AccessSiteHostStatus::kOk) {
    host_states_[host].failure_reason = AccessSiteProxySessionErrorReadableMessage(
        AccessSiteProxySessionError::kInvalidHost);
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    return false;
  }
  base::OnceCallback<void(bool)> superseded_retry;
  base::OnceCallback<void(bool)> superseded_queue;
  if (publication_in_flight_ && !enabled && verifying_host_ == host) {
    // The ON transaction is already committed. Its connectivity recheck may
    // finish later, but a newer OFF owns both the choice and the retry now.
    verifying_host_.reset();
    ++committed_verification_attempt_;
    publication_in_flight_ = false;
    superseded_retry = std::move(retry_completion_);
    superseded_queue = std::move(queued_retry_);
    retry_url_ = GURL();
  }
  if (publication_in_flight_ || (enabled && restoring_core_)) {
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
    if (superseded_retry) std::move(superseded_retry).Run(false);
    if (superseded_queue) std::move(superseded_queue).Run(false);
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
  // Stop revokes the document callback immediately. The old transaction may
  // still own the publisher while the user clicks Retry on that page again.
  if (publication_in_flight_ && retry_url_ == original_url &&
      retry_completion_ && retry_completion_.IsCancelled() &&
      (!queued_retry_ || queued_retry_.IsCancelled())) {
    queued_retry_ = std::move(completion);
    return;
  }
  if (!host.host || publication_in_flight_) {
    std::move(completion).Run(false);
    return;
  }
  retry_url_ = original_url;
  retry_completion_ = std::move(completion);
  if (!RequestHostProxySession(*host.host, true) && retry_completion_) {
    retry_url_ = GURL();
    std::move(retry_completion_).Run(false);
  }
}
base::RepeatingCallback<void(const GURL&, base::OnceCallback<void(bool)>)>
AccessSiteProxyBubbleController::GetFailedNavigationRetryHandler() {
  if (!ResolveAccessLocalCoreInput()) return {};
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
        group.group.site_toggle_id !=
            (group.group.website_context ? "bubble-site:" : "bubble:") +
                group.group.canonical_host) continue;
    const auto host = MakeAccessSiteHost(group.group.canonical_host);
    if (host.host) {
      intent_store_.Set(*host.host,
          group.members.front().policy.mode == AccessMode::kProxy
              ? AccessSiteIntent::kAllow : AccessSiteIntent::kOff);
      host_states_.try_emplace(*host.host);
      if (group.group.website_context) website_hosts_.insert(*host.host);
    }
  }
  ++state_revision_;
}
void AccessSiteProxyBubbleController::AdoptWebsiteIntent(
    const AccessSiteHost& host, bool enabled) {
  std::vector<AccessSiteHost> aliases;
  for (const auto& [key, intent] : intent_store_.All()) {
    if (key != host && CanonicalWebsiteHost(key).host == host) aliases.push_back(key);
  }
  for (const auto& alias : aliases) {
    intent_store_.Set(alias, AccessSiteIntent::kOff);
    host_states_.erase(alias);
  }
  website_hosts_.insert(host);
  ApplySiteProxyToggle(&intent_store_, host, enabled);
}
void AccessSiteProxyBubbleController::FailCorePreparation(
    const AccessSiteHost& host, std::string error) {
  publication_in_flight_ = false;
  local_core_ready_ = false;
  ++state_revision_;
  host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
  host_states_[host].failure_reason = std::move(error);
  FinishNavigationPreparation(false);
}
void AccessSiteProxyBubbleController::PrepareLocalCore(const AccessSiteHost& host) {
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto owner = transport
      ? transport->OwnerForPartition(AccessChannelForCurrentBuild(), base::FilePath())
      : std::nullopt;
  if (!owner || !transport->OwnsConfiguredPartition(*owner) ||
      !IsDevAllowBlockPanelRegistered()) {
    FailCorePreparation(host, "The test proxy is unavailable in this build.");
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
  CreateLocalCore();
  if (!local_core_) {
    FailCorePreparation(host, "The authorized proxy configuration is unavailable.");
    return;
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
  if (!RegisterPreparedCore(owner, result)) {
    FailCorePreparation(host, "The prepared proxy registration could not be installed.");
    return;
  }
  AccessSiteProxyLocalProxyReadyInfo ready;
  if (EnsureLocalProxyReady(host, &ready) != AccessSiteProxySessionError::kOk) {
    FailCorePreparation(host, "The prepared proxy has not been registered with this Profile.");
    return;
  }
  BeginEnablePublication(host, std::move(ready));
}
std::string AccessSiteProxyBubbleController::LocalProxyGroup(
    const OwnershipKey& owner) {
  if (owner.channel == ChannelNamespace::kBeta) return "beta-authorized-test-node";
  return owner.channel == ChannelNamespace::kAlpha ? "alpha-authorized-test-node"
                                                  : "dev-authorized-local-node";
}
bool AccessSiteProxyBubbleController::CanViewCoreLogs() const {
  return core_logs_ != nullptr;
}
void AccessSiteProxyBubbleController::SetCoreLogLevel(std::string_view level) {
  if (!CanViewCoreLogs() ||
      std::find(kCoreLogLevels.begin(), kCoreLogLevels.end(), level) == kCoreLogLevels.end())
    return;
  profile_->GetOriginalProfile()->GetPrefs()->SetString(
      profile_->IsOffTheRecord() ? kAccessPrivateCoreLogLevel : kAccessCoreLogLevel,
      std::string(level));
  core_logs_->SetLevel(level);
  ++state_revision_;
}
#if BUILDFLAG(IS_MAC)
void AccessSiteProxyBubbleController::ShareCoreLogs(content::WebContents* tab, std::string preview, uint64_t version,
    base::OnceCallback<void(bool)> done) {
  if (!CanViewCoreLogs() || !tab ||
      tab->GetBrowserContext() != profile_ || preview.empty() || !core_logs_->CanShare(version)) {
    std::move(done).Run(false);
    return;
  }
  log_share_.Start(std::move(preview), base::BindOnce(
      [](base::WeakPtr<content::WebContents> tab, content::GlobalRenderFrameHostId frame,
         scoped_refptr<AccessCoreLogStore> store, uint64_t version,
         base::OnceCallback<void(bool)> done, base::FilePath path,
         base::ScopedClosureRunner release) {
        if (!tab || path.empty() || !store->CanShare(version) ||
            tab->GetPrimaryMainFrame()->GetGlobalId() != frame ||
            tab->GetVisibility() != content::Visibility::VISIBLE ||
            !tab->GetRenderWidgetHostView()) {
          std::move(done).Run(false);
          return;
        }
        tab->GetRenderWidgetHostView()->ShowSharePicker("", "", GURL(), {path.value()},
            base::BindOnce([](base::ScopedClosureRunner release, base::OnceCallback<void(bool)> done,
                              blink::mojom::ShareError result) {
              release.RunAndReset();
              std::move(done).Run(result != blink::mojom::ShareError::INTERNAL_ERROR);
            }, std::move(release), std::move(done)));
      }, tab->GetWeakPtr(), tab->GetPrimaryMainFrame()->GetGlobalId(), core_logs_,
      version, std::move(done)));
}
#endif
void AccessSiteProxyBubbleController::CreateLocalCore() {
  if (local_core_) return;
  auto input = ResolveAccessLocalCoreInput();
  if (!input) return;
  input->log_store = core_logs_;
  local_core_ = std::make_unique<AccessLocalCoreManager>(*input);
  local_core_->SetStoppedCallback(base::BindRepeating(
      &AccessSiteProxyBubbleController::OnLocalCoreStopped,
      weak_factory_.GetWeakPtr()));
}
bool AccessSiteProxyBubbleController::RegisterPreparedCore(
    const OwnershipKey& owner, const AccessLocalCoreReady& result) {
  if (!result.ready || !result.local_credentials) return false;
  // Rebinding a child does not change a saved rule or its revision.
  auto* identity = AccessIdentityGenerationSource::GetOrCreate(profile_);
  if (!identity->binding()) identity->CommitIdentity(
      {aegis_access::AccessIdentityKind::kSignedOut, {}, {}, LocalAccessIdentityChannel(owner.channel), "authorized-local-node"});
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto common = runtime ? runtime->CaptureCommonGenerationTupleOnUiThread(owner)
                              : std::nullopt;
  if (!common || !result.local_credentials) {
    return false;
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  auto* selections = AccessProxySelectionGenerationSource::GetOrCreate(profile_);
  const std::string group = LocalProxyGroup(owner);
  const auto* old = selections->binding_for_group(group);
  const bool same = old && old->endpoint_id == result.registration_id;
  const auto selected = selections->CommitSelection(
      {group, result.registration_id, "dev-process:" + result.registration_id,
       "dev-binding:" + result.registration_id,
       same ? old->binding_revision : old ? old->binding_revision + 1 : 1});
  if (selected.status != aegis_access::ProxySelectionGenerationCommitStatus::kCommitted &&
      selected.status != aegis_access::ProxySelectionGenerationCommitStatus::kUnchanged) {
    return false;
  }
  auto generations = *common;
  generations.selection_generation = selected.generation;
  if (!selected.generation || !transport || !transport->RegisterPreparedProxy({
          {result.registration_id, group, owner, generations,
           aegis_access::RegisteredProxyTransport::kHttp, "127.0.0.1", result.port},
          result.local_credentials})) {
    return false;
  }
  core_owner_ = owner;
  core_registration_ = result.registration_id;
  local_core_ready_ = false;
  return true;
}
void AccessSiteProxyBubbleController::OnCommittedCoreVerified(
    AccessSiteHost host, uint64_t attempt, AccessLocalCoreReady result) {
  if (attempt != committed_verification_attempt_ || verifying_host_ != host)
    return;
  verifying_host_.reset();
  if (!result.ready) {
    OnLocalCoreStopped(core_registration_);
    FailCorePreparation(host, std::move(result.error));
    return;
  }
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto owner = transport
      ? transport->OwnerForPartition(AccessChannelForCurrentBuild(), base::FilePath())
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
  local_core_ready_ = true;
  FinishNavigationPreparation(true);
}

bool AccessSiteProxyBubbleController::IsCurrentPreparedCore(
    const OwnershipKey& owner, const AccessLocalCoreReady& result) const {
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto endpoint = transport ? transport->CurrentEndpoint(owner) : std::nullopt;
  const auto live = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(owner) : std::nullopt;
  auto bound = endpoint ? std::make_optional(endpoint->generations) : std::nullopt;
  if (bound) bound->selection_generation = 0;
  return result.ready && endpoint && live && bound == live &&
      endpoint->proxy_group_id == LocalProxyGroup(owner) &&
      endpoint->registration_id == result.registration_id &&
      endpoint->port == result.port && transport->HasCurrentPrivatePolicy(owner, *live);
}

void AccessSiteProxyBubbleController::EnsureLocalCoreForRequest(
    const OwnershipKey& owner, const std::string& group,
    base::OnceCallback<void(bool)> completion) {
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto expected_owner = transport ? transport->OwnerForPartition(
      AccessChannelForCurrentBuild(), {}) : std::nullopt;
  auto* coordinator = AccessServiceCoordinator::Get(profile_);
  if (!expected_owner || *expected_owner != owner ||
      !transport->OwnsConfiguredPartition(owner) || group != LocalProxyGroup(owner) ||
      !IsDevAllowBlockPanelRegistered() || !coordinator || !coordinator->CanDispatch(owner)) {
    std::move(completion).Run(false);
    return;
  }
  const auto endpoint = transport->CurrentEndpoint(owner);
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto common = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(owner) : std::nullopt;
  if (local_core_ready_ && core_owner_ == owner && endpoint && common &&
      endpoint->registration_id == core_registration_ &&
      endpoint->generations.identity_generation == common->identity_generation &&
      endpoint->generations.network_epoch == common->network_epoch &&
      endpoint->generations.base_proxy_config_generation == common->base_proxy_config_generation) {
    std::move(completion).Run(true);
    return;
  }
  core_request_waiters_.push_back(std::move(completion));
  if (restoring_core_ || publication_in_flight_) return;
  CreateLocalCore();
  if (!local_core_) {
    FinishCoreRequests(false);
    return;
  }
  local_core_ready_ = false;
  restoring_core_ = true;
  const auto attempt = ++core_attempt_;
  for (auto& [host, state] : host_states_) {
    if (intent_store_.Get(host) == AccessSiteIntent::kAllow) {
      state.connection = AccessSiteConnectionState::kConnecting;
      state.failure_reason.clear();
    }
  }
  ++state_revision_;
  local_core_->Prepare(base::BindOnce(
      &AccessSiteProxyBubbleController::OnRestoredCorePrepared,
      weak_factory_.GetWeakPtr(), owner, attempt));
}

void AccessSiteProxyBubbleController::OnRestoredCorePrepared(
    OwnershipKey owner, uint64_t attempt, AccessLocalCoreReady result) {
  if (attempt != core_attempt_ || !restoring_core_) return;
  if (!RegisterPreparedCore(owner, result)) {
    OnLocalCoreStopped(core_registration_);
    FinishCoreRequests(false);
    return;
  }
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  const auto* policy = runtime ? runtime->GetPublishedPolicySnapshot(owner) : nullptr;
  const auto common = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(owner) : std::nullopt;
  if (!transport || !policy || !common) {
    FinishCoreRequests(false);
    return;
  }
  transport->PublishPrivatePolicy(*policy, *common, base::BindOnce(
      &AccessSiteProxyBubbleController::OnRestoredCorePolicyReady,
      weak_factory_.GetWeakPtr(), owner, attempt, *common));
}
void AccessSiteProxyBubbleController::OnRestoredCorePolicyReady(
    OwnershipKey owner, uint64_t attempt,
    aegis_access::GenerationTuple expected, bool accepted) {
  if (attempt != core_attempt_ || !restoring_core_) return;
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  const auto common = runtime
      ? runtime->CaptureCommonGenerationTupleOnUiThread(owner) : std::nullopt;
  if (!accepted || !common || *common != expected) {
    FinishCoreRequests(false);
    return;
  }
  local_core_->Verify(base::BindOnce(
      &AccessSiteProxyBubbleController::OnRestoredCoreVerified,
      weak_factory_.GetWeakPtr(), owner, attempt));
}
void AccessSiteProxyBubbleController::OnRestoredCoreVerified(
    OwnershipKey owner, uint64_t attempt, AccessLocalCoreReady result) {
  if (attempt != core_attempt_ || !restoring_core_) return;
  const bool ready = IsCurrentPreparedCore(owner, result);
  if (!ready && !result.ready) OnLocalCoreStopped(core_registration_);
  local_core_ready_ = ready;
  for (auto& [host, state] : host_states_) {
    if (intent_store_.Get(host) == AccessSiteIntent::kAllow) {
      state.connection = ready ? AccessSiteConnectionState::kReady
                                           : AccessSiteConnectionState::kUnavailable;
      state.failure_reason = ready ? std::string() :
          "The saved proxy binding is not ready.";
    }
  }
  ++state_revision_;
  FinishCoreRequests(ready);
}
void AccessSiteProxyBubbleController::FinishNavigationPreparation(bool ready) {
  auto retry = std::move(retry_completion_);
  auto next = std::move(queued_retry_);
  GURL url = std::exchange(retry_url_, GURL());
  if (retry) std::move(retry).Run(ready);
  FinishCoreRequests(ready);
  // Never reuse the first attempt's result. The new document ticket needs its
  // own core verification and acknowledgement before it can reload.
  if (next && !next.IsCancelled()) {
    RequestFailedNavigationProxy(url, std::move(next));
  }
}

void AccessSiteProxyBubbleController::FinishCoreRequests(bool ready) {
  if (restoring_core_ && !ready) {
    for (auto& [host, state] : host_states_) {
      if (intent_store_.Get(host) == AccessSiteIntent::kAllow) {
        state.connection = AccessSiteConnectionState::kUnavailable;
        state.failure_reason = "The saved proxy binding is not ready.";
      }
    }
    ++state_revision_;
  }
  restoring_core_ = false;
  auto callbacks = std::move(core_request_waiters_);
  core_request_waiters_.clear();
  for (auto& callback : callbacks) std::move(callback).Run(ready);
}
void AccessSiteProxyBubbleController::OnLocalCoreStopped(std::string registration_id) {
  if (registration_id.empty() || registration_id != core_registration_ || !core_owner_) return;
  local_core_ready_ = false;
  ++core_attempt_;
  auto* transport = AccessNetworkContextTransport::Get(profile_);
  auto* runtime = AccessPublishedRequestRuntime::Get(profile_);
  if (transport && transport->ForgetPreparedProxy(*core_owner_, LocalProxyGroup(*core_owner_),
                                                 registration_id) && runtime) {
    const auto* policy = runtime->GetPublishedPolicySnapshot(*core_owner_);
    const auto common = runtime->CaptureCommonGenerationTupleOnUiThread(*core_owner_);
    if (policy && common)
      transport->PublishPrivatePolicy(*policy, *common, base::BindOnce([](bool) {}));
  }
  for (auto& [host, state] : host_states_) {
    if (intent_store_.Get(host) == AccessSiteIntent::kAllow) {
      state.connection = AccessSiteConnectionState::kUnavailable;
      state.failure_reason = "The local proxy has stopped.";
    }
  }
  ++state_revision_;
  FinishCoreRequests(false);
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
      transport->OwnerForPartition(AccessChannelForCurrentBuild(), base::FilePath());
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
      if (group.group.site_toggle_id == "bubble-site:" + host.value) {
        expected_revision = group.group.revision;
        break;
      }
    }
  }
  const AccessSiteProxySessionMutationPlan plan =
      BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kAllow,
                                        ready.owner, ready.proxy_group_id,
                                        base::Uuid::GenerateRandomV4().AsLowercaseString(),
                                        expected_revision, /*website_context=*/true);
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
      ? transport->OwnerForPartition(AccessChannelForCurrentBuild(), base::FilePath())
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
      if (group.group.site_toggle_id == "bubble-site:" + host.value) {
        expected_revision = group.group.revision;
        break;
      }
    }
  }
  const AccessSiteProxySessionMutationPlan plan =
      BuildSiteProxySessionMutationPlan(host, AccessSiteIntent::kOff,
                                        ready.owner, /*proxy_group_id=*/"",
                                        base::Uuid::GenerateRandomV4().AsLowercaseString(),
                                        expected_revision, /*website_context=*/true);
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
    AdoptWebsiteIntent(host, enabling);
  }

  if (enabling) {
    if (result.status == AccessMutationTransactionStatus::kCommitted) {
      publication_in_flight_ = true;
      verifying_host_ = host;
      local_core_->Verify(base::BindOnce(
          &AccessSiteProxyBubbleController::OnCommittedCoreVerified,
          weak_factory_.GetWeakPtr(), host, ++committed_verification_attempt_));
      return;
    }
    // Preserve the last committed choice; preparation is not a commit.
    host_states_[host].connection = AccessSiteConnectionState::kUnavailable;
    host_states_[host].failure_reason = MutationStatusReadableMessage(result.status);
    FinishNavigationPreparation(false);
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
  if (!restoring_core_) FinishCoreRequests(false);
}

}  // namespace aegis::access
