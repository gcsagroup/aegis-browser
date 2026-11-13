// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_network_context_transport.h"

#include <algorithm>
#include <limits>
#include <memory>
#include <set>
#include <utility>

#include "base/barrier_closure.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/functional/callback_helpers.h"
#include "base/uuid.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/base/proxy_server.h"
#include "net/proxy_resolution/proxy_config.h"
#include "net/proxy_resolution/proxy_info.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

const void* const kTransportUserDataKey = &kTransportUserDataKey;
constexpr size_t kMaxExactHosts = 256;
constexpr size_t kMaxPartitionKeyBytes = 1024;

bool IsCanonicalExactHost(const std::string& host) {
  if (host.empty() || host.back() == '.') {
    return false;
  }
  const GURL url("https://" + host + "/");
  return url.is_valid() && url.has_host() && url.host() == host;
}

bool AreCanonicalExactHosts(const std::vector<std::string>& exact_hosts) {
  return !exact_hosts.empty() && exact_hosts.size() <= kMaxExactHosts &&
         std::ranges::is_sorted(exact_hosts) &&
         std::adjacent_find(exact_hosts.begin(), exact_hosts.end()) ==
             exact_hosts.end() &&
         std::ranges::all_of(exact_hosts, IsCanonicalExactHost);
}

aegis_access::RoutePlan RoutePlanForEndpoint(
    const aegis_access::RegisteredProxyEndpoint& endpoint) {
  aegis_access::RoutePlan plan;
  plan.action = aegis_access::RouteAction::kUseRegisteredProxy;
  plan.effective_mode = aegis_access::AccessMode::kProxy;
  plan.reason = aegis_access::RouteReason::kNone;
  plan.generations = endpoint.generations;
  plan.registered_proxy_entry = aegis_access::RegisteredProxyEntry{
      endpoint.registration_id, endpoint.proxy_group_id, endpoint.owner,
      endpoint.generations};
  return plan;
}

bool IsCandidateIdentityValid(
    const aegis_access::PolicyPublicationIdentity& identity,
    uint64_t network_epoch) {
  return !(
      !aegis_access::IsValidRequestCancellationSelector(identity.selector) ||
      identity.operation_id.empty() || identity.operation_sequence == 0 ||
      identity.policy_generation == 0 ||
      identity.policy_generation != identity.operation_sequence ||
      (identity.selection_generation == 0) != identity.proxy_group_id.empty() ||
      identity.network_epoch == 0 || identity.network_epoch != network_epoch);
}

}  // namespace

// static
AccessNetworkContextTransport* AccessNetworkContextTransport::Get(
    Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessNetworkContextTransport*>(
      profile->GetUserData(kTransportUserDataKey));
}

// static
AccessNetworkContextTransport* AccessNetworkContextTransport::GetOrCreate(
    Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  if (auto* existing = Get(profile)) {
    return existing;
  }
  auto transport = std::unique_ptr<AccessNetworkContextTransport>(
      new AccessNetworkContextTransport());
  auto* result = transport.get();
#if BUILDFLAG(IS_MAC)
  profile->SetAccountProxyDispatchGate(base::BindRepeating(
      [](base::WeakPtr<AccessNetworkContextTransport> self, const GURL& url) {
        return !self || self->AccountDispatchBlocked(url);
      }, result->weak_factory_.GetWeakPtr()));
#endif
  profile->SetUserData(kTransportUserDataKey, std::move(transport));
  return result;
}

AccessNetworkContextTransport::AccessNetworkContextTransport()
    : runtime_profile_token_(
          base::Uuid::GenerateRandomV4().AsLowercaseString()) {
  net::NetworkChangeNotifier::AddNetworkChangeObserver(this);
}

AccessNetworkContextTransport::~AccessNetworkContextTransport() {
  net::NetworkChangeNotifier::RemoveNetworkChangeObserver(this);
}

void AccessNetworkContextTransport::OnNetworkChanged(
    net::NetworkChangeNotifier::ConnectionType) {
  if (network_epoch_ == 0) {
    return;
  }
  if (network_epoch_ == std::numeric_limits<uint64_t>::max()) {
    // Zero is the incomplete GenerationTuple sentinel. Once the counter is
    // exhausted, keep the source invalid so callers fail closed rather than
    // wrapping to a previously valid epoch.
    network_epoch_ = 0;
    return;
  }
  ++network_epoch_;

  // Keep the already-installed localhost proxy route intact here. Broadcasting
  // an empty CustomProxyConfig would restore Chromium's native proxy result and
  // could silently downgrade a request that still requires proxying to DIRECT.
  // The incremented epoch invalidates stale re-publication; the request-runtime
  // generation gate is responsible for blocking stale tuples while the local
  // proxy runtime rebinds to the new network.
}

