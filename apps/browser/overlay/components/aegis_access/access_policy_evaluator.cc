// Copyright 2026 GCSA

#include "components/aegis_access/access_policy_evaluator.h"

#include <algorithm>
#include <compare>
#include <functional>
#include <set>
#include <tuple>
#include <utility>

#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/base/schemeful_site.h"
#include "net/base/url_util.h"
#include "url/url_canon.h"

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

bool IsKnownScheme(RequestScheme scheme) {
  switch (scheme) {
    case RequestScheme::kHttp:
    case RequestScheme::kHttps:
    case RequestScheme::kWs:
    case RequestScheme::kWss:
      return true;
    case RequestScheme::kInvalid:
      return false;
  }
  return false;
}

bool IsKnownProtectionOverride(ProtectionOverride protection_override) {
  switch (protection_override) {
    case ProtectionOverride::kNone:
    case ProtectionOverride::kTracker:
    case ProtectionOverride::kEasyList:
    case ProtectionOverride::kCname:
      return true;
    case ProtectionOverride::kInvalid:
      return false;
  }
  return false;
}

bool IsCanonicalHost(const std::string& host, bool include_subdomains) {
  url::CanonHostInfo host_info;
  const std::string canonical = net::CanonicalizeHost(host, &host_info);
  if (canonical.empty() || canonical != host ||
      host_info.family == url::CanonHostInfo::BROKEN) {
    return false;
  }
  if (!include_subdomains) {
    return true;
  }
  if (host_info.IsIPAddress()) {
    return false;
  }
  return !net::registry_controlled_domains::GetDomainAndRegistry(
              canonical,
              net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES)
              .empty();
}

bool IsCanonicalTopLevelSite(const std::string& value) {
  if (value.empty()) {
    return false;
  }
  const net::SchemefulSite site = net::SchemefulSite::Deserialize(value);
  return !site.opaque() && site.GetURL().SchemeIsHTTPOrHTTPS() &&
         site.Serialize() == value;
}

bool IsStrictlySorted(const std::vector<RequestScheme>& schemes) {
  if (schemes.empty()) {
    return false;
  }
  for (size_t i = 0; i < schemes.size(); ++i) {
    if (!IsKnownScheme(schemes[i]) ||
        (i > 0 && schemes[i - 1] >= schemes[i])) {
      return false;
    }
  }
  return true;
}

bool IsStrictlySorted(const std::vector<uint16_t>& ports) {
  if (ports.empty()) {
    return false;
  }
  for (size_t i = 0; i < ports.size(); ++i) {
    if (ports[i] == 0 || (i > 0 && ports[i - 1] >= ports[i])) {
      return false;
    }
  }
  return true;
}

bool IsValidRule(const AccessPolicyRule& rule,
                 const OwnershipKey& snapshot_owner) {
  if (rule.rule_id.empty() || !IsComplete(rule.owner) ||
      rule.owner != snapshot_owner || rule.row_revision == 0 ||
      rule.last_operation_sequence == 0 ||
      !IsCanonicalHost(rule.destination_host, rule.include_subdomains) ||
      !IsStrictlySorted(rule.schemes) ||
      !IsKnownProtectionOverride(rule.protection_override)) {
    return false;
  }

  if (rule.scope == PolicyScope::kSite) {
    if (!IsCanonicalTopLevelSite(rule.top_level_site)) {
      return false;
    }
  } else if (rule.scope == PolicyScope::kProfile) {
    if (!rule.top_level_site.empty()) {
      return false;
    }
  } else {
    return false;
  }

  if (rule.ports.scope == PortScope::kAllBrowserPermitted) {
    if (!rule.ports.explicit_ports.empty()) {
      return false;
    }
  } else if (rule.ports.scope == PortScope::kExplicitSubset) {
    if (!IsStrictlySorted(rule.ports.explicit_ports)) {
      return false;
    }
  } else {
    return false;
  }

  if (rule.mode == AccessMode::kProxy) {
    return !rule.proxy_group_id.empty();
  }
  if (rule.mode == AccessMode::kDirect ||
      rule.mode == AccessMode::kReject) {
    return rule.proxy_group_id.empty() &&
           rule.protection_override == ProtectionOverride::kNone;
  }
  return false;
}

