// Copyright 2026 GCSA
#include "services/network/aegis/access_route_registry.h"

#include "base/check.h"
#include "net/http/http_auth_cache.h"

namespace network {
namespace {
using aegis_access::GenerationTuple;
std::optional<net::AuthCredentials> LocalCredentials(
    const scoped_refptr<net::AccessProxyRoute>& route) {
  const auto& proxy = route->proxy_chain().GetProxyServer(0);
  auto* entry = route->proxy_auth_cache()->Lookup(
      url::SchemeHostPort(url::kHttpScheme, proxy.host_port_pair().host(),
                          proxy.host_port_pair().port()),
      net::HttpAuth::AUTH_PROXY, "proxy", net::HttpAuth::AUTH_SCHEME_BASIC,
      net::NetworkAnonymizationKey());
  return entry ? std::make_optional(entry->credentials()) : std::nullopt;
}
bool SameCredentials(const std::optional<net::AuthCredentials>& a,
                     const std::optional<net::AuthCredentials>& b) {
  return a.has_value() == b.has_value() && (!a || a->Equals(*b));
}
bool SameCommon(const GenerationTuple& a, const GenerationTuple& b) {
  return a.policy_generation == b.policy_generation &&
         a.identity_generation == b.identity_generation &&
         a.network_epoch == b.network_epoch &&
         a.base_proxy_config_generation == b.base_proxy_config_generation;
}
GenerationTuple Generations(const net::AccessRouteIsolationKey& key) {
  return {key.policy_generation, key.identity_generation,
          key.selection_generation, key.network_epoch,
          key.base_proxy_config_generation};
}
bool IsLiveCommon(const GenerationTuple& common) {
  return common.policy_generation && common.identity_generation &&
         common.network_epoch && common.base_proxy_config_generation &&
         common.selection_generation == 0;
}
bool IsNondecreasing(const GenerationTuple& next, const GenerationTuple& old) {
  return next.policy_generation >= old.policy_generation &&
         next.identity_generation >= old.identity_generation &&
         next.network_epoch >= old.network_epoch &&
         next.base_proxy_config_generation >= old.base_proxy_config_generation;
}
}  // namespace

AccessRouteRegistry::AccessRouteRegistry(aegis_access::OwnershipKey owner,
                                         std::string incarnation)
    : owner_(std::move(owner)), incarnation_(std::move(incarnation)) {
  CHECK(aegis_access::IsCompleteOwner(owner_));
  CHECK(!incarnation_.empty());
}
AccessRouteRegistry::~AccessRouteRegistry() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
}