// static
bool AccessNetworkContextTransport::ConfigureNetworkContext(
    Profile* profile,
    const base::FilePath& relative_partition_path,
    network::mojom::NetworkContextParams* network_context_params) {
  if (!aegis::IsAegisProfileSupported(profile) || !network_context_params ||
      network_context_params->initial_custom_proxy_config ||
      network_context_params->custom_proxy_config_client_receiver.is_valid() ||
      network_context_params->custom_proxy_connection_observer_remote.is_valid()) {
    return false;
  }
  AccessNetworkContextTransport* transport = GetOrCreate(profile);
  const std::optional<std::string> key = PartitionKey(relative_partition_path);
  if (!transport || !key) {
    return false;
  }

  PartitionState& state = transport->partitions_[*key];
  network_context_params->initial_custom_proxy_config =
      transport->BuildConfig(state);
  mojo::PendingRemote<network::mojom::CustomProxyConfigClient> client;
  network_context_params->custom_proxy_config_client_receiver =
      client.InitWithNewPipeAndPassReceiver();
  if (state.clients_generation == std::numeric_limits<uint64_t>::max()) {
    return false;
  }
  ++state.clients_generation;
  state.clients.Add(std::move(client));
#if BUILDFLAG(IS_MAC)
  if (!state.account_fenced.empty() || !state.account_sites.empty())
    transport->PublishAccountConfig(state);
#endif
  return true;
}

std::optional<aegis_access::OwnershipKey>
AccessNetworkContextTransport::OwnerForPartition(
    aegis_access::ChannelNamespace channel,
    const base::FilePath& relative_partition_path) const {
  if (!aegis_access::IsKnownChannel(channel)) {
    return std::nullopt;
  }
  const std::optional<std::string> partition_token =
      PartitionToken(relative_partition_path);
  if (!partition_token) {
    return std::nullopt;
  }
  return aegis_access::OwnershipKey{channel, runtime_profile_token_,
                                    *partition_token};
}

bool AccessNetworkContextTransport::OwnsConfiguredPartition(
    const aegis_access::OwnershipKey& owner) const {
  return aegis_access::IsCompleteOwner(owner) &&
         owner.profile_token == runtime_profile_token_ &&
         partitions_.contains(owner.storage_partition_token);
}

bool AccessNetworkContextTransport::PublishProxySelection(
    const base::FilePath& relative_partition_path,
    std::vector<std::string> exact_hosts,
    const aegis_access::RegisteredProxyEndpoint& endpoint) {
  const std::optional<std::string> key = PartitionKey(relative_partition_path);
  if (!key ||
      !IsEndpointCurrentForPartition(relative_partition_path, endpoint)) {
    return false;
  }

  std::sort(exact_hosts.begin(), exact_hosts.end());
  if (!AreCanonicalExactHosts(exact_hosts)) {
    return false;
  }

  PartitionState candidate;
  candidate.endpoint = endpoint;
  candidate.exact_hosts = std::move(exact_hosts);
  network::mojom::CustomProxyConfigPtr candidate_config =
      BuildConfig(candidate);
  if (!candidate_config ||
      candidate_config->rules.type ==
          net::ProxyConfig::ProxyRules::Type::EMPTY) {
    return false;
  }

  PartitionState& state = partitions_[*key];
#if BUILDFLAG(IS_MAC)
  if (state.account_config) return false;
#endif
  state.endpoint = std::move(candidate.endpoint);
  state.exact_hosts = std::move(candidate.exact_hosts);
  Broadcast(state);
  return true;
}

#if BUILDFLAG(IS_MAC)
const std::vector<std::string>& AccessNetworkContextTransport::AccountSites() const {
  static const base::NoDestructor<std::vector<std::string>> empty;
  const auto it = partitions_.find("<default>");
  return it == partitions_.end() ? *empty : it->second.account_sites;
}

bool AccessNetworkContextTransport::AccountDispatchBlocked(const GURL& url) const {
  auto it = partitions_.find("<default>");
  if (it == partitions_.end()) return false;
  std::string host(url.host());
  while (!host.empty() && host.back() == '.') host.pop_back();
  return it->second.account_fenced.contains(host);
}

void AccessNetworkContextTransport::PublishAccountConfig(PartitionState& state) {
  const auto revision = ++state.account_publication;
  if (state.clients.empty()) return;
  auto config = BuildConfig(state);
  if (!config) return;
  UpdateClientConfigs(state, config, base::BindOnce(
      [](base::WeakPtr<AccessNetworkContextTransport> self, uint64_t revision, bool accepted) {
        if (!self || !accepted) return;
        auto& current = self->partitions_.at("<default>");
        if (current.account_publication == revision) current.account_fenced.clear();
      }, weak_factory_.GetWeakPtr(), revision));
}