struct RuleKey {
  int channel;
  std::string profile_token;
  std::string storage_partition_token;
  PolicyScope scope;
  std::string top_level_site;
  std::string destination_host;
  bool include_subdomains;
  std::vector<RequestScheme> schemes;
  PortScope port_scope;
  std::vector<uint16_t> explicit_ports;

  friend auto operator<=>(const RuleKey&, const RuleKey&) = default;
};

RuleKey MakeRuleKey(const AccessPolicyRule& rule) {
  return RuleKey{static_cast<int>(rule.owner.channel),
                 rule.owner.profile_token,
                 rule.owner.storage_partition_token,
                 rule.scope,
                 rule.top_level_site,
                 rule.destination_host,
                 rule.include_subdomains,
                 rule.schemes,
                 rule.ports.scope,
                 rule.ports.explicit_ports};
}

bool HasDuplicateRuleKey(const std::vector<AccessPolicyRule>& rules) {
  std::set<RuleKey> keys;
  std::set<std::string> rule_ids;
  for (const AccessPolicyRule& rule : rules) {
    if (!rule_ids.insert(rule.rule_id).second ||
        !keys.insert(MakeRuleKey(rule)).second) {
      return true;
    }
  }
  return false;
}

bool Contains(const std::vector<RequestScheme>& schemes,
              RequestScheme scheme) {
  return std::binary_search(schemes.begin(), schemes.end(), scheme);
}

bool Contains(const RulePortSelector& ports, uint16_t port) {
  if (ports.scope == PortScope::kAllBrowserPermitted) {
    return true;
  }
  return std::binary_search(ports.explicit_ports.begin(),
                            ports.explicit_ports.end(), port);
}

bool HostMatches(const RequestPolicyContext& request,
                 const AccessPolicyRule& rule) {
  if (request.exact_host() == rule.destination_host) {
    return true;
  }
  if (!rule.include_subdomains || request.registrable_domain().empty()) {
    return false;
  }
  const std::string rule_domain =
      net::registry_controlled_domains::GetDomainAndRegistry(
          rule.destination_host,
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  return !rule_domain.empty() &&
         request.registrable_domain() == rule_domain &&
         net::IsSubdomainOf(request.exact_host(), rule.destination_host);
}

size_t HostLabelCount(const std::string& host) {
  if (host.empty()) {
    return 0;
  }
  const size_t length = host.back() == '.' ? host.size() - 1 : host.size();
  return 1 + static_cast<size_t>(
                 std::count(host.begin(), host.begin() + length, '.'));
}

bool VectorSubset(const std::vector<RequestScheme>& left,
                  const std::vector<RequestScheme>& right) {
  return std::includes(right.begin(), right.end(), left.begin(), left.end());
}

bool VectorSubset(const std::vector<uint16_t>& left,
                  const std::vector<uint16_t>& right) {
  return std::includes(right.begin(), right.end(), left.begin(), left.end());
}

bool PortSubset(const RulePortSelector& left,
                const RulePortSelector& right) {
  if (right.scope == PortScope::kAllBrowserPermitted) {
    return true;
  }
  if (left.scope == PortScope::kAllBrowserPermitted) {
    return false;
  }
  return VectorSubset(left.explicit_ports, right.explicit_ports);
}

bool SelectorMoreSpecific(const AccessPolicyRule& left,
                          const AccessPolicyRule& right) {
  const bool schemes_subset = VectorSubset(left.schemes, right.schemes);
  const bool ports_subset = PortSubset(left.ports, right.ports);
  if (!schemes_subset || !ports_subset) {
    return false;
  }
  return left.schemes != right.schemes || left.ports != right.ports;
}

struct Candidate {
  std::reference_wrapper<const AccessPolicyRule> rule;
  bool exact_host;
  size_t host_labels;
};

std::vector<Candidate> MatchingCandidates(
    const RequestPolicyContext& request,
    const PublishedAccessPolicySnapshot& snapshot,
    PolicyScope scope) {
  std::vector<Candidate> result;
  for (const AccessPolicyRule& rule : snapshot.rules) {
    if (rule.scope != scope ||
        (scope == PolicyScope::kSite &&
         (!request.site_ownership_reliable() ||
          rule.top_level_site != request.top_level_site())) ||
        !HostMatches(request, rule) || !Contains(rule.schemes, request.scheme()) ||
        !Contains(rule.ports, request.port())) {
      continue;
    }
    result.push_back(
        Candidate{std::cref(rule),
                  !rule.include_subdomains &&
                      request.exact_host() == rule.destination_host,
                  HostLabelCount(rule.destination_host)});
  }
  return result;
}

void KeepBestHostSpecificity(std::vector<Candidate>* candidates) {
  const bool has_exact =
      std::ranges::any_of(*candidates, [](const Candidate& candidate) {
        return candidate.exact_host;
      });
  if (has_exact) {
    std::erase_if(*candidates, [](const Candidate& candidate) {
      return !candidate.exact_host;
    });
    return;
  }
  const size_t longest =
      std::ranges::max_element(*candidates, {}, &Candidate::host_labels)
          ->host_labels;
  std::erase_if(*candidates, [longest](const Candidate& candidate) {
    return candidate.host_labels != longest;
  });
}

void KeepMaximalSelectors(std::vector<Candidate>* candidates) {
  std::vector<Candidate> maximal;
  for (const Candidate& candidate : *candidates) {
    const bool dominated =
        std::ranges::any_of(*candidates, [&candidate](const Candidate& other) {
          return &candidate.rule.get() != &other.rule.get() &&
                 SelectorMoreSpecific(other.rule.get(), candidate.rule.get());
        });
    if (!dominated) {
      maximal.push_back(candidate);
    }
  }
  *candidates = std::move(maximal);
}

PolicyMatchResult Error(PolicyState state, PolicyMatchReason reason,
                        uint64_t policy_generation) {
  return PolicyMatchResult{state,
                           AccessMode::kInvalid,
                           PolicyScope::kInvalid,
                           {},
                           {},
                           ProtectionOverride::kInvalid,
                           policy_generation,
                           reason};
}

}  // namespace

