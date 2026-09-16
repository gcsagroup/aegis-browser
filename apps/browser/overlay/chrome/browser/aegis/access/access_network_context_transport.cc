// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_network_context_transport.h"

#include <algorithm>
#include <utility>

#include "base/functional/callback_helpers.h"
#include "base/uuid.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "net/proxy_resolution/proxy_config.h"
#include "net/proxy_resolution/proxy_info.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

const void* const kTransportUserDataKey = &kTransportUserDataKey;
constexpr size_t kMaxExactHosts = 256;
constexpr size_t kMaxPartitionKeyBytes = 1024;

bool IsKnownChannel(aegis_access::ChannelNamespace channel) {
  switch (channel) {
    case aegis_access::ChannelNamespace::kDev:
    case aegis_access::ChannelNamespace::kAlpha:
    case aegis_access::ChannelNamespace::kBeta:
    case aegis_access::ChannelNamespace::kRelease:
      return true;
    case aegis_access::ChannelNamespace::kInvalid:
      return false;
  }
  return false;
}

bool IsCanonicalExactHost(const std::string& host) {
  if (host.empty()) {
    return false;
  }
  const GURL url("https://" + host + "/");
  return url.is_valid() && url.has_host() && url.host() == host;
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
  profile->SetUserData(kTransportUserDataKey, std::move(transport));
  return result;
}

AccessNetworkContextTransport::AccessNetworkContextTransport()
    : runtime_profile_token_(
          base::Uuid::GenerateRandomV4().AsLowercaseString()) {}

AccessNetworkContextTransport::~AccessNetworkContextTransport() = default;

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
  state.clients.Add(std::move(client));
  return true;
}

std::optional<aegis_access::OwnershipKey>
AccessNetworkContextTransport::OwnerForPartition(
    aegis_access::ChannelNamespace channel,
    const base::FilePath& relative_partition_path) const {
  if (!IsKnownChannel(channel)) {
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

bool AccessNetworkContextTransport::PublishProxySelection(
    const base::FilePath& relative_partition_path,
    std::vector<std::string> exact_hosts,
    const aegis_access::RegisteredProxyEndpoint& endpoint) {
  const std::optional<std::string> key = PartitionKey(relative_partition_path);
  const std::optional<aegis_access::OwnershipKey> expected_owner =
      OwnerForPartition(endpoint.owner.channel, relative_partition_path);
  if (!key || !expected_owner || endpoint.owner != *expected_owner ||
      exact_hosts.empty() || exact_hosts.size() > kMaxExactHosts) {
    return false;
  }

  std::sort(exact_hosts.begin(), exact_hosts.end());
  if (std::adjacent_find(exact_hosts.begin(), exact_hosts.end()) !=
      exact_hosts.end()) {
    return false;
  }
  if (!std::ranges::all_of(exact_hosts, IsCanonicalExactHost)) {
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
  state.endpoint = std::move(candidate.endpoint);
  state.exact_hosts = std::move(candidate.exact_hosts);
  Broadcast(state);
  return true;
}

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

network::mojom::CustomProxyConfigPtr AccessNetworkContextTransport::BuildConfig(
    const PartitionState& state) const {
  auto config = network::mojom::CustomProxyConfig::New();
  if (!state.endpoint.has_value() || state.exact_hosts.empty()) {
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