bool AccessNetworkContextTransport::SetAccountNodeSites(
    const std::vector<std::string>& sites, const std::string& host, uint16_t port,
    const std::string& authorization) {
  auto& state = partitions_["<default>"];
  if (sites.empty()) {
    state.account_fenced.insert(state.account_sites.begin(), state.account_sites.end());
    state.account_sites.clear();
    state.account_config.reset();
    PublishAccountConfig(state);
    return true;
  }
  // Private request routes carry their own per-request endpoint. Only the
  // legacy partition-wide custom proxy competes for this configuration.
  if (!AreCanonicalExactHosts(sites) || (state.endpoint && !state.private_routing))
    return false;
  auto config = network::mojom::CustomProxyConfig::New();
  auto blocked = net::ProxyServer::FromSchemeHostAndPort(
      net::ProxyServer::SCHEME_HTTPS, "blocked.invalid", 443);
  auto proxy = host.empty() ? blocked : net::ProxyServer::FromSchemeHostAndPort(
      net::ProxyServer::SCHEME_HTTPS, host, port);
  if (!proxy.is_valid() || (!host.empty() && authorization.empty())) return false;
  config->rules.type = net::ProxyConfig::ProxyRules::Type::PROXY_LIST_PER_SCHEME;
  for (const auto& site : sites)
    config->rules.bypass_rules.AddAegisExactSite(site);
  // Keep this single endpoint exclusive to the config. The CONNECT-only node
  // rejects ordinary HTTP and no tunnel header accompanies those requests.
  config->rules.proxies_for_http.SetSingleProxyServer(proxy);
  config->rules.proxies_for_https.SetSingleProxyServer(proxy);
  config->rules.reverse_bypass = true;
  config->should_override_existing_config = true;
  config->allow_non_idempotent_methods = true;
  // An empty value marks a blocked account route during acquisition/logout.
  // The delegate never sends that placeholder on the wire.
  config->connect_tunnel_headers.SetHeader(net::HttpRequestHeaders::kProxyAuthorization,
                                           authorization);
  // The Browser dispatch path and all NetworkContexts have separate pipes.
  // Fence changed exact hosts before publishing, until every recipient ACKs.
  if (!state.account_config ||
      state.account_config->connect_tunnel_headers.GetHeader(net::HttpRequestHeaders::kProxyAuthorization) !=
          config->connect_tunnel_headers.GetHeader(net::HttpRequestHeaders::kProxyAuthorization) ||
      state.account_config->rules.proxies_for_https.AllChains() != config->rules.proxies_for_https.AllChains()) {
    state.account_fenced.insert(state.account_sites.begin(), state.account_sites.end());
    state.account_fenced.insert(sites.begin(), sites.end());
  } else {
    std::set_symmetric_difference(state.account_sites.begin(), state.account_sites.end(),
        sites.begin(), sites.end(), std::inserter(state.account_fenced, state.account_fenced.end()));
  }
  state.account_sites = sites;
  state.account_config = std::move(config);
  PublishAccountConfig(state);
  return true;
}
#endif

bool AccessNetworkContextTransport::ClearProxySelection(
    const base::FilePath& relative_partition_path) {
  const std::optional<std::string> key = PartitionKey(relative_partition_path);
  if (!key) {
    return false;
  }
  auto it = partitions_.find(*key);
  if (it == partitions_.end()) {
    return true;
  }
  it->second.endpoint.reset();
  it->second.exact_hosts.clear();
  Broadcast(it->second);
  return true;
}