bool AccessRouteRegistry::Install(uint64_t sequence, Snapshot snapshot) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  const auto& common = snapshot.common_generations;
  if (sequence <= installed_sequence_ || snapshot.policy.owner != owner_ ||
      !IsLiveCommon(common) ||
      (last_policy_ &&
       snapshot.policy.policy_generation == last_policy_->policy_generation &&
       snapshot.policy != *last_policy_) ||
      snapshot.policy.policy_generation != common.policy_generation ||
      (high_water_generations_ &&
       !IsNondecreasing(common, *high_water_generations_)) ||
      aegis_access::ValidateAccessPolicySnapshot(snapshot.policy) !=
          aegis_access::PolicyMatchReason::kNone) {
    return false;
  }
  for (const auto& [group, route] : snapshot.routes) {
    if (!route || group.empty()) {
      return false;
    }
    const auto& key = route->isolation_key();
    if (!key.IsComplete() || key.group != group ||
        key.channel != static_cast<uint8_t>(owner_.channel) ||
        key.profile != owner_.profile_token ||
        key.partition != owner_.storage_partition_token ||
        key.incarnation != incarnation_ ||
        !SameCommon(Generations(key), common) ||
        !route->proxy_chain().is_single_proxy() ||
        !route->proxy_chain().GetProxyServer(0).is_http()) {
      return false;
    }
  }
  for (const auto& [group, selection] : snapshot.unavailable_groups) {
    const auto high_water = selection_high_water_.find(group);
    if (group.empty() || snapshot.routes.contains(group) ||
        (high_water != selection_high_water_.end() &&
         selection < high_water->second)) {
      return false;
    }
  }
  std::map<std::string, std::string> candidate_registrations;
  for (const auto& [group, route] : snapshot.routes) {
    const auto& key = route->isolation_key();
    auto high_water = selection_high_water_.find(group);
    if (high_water != selection_high_water_.end() &&
        key.selection_generation < high_water->second) {
      return false;
    }
    if (!candidate_registrations.emplace(key.registration, group).second) {
      return false;
    }
    auto old = registrations_.find(key.registration);
    if (old != registrations_.end() &&
        (old->second.group != group ||
         old->second.proxy_chain != route->proxy_chain() ||
         !SameCredentials(old->second.local_credentials, LocalCredentials(route)))) {
      return false;
    }
  }
  for (const auto& rule : snapshot.policy.rules) {
    if (rule.mode == aegis_access::AccessMode::kProxy &&
        !snapshot.routes.contains(rule.proxy_group_id) &&
        !snapshot.unavailable_groups.contains(rule.proxy_group_id)) {
      return false;
    }
  }
  // All validation completes before any live state or high-water mark changes.
  for (const auto& [group, selection] : snapshot.unavailable_groups) {
    selection_high_water_[group] = selection;
  }
  for (const auto& [group, route] : snapshot.routes) {
    const auto& key = route->isolation_key();
    selection_high_water_[group] = key.selection_generation;
    registrations_.insert_or_assign(
        key.registration, RegistrationBinding{group, route->proxy_chain(),
                                               LocalCredentials(route)});
  }
  last_policy_ = snapshot.policy;
  installed_sequence_ = sequence;
  high_water_generations_ = common;
  snapshot_ = std::move(snapshot);
  return true;
}

void AccessRouteRegistry::EnterRestoring() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  snapshot_.reset();
}

AccessRouteRegistry::Result AccessRouteRegistry::Resolve(
    const aegis_access::BrowserOwnedRequestMetadata& metadata,
    const GURL& target, const Expectation& expected) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!snapshot_ || metadata.owner != owner_ ||
      expected.incarnation != incarnation_ ||
      !SameCommon(expected.generations, snapshot_->common_generations)) {
    return {};
  }
  auto canonical = aegis_access::CanonicalizeBrowserOwnedRequest(metadata, target);
  if (!canonical.context) {
    return {};
  }
  const auto match = aegis_access::EvaluateAccessPolicy(*canonical.context,
                                                       snapshot_->policy);
  if (match.policy_state != aegis_access::PolicyState::kValid &&
      match.policy_state != aegis_access::PolicyState::kAbsent) {
    return {};
  }
  switch (match.effective_mode) {
    case aegis_access::AccessMode::kNone:
    case aegis_access::AccessMode::kDirect:
      if (expected.registration_id.empty() &&
          expected.generations.selection_generation == 0) {
        return {net::OK, nullptr};
      }
      return {};
    case aegis_access::AccessMode::kProxy: {
      if (snapshot_->unavailable_groups.contains(match.effective_proxy_group_id)) {
        return {net::ERR_PROXY_CONNECTION_FAILED, nullptr};
      }
      auto found = snapshot_->routes.find(match.effective_proxy_group_id);
      if (found == snapshot_->routes.end()) {
        return {};
      }
      const auto& key = found->second->isolation_key();
      if (expected.generations != Generations(key) ||
          expected.registration_id != key.registration) {
        return {};
      }
      return {net::OK, found->second};
    }
    case aegis_access::AccessMode::kReject:
    case aegis_access::AccessMode::kInvalid:
      return {};
  }
  return {};
}
}  // namespace network