PolicyMatchResult EvaluateAccessPolicy(
    const RequestPolicyContext& request,
    const PublishedAccessPolicySnapshot& snapshot) {
  if (!IsComplete(snapshot.owner) || snapshot.policy_generation == 0) {
    return Error(PolicyState::kInvalid,
                 PolicyMatchReason::kInvalidSnapshot,
                 snapshot.policy_generation);
  }
  if (request.owner() != snapshot.owner) {
    return Error(PolicyState::kInvalid,
                 PolicyMatchReason::kOwnershipMismatch,
                 snapshot.policy_generation);
  }
  for (const AccessPolicyRule& rule : snapshot.rules) {
    if (!IsValidRule(rule, snapshot.owner)) {
      const PolicyMatchReason reason =
          rule.owner != snapshot.owner
              ? PolicyMatchReason::kOwnershipMismatch
              : PolicyMatchReason::kInvalidRule;
      return Error(PolicyState::kInvalid, reason,
                   snapshot.policy_generation);
    }
  }
  if (HasDuplicateRuleKey(snapshot.rules)) {
    return Error(PolicyState::kConflict,
                 PolicyMatchReason::kPolicyConflict,
                 snapshot.policy_generation);
  }

  std::vector<Candidate> candidates =
      MatchingCandidates(request, snapshot, PolicyScope::kSite);
  PolicyScope selected_scope = PolicyScope::kSite;
  if (candidates.empty()) {
    candidates = MatchingCandidates(request, snapshot, PolicyScope::kProfile);
    selected_scope = PolicyScope::kProfile;
  }
  if (candidates.empty()) {
    return PolicyMatchResult{PolicyState::kAbsent,
                             AccessMode::kNone,
                             PolicyScope::kNone,
                             {},
                             {},
                             ProtectionOverride::kNone,
                             snapshot.policy_generation,
                             PolicyMatchReason::kNoMatchingRule};
  }

  KeepBestHostSpecificity(&candidates);
  KeepMaximalSelectors(&candidates);
  if (candidates.size() != 1) {
    return Error(PolicyState::kConflict,
                 PolicyMatchReason::kPolicyConflict,
                 snapshot.policy_generation);
  }

  const AccessPolicyRule& rule = candidates.front().rule.get();
  return PolicyMatchResult{PolicyState::kValid,
                           rule.mode,
                           selected_scope,
                           rule.proxy_group_id,
                           rule.rule_id,
                           rule.protection_override,
                           snapshot.policy_generation,
                           PolicyMatchReason::kNone};
}

}  // namespace aegis_access