bool AccessNetworkContextTransport::RegisterPreparedProxy(
    const AccessPrivateEndpoint& entry) {
  const auto& endpoint = entry.registration;
  const auto& g = endpoint.generations;
  if (!OwnsConfiguredPartition(endpoint.owner) ||
      endpoint.transport != aegis_access::RegisteredProxyTransport::kHttp ||
      (endpoint.host != "127.0.0.1" && endpoint.host != "::1") || !endpoint.port ||
      endpoint.proxy_group_id.empty() || endpoint.registration_id.empty() ||
      !g.policy_generation || !g.identity_generation || !g.selection_generation ||
      g.network_epoch != network_epoch_ || !g.base_proxy_config_generation ||
      !entry.local_credentials || entry.local_credentials->username().empty() ||
      entry.local_credentials->password().empty()) return false;
  auto& state = partitions_.at(endpoint.owner.storage_partition_token);
  for (const auto& [group, old] : state.private_endpoints) {
    if (old.registration.registration_id == endpoint.registration_id &&
        (group != endpoint.proxy_group_id || old.registration.host != endpoint.host ||
         old.registration.port != endpoint.port ||
         !old.local_credentials->Equals(*entry.local_credentials))) return false;
  }
  state.private_endpoints.insert_or_assign(endpoint.proxy_group_id, entry);
  state.private_unavailable_generations.erase(endpoint.proxy_group_id);
  state.endpoint = endpoint;
  return true;
}
std::vector<AccessPrivateEndpoint> AccessNetworkContextTransport::PrivateEndpoints(
    const aegis_access::OwnershipKey& owner) const {
  std::vector<AccessPrivateEndpoint> endpoints;
  if (!OwnsConfiguredPartition(owner)) return endpoints;
  for (const auto& [group, entry] : partitions_.at(owner.storage_partition_token).private_endpoints)
    endpoints.push_back(entry);
  return endpoints;
}
bool AccessNetworkContextTransport::ForgetPreparedProxy(
    const aegis_access::OwnershipKey& owner, const std::string& group,
    const std::string& registration_id) {
  if (!OwnsConfiguredPartition(owner)) return false;
  auto& state = partitions_.at(owner.storage_partition_token);
  const auto found = state.private_endpoints.find(group);
  if (found == state.private_endpoints.end() ||
      found->second.registration.owner != owner ||
      found->second.registration.registration_id != registration_id) return false;
  state.private_unavailable_generations.insert_or_assign(
      group, found->second.registration.generations.selection_generation);
  state.private_endpoints.erase(found);
  if (state.endpoint && state.endpoint->registration_id == registration_id)
    state.endpoint.reset();
  return true;
}
bool AccessNetworkContextTransport::HasReadyPrivateContext(
    const aegis_access::OwnershipKey& owner) const {
  if (!OwnsConfiguredPartition(owner)) return false;
  const auto& contexts = partitions_.at(owner.storage_partition_token).private_contexts;
  const auto& state = partitions_.at(owner.storage_partition_token);
  return !contexts.empty() && std::ranges::all_of(contexts,
      [&](const auto& entry) { return entry.second.client->is_ready() &&
          entry.second.applied_revision == state.private_revision; });
}

bool AccessNetworkContextTransport::HasCurrentPrivatePolicy(
    const aegis_access::OwnershipKey& owner,
    const aegis_access::GenerationTuple& common) const {
  if (!HasReadyPrivateContext(owner)) return false;
  const auto& publication =
      partitions_.at(owner.storage_partition_token).private_publication;
  return publication && publication->common == common;
}

void AccessNetworkContextTransport::BindPrivateContext(
    const aegis_access::OwnershipKey& owner, network::mojom::NetworkContext* context,
    base::OnceCallback<void(PrivateContext)> completion) {
  if (!context || !OwnsConfiguredPartition(owner)) {
    std::move(completion).Run(nullptr);
    return;
  }
  auto& state = partitions_.at(owner.storage_partition_token);
  if (!state.private_routing) {
    state.private_routing = true;
    // Clear any earlier legacy selection before the private capability can
    // become usable. Subsequent Context creation also starts with empty config.
    Broadcast(state);
  }
  auto client = std::make_shared<AccessPrivateContextClient>(owner);
  client->Initialize(context, base::BindOnce(
      [](base::WeakPtr<AccessNetworkContextTransport> self,
         aegis_access::OwnershipKey owner, PrivateContext client,
         base::OnceCallback<void(PrivateContext)> completion, bool initialized) {
        if (!self || !initialized || !self->OwnsConfiguredPartition(owner)) {
          std::move(completion).Run(nullptr);
          return;
        }
        auto& state = self->partitions_.at(owner.storage_partition_token);
        bool lost = false;
        std::erase_if(state.private_contexts, [&](const auto& entry) {
          const bool disconnected = entry.second.client->incarnation().empty();
          lost |= disconnected;
          return disconnected;
        });
        if (lost) self->SettlePrivatePublication(state, false);
        const auto incarnation = client->incarnation();
        auto [entry, inserted] = state.private_contexts.try_emplace(
            incarnation, PrivateContextEntry{client});
        // All factories for the same actual Context share one sequence owner.
        std::move(completion).Run(entry->second.client);
      }, weak_factory_.GetWeakPtr(), owner, client, std::move(completion)));
}
bool AccessNetworkContextTransport::SamePrivatePublication(
    const PrivatePublication& a, const PrivatePublication& b) {
  if (a.policy != b.policy || a.common != b.common || a.unavailable != b.unavailable ||
      a.endpoints.size() != b.endpoints.size()) return false;
  for (size_t i = 0; i < a.endpoints.size(); ++i) {
    const auto& left = a.endpoints[i];
    const auto& right = b.endpoints[i];
    if (left.registration != right.registration ||
        left.local_credentials.has_value() != right.local_credentials.has_value() ||
        (left.local_credentials && !left.local_credentials->Equals(*right.local_credentials)))
      return false;
  }
  return true;
}
AccessNetworkConfigAckResult AccessNetworkContextTransport::PublishPrivatePolicy(
    const aegis_access::PublishedAccessPolicySnapshot& policy,
    const aegis_access::GenerationTuple& common,
    base::OnceCallback<void(bool)> completion) {
  if (!OwnsConfiguredPartition(policy.owner) ||
      aegis_access::ValidateAccessPolicySnapshot(policy) != aegis_access::PolicyMatchReason::kNone ||
      common.policy_generation != policy.policy_generation || !common.policy_generation ||
      !common.identity_generation || !common.network_epoch ||
      common.network_epoch != network_epoch_ || !common.base_proxy_config_generation ||
      common.selection_generation != 0) {
    std::move(completion).Run(false);
    return {AccessNetworkConfigAckStatus::kInvalidPublication, 0};
  }
  auto& state = partitions_.at(policy.owner.storage_partition_token);
  PrivatePublication candidate{policy, common, {}, {}};
  std::set<std::string> groups;
  for (const auto& rule : policy.rules)
    if (rule.mode == aegis_access::AccessMode::kProxy) groups.insert(rule.proxy_group_id);
  for (const auto& group : groups) {
    auto found = state.private_endpoints.find(group);
    if (found != state.private_endpoints.end()) {
      auto& entry = found->second;
      auto& g = entry.registration.generations;
      if (g.identity_generation == common.identity_generation &&
          g.network_epoch == common.network_epoch &&
          g.base_proxy_config_generation == common.base_proxy_config_generation) {
        g.policy_generation = common.policy_generation;
        candidate.endpoints.push_back(entry);
        continue;
      }
      candidate.unavailable.emplace(group, g.selection_generation);
    } else {
      // This process has not selected an endpoint for the restored group.
      const auto high_water = state.private_unavailable_generations.find(group);
      candidate.unavailable.emplace(group,
          high_water == state.private_unavailable_generations.end() ? 0 : high_water->second);
    }
  }
  if (!state.private_publication || !SamePrivatePublication(*state.private_publication, candidate)) {
    SettlePrivatePublication(state, false);
    state.private_publication = std::move(candidate);
    ++state.private_revision;
  }
  state.private_publication_waiters.push_back(std::move(completion));
  if (state.private_contexts.empty()) {
    SettlePrivatePublication(state, false);
    return {AccessNetworkConfigAckStatus::kNoClients, 0};
  }
  const size_t required = state.private_contexts.size();
  for (const auto& [incarnation, entry] : state.private_contexts)
    PublishPrivateContext(policy.owner, incarnation);
  if (HasReadyPrivateContext(policy.owner)) SettlePrivatePublication(state, true);
  return {AccessNetworkConfigAckStatus::kStarted, required};
}
void AccessNetworkContextTransport::PublishPrivateContext(
    const aegis_access::OwnershipKey& owner, const std::string& incarnation) {
  auto& state = partitions_.at(owner.storage_partition_token);
  auto& entry = state.private_contexts.at(incarnation);
  if (entry.publishing || !state.private_publication ||
      (entry.applied_revision == state.private_revision && entry.client->is_ready())) return;
  const auto& publication = *state.private_publication;
  entry.publishing = true;
  entry.client->PublishPolicy(publication.policy, publication.common, ++entry.sequence,
      publication.endpoints, publication.unavailable,
      base::BindOnce(&AccessNetworkContextTransport::OnPrivateContextPublished,
          weak_factory_.GetWeakPtr(), owner, incarnation, state.private_revision));
}
void AccessNetworkContextTransport::OnPrivateContextPublished(
    aegis_access::OwnershipKey owner, std::string incarnation,
    uint64_t revision, bool accepted) {
  auto found = partitions_.find(owner.storage_partition_token);
  if (found == partitions_.end()) return;
  auto& state = found->second;
  auto entry = state.private_contexts.find(incarnation);
  if (entry == state.private_contexts.end()) return;
  entry->second.publishing = false;
  if (revision != state.private_revision) {
    PublishPrivateContext(owner, incarnation);
    return;
  }
  if (!accepted) {
    SettlePrivatePublication(state, false);
    return;
  }
  entry->second.applied_revision = revision;
  if (HasReadyPrivateContext(owner)) SettlePrivatePublication(state, true);
}
void AccessNetworkContextTransport::SettlePrivatePublication(PartitionState& state,
                                                            bool accepted) {
  auto callbacks = std::move(state.private_publication_waiters);
  state.private_publication_waiters.clear();
  for (auto& callback : callbacks) base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(std::move(callback), accepted));
}

std::optional<aegis_access::RegisteredProxyEndpoint>
AccessNetworkContextTransport::CaptureSelectedProxyEndpoint(
    const aegis_access::OwnershipKey& owner,
    const std::string& proxy_group_id,
    const std::string& exact_host) const {
  if (!aegis_access::IsCompleteOwner(owner) || proxy_group_id.empty() ||
      !IsCanonicalExactHost(exact_host) || !OwnsConfiguredPartition(owner) ||
      network_epoch_ == 0) {
    return std::nullopt;
  }

  const auto it = partitions_.find(owner.storage_partition_token);
  if (it != partitions_.end()) {
    const auto entry = it->second.private_endpoints.find(proxy_group_id);
    if (entry != it->second.private_endpoints.end()) {
      const auto& endpoint = entry->second.registration;
      return endpoint.owner == owner && endpoint.generations.network_epoch == network_epoch_
          ? std::make_optional(endpoint) : std::nullopt;
    }
  }
  // PublishProxySelection() sorts exact_hosts before committing PartitionState.
  if (it == partitions_.end() || !it->second.endpoint.has_value() ||
      !std::binary_search(it->second.exact_hosts.begin(),
                          it->second.exact_hosts.end(), exact_host)) {
    return std::nullopt;
  }

  const aegis_access::RegisteredProxyEndpoint& endpoint = *it->second.endpoint;
  if (endpoint.owner != owner || endpoint.proxy_group_id != proxy_group_id ||
      endpoint.generations.network_epoch != network_epoch_) {
    return std::nullopt;
  }
  return endpoint;
}

AccessNetworkConfigAckResult
AccessNetworkContextTransport::RepublishCurrentConfigWithAck(
    const aegis_access::OwnershipKey& owner,
    base::OnceCallback<void(bool)> all_clients_settled) {
  if (!all_clients_settled) {
    return {AccessNetworkConfigAckStatus::kInvalidOwner, 0};
  }
  auto fail = [&](AccessNetworkConfigAckStatus status) {
    std::move(all_clients_settled).Run(false);
    return AccessNetworkConfigAckResult{status, 0};
  };
  if (!OwnsConfiguredPartition(owner)) {
    return fail(AccessNetworkConfigAckStatus::kInvalidOwner);
  }
  auto it = partitions_.find(owner.storage_partition_token);
  if (it == partitions_.end()) {
    return fail(AccessNetworkConfigAckStatus::kMissingPartition);
  }
  PartitionState& state = it->second;
  if (state.clients.empty()) {
    return fail(AccessNetworkConfigAckStatus::kNoClients);
  }
  network::mojom::CustomProxyConfigPtr config = BuildConfig(state);
  if (!config) {
    return fail(AccessNetworkConfigAckStatus::kBuildFailed);
  }

  const size_t required_acks = state.clients.size();
  UpdateClientConfigs(state, config, std::move(all_clients_settled));
  return {AccessNetworkConfigAckStatus::kStarted, required_acks};
}

AccessNetworkConfigAckResult
AccessNetworkContextTransport::PublishPolicyCandidateWithAck(
    const aegis_access::PolicyPublicationIdentity& identity,
    const aegis_access::OwnershipKey& owner,
    base::OnceCallback<void(bool)> all_clients_settled) {
  if (!all_clients_settled) {
    return {AccessNetworkConfigAckStatus::kInvalidPublication, 0};
  }
  auto fail = [&](AccessNetworkConfigAckStatus status) {
    std::move(all_clients_settled).Run(false);
    return AccessNetworkConfigAckResult{status, 0};
  };
  if (!OwnsConfiguredPartition(owner) || identity.selector.owner != owner) {
    return fail(AccessNetworkConfigAckStatus::kInvalidOwner);
  }
  if (!IsCandidateIdentityValid(identity, network_epoch_)) {
    return fail(AccessNetworkConfigAckStatus::kInvalidPublication);
  }
  auto it = partitions_.find(owner.storage_partition_token);
  if (it == partitions_.end()) {
    return fail(AccessNetworkConfigAckStatus::kMissingPartition);
  }
  PartitionState& state = it->second;
  if (state.clients.empty()) {
    return fail(AccessNetworkConfigAckStatus::kNoClients);
  }
  if (!SelectionMatchesIdentity(state, identity)) {
    return fail(AccessNetworkConfigAckStatus::kInvalidPublication);
  }

  const size_t required_acks = state.clients.size();
  PublishPolicyCandidateToClients(state, identity, owner,
                                  std::move(all_clients_settled));
  return {AccessNetworkConfigAckStatus::kStarted, required_acks};
}

std::optional<aegis_access::RegisteredProxyEndpoint>
AccessNetworkContextTransport::CurrentEndpoint(
    const aegis_access::OwnershipKey& owner) const {
  if (!OwnsConfiguredPartition(owner)) {
    return std::nullopt;
  }
  return partitions_.at(owner.storage_partition_token).endpoint;
}

std::optional<AccessTransportSelection>
AccessNetworkContextTransport::CurrentSelection(
    const aegis_access::OwnershipKey& owner) const {
  if (!OwnsConfiguredPartition(owner)) {
    return std::nullopt;
  }
  const auto& state = partitions_.at(owner.storage_partition_token);
  return AccessTransportSelection{state.endpoint, state.exact_hosts};
}

bool AccessNetworkContextTransport::ReplaceSelection(
    const aegis_access::OwnershipKey& owner,
    const AccessTransportSelection& expected,
    const AccessTransportSelection& replacement) {
  const bool private_context = OwnsConfiguredPartition(owner) &&
      partitions_.at(owner.storage_partition_token).private_routing;
  if (CurrentSelection(owner) != expected ||
      (replacement.endpoint && replacement.endpoint->owner != owner) ||
      (!replacement.exact_hosts.empty() &&
       ((!replacement.endpoint && !private_context) ||
        !AreCanonicalExactHosts(replacement.exact_hosts)))) {
    return false;
  }
  auto& state = partitions_.at(owner.storage_partition_token);
  state.endpoint = replacement.endpoint;
  state.exact_hosts = replacement.exact_hosts;
  if (replacement.endpoint) {
    auto found = state.private_endpoints.find(replacement.endpoint->proxy_group_id);
    if (found != state.private_endpoints.end() &&
        found->second.registration.registration_id == replacement.endpoint->registration_id)
      found->second.registration = *replacement.endpoint;
  }
  // The policy metadata is sent after this config on the same Mojo pipe.
  if (!private_context) Broadcast(state);
  return true;
}

bool AccessNetworkContextTransport::SelectionMatchesIdentity(
    const PartitionState& state,
    const aegis_access::PolicyPublicationIdentity& identity) {
  if (identity.selection_generation == 0) {
    return true;
  }
  return state.endpoint && state.endpoint->owner == identity.selector.owner &&
         state.endpoint->proxy_group_id == identity.proxy_group_id &&
         state.endpoint->generations.selection_generation ==
             identity.selection_generation &&
         state.endpoint->generations.network_epoch == identity.network_epoch &&
         std::binary_search(state.exact_hosts.begin(), state.exact_hosts.end(),
                            identity.selector.exact_host);
}

bool AccessNetworkContextTransport::PublicationStillCurrent(
    const aegis_access::PolicyPublicationIdentity& identity,
    uint64_t clients_generation,
    size_t client_count) const {
  if (network_epoch_ != identity.network_epoch) {
    return false;
  }
  const auto it =
      partitions_.find(identity.selector.owner.storage_partition_token);
  return it != partitions_.end() &&
         it->second.clients_generation == clients_generation &&
         it->second.clients.size() == client_count &&
         SelectionMatchesIdentity(it->second, identity);
}

void AccessNetworkContextTransport::PublishPolicyCandidateToClients(
    PartitionState& state,
    const aegis_access::PolicyPublicationIdentity& identity,
    const aegis_access::OwnershipKey& owner,
    base::OnceCallback<void(bool)> all_clients_settled) {
  auto metadata = network::mojom::AegisAccessPolicyPublicationMetadata::New();
  metadata->operation_id = identity.operation_id;
  metadata->operation_sequence = identity.operation_sequence;
  metadata->policy_generation = identity.policy_generation;
  metadata->proxy_group_id = identity.proxy_group_id;
  metadata->selection_generation = identity.selection_generation;
  metadata->network_epoch = identity.network_epoch;
  metadata->channel = static_cast<uint32_t>(owner.channel);
  metadata->profile_token = owner.profile_token;
  metadata->storage_partition_token = owner.storage_partition_token;

  auto all_succeeded = std::make_shared<bool>(true);
  base::RepeatingClosure barrier = base::BarrierClosure(
      state.clients.size(),
      base::BindOnce(
          [](base::WeakPtr<AccessNetworkContextTransport> transport,
             aegis_access::PolicyPublicationIdentity identity,
             uint64_t clients_generation, size_t client_count,
             std::shared_ptr<bool> succeeded,
             base::OnceCallback<void(bool)> completion) {
            const bool current =
                transport && transport->PublicationStillCurrent(
                                 identity, clients_generation, client_count);
            std::move(completion).Run(*succeeded && current);
          },
          weak_factory_.GetWeakPtr(), identity, state.clients_generation,
          state.clients.size(), all_succeeded, std::move(all_clients_settled)));

  for (auto& client : state.clients) {
    base::OnceCallback<void(bool)> result =
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(
            base::BindOnce(
                [](std::shared_ptr<bool> succeeded,
                   base::RepeatingClosure completion, bool client_acked) {
                  *succeeded = *succeeded && client_acked;
                  completion.Run();
                },
                all_succeeded, barrier),
            false);
    client->OnAegisAccessPolicyPublished(metadata->Clone(), std::move(result));
  }
}

void AccessNetworkContextTransport::UpdateClientConfigs(
    PartitionState& state,
    const network::mojom::CustomProxyConfigPtr& config,
    base::OnceCallback<void(bool)> all_clients_settled) {
  auto all_succeeded = std::make_shared<bool>(true);
  base::RepeatingClosure barrier = base::BarrierClosure(
      state.clients.size(),
      base::BindOnce(
          [](std::shared_ptr<bool> succeeded,
             base::OnceCallback<void(bool)> completion) {
            std::move(completion).Run(*succeeded);
          },
          all_succeeded, std::move(all_clients_settled)));

  for (auto& client : state.clients) {
    base::OnceCallback<void(bool)> result =
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(
            base::BindOnce(
                [](std::shared_ptr<bool> succeeded,
                   base::RepeatingClosure completion, bool client_acked) {
                  *succeeded = *succeeded && client_acked;
                  completion.Run();
                },
                all_succeeded, barrier),
            false);
    client->OnCustomProxyConfigUpdated(
        config->Clone(),
        base::BindOnce(
            [](base::OnceCallback<void(bool)> result_callback) {
              std::move(result_callback).Run(true);
            },
            std::move(result)));
  }
}

network::mojom::CustomProxyConfigPtr
AccessNetworkContextTransport::BuildConfigForTesting(
    const base::FilePath& relative_partition_path) const {
  const std::optional<std::string> key = PartitionKey(relative_partition_path);
  if (!key) {
    return nullptr;
  }
  auto it = partitions_.find(*key);
  if (it == partitions_.end()) {
    return network::mojom::CustomProxyConfig::New();
  }
  return BuildConfig(it->second);
}

void AccessNetworkContextTransport::FlushClientsForTesting(
    const base::FilePath& relative_partition_path) {
  const std::optional<std::string> key = PartitionKey(relative_partition_path);
  if (!key) {
    return;
  }
  auto it = partitions_.find(*key);
  if (it != partitions_.end()) {
    it->second.clients.FlushForTesting();
  }
}

// static
std::optional<std::string> AccessNetworkContextTransport::PartitionKey(
    const base::FilePath& relative_partition_path) {
  if (relative_partition_path.IsAbsolute() ||
      relative_partition_path.ReferencesParent()) {
    return std::nullopt;
  }
  const std::string value = relative_partition_path.AsUTF8Unsafe();
  if (value.size() > kMaxPartitionKeyBytes) {
    return std::nullopt;
  }
  return value.empty() ? std::optional<std::string>("<default>")
                       : std::optional<std::string>("partition:" + value);
}

std::optional<std::string> AccessNetworkContextTransport::PartitionToken(
    const base::FilePath& relative_partition_path) const {
  return PartitionKey(relative_partition_path);
}

bool AccessNetworkContextTransport::IsEndpointCurrentForPartition(
    const base::FilePath& relative_partition_path,
    const aegis_access::RegisteredProxyEndpoint& endpoint) const {
  const std::optional<aegis_access::OwnershipKey> expected_owner =
      OwnerForPartition(endpoint.owner.channel, relative_partition_path);
  return network_epoch_ != 0 && expected_owner.has_value() &&
         endpoint.owner == *expected_owner &&
         endpoint.generations.network_epoch == network_epoch_;
}

network::mojom::CustomProxyConfigPtr AccessNetworkContextTransport::BuildConfig(
    const PartitionState& state) const {
#if BUILDFLAG(IS_MAC)
  if (state.account_config) return state.account_config->Clone();
#endif
  auto config = network::mojom::CustomProxyConfig::New();
  if (state.private_routing || !state.endpoint.has_value() ||
      state.exact_hosts.empty()) {
    return config;
  }

  net::ProxyInfo proxy_info;
  proxy_info.UseDirect();
  const aegis_access::ProxyRouteApplyStatus status =
      aegis_access::ApplyRoutePlanToProxyInfo(RoutePlanForEndpoint(*state.endpoint),
                                              &*state.endpoint, &proxy_info);
  if (status != aegis_access::ProxyRouteApplyStatus::kAppliedProxy ||
      proxy_info.is_empty() || proxy_info.is_direct()) {
    return nullptr;
  }

  config->rules.type =
      net::ProxyConfig::ProxyRules::Type::PROXY_LIST_PER_SCHEME;
  config->rules.proxies_for_http = proxy_info.proxy_list();
  config->rules.proxies_for_https = proxy_info.proxy_list();
  for (const std::string& host : state.exact_hosts) {
    if (!config->rules.bypass_rules.AddRuleFromString(host)) {
      return nullptr;
    }
  }
  // Positive rules become the only destinations that do NOT bypass this
  // custom proxy. A non-selected URL resolves to DIRECT inside the custom
  // config, causing NetworkServiceProxyDelegate to preserve the native result.
  config->rules.reverse_bypass = true;
  config->should_override_existing_config = true;
  config->allow_non_idempotent_methods = true;
  return config;
}

void AccessNetworkContextTransport::Broadcast(PartitionState& state) {
  network::mojom::CustomProxyConfigPtr config = BuildConfig(state);
  if (!config) {
    return;
  }
  for (auto& client : state.clients) {
    client->OnCustomProxyConfigUpdated(config->Clone(), base::DoNothing());
  }
}

}  // namespace aegis::access
