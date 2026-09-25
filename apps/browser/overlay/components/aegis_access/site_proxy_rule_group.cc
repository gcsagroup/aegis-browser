// Copyright 2026 GCSA

#include "components/aegis_access/site_proxy_rule_group.h"

#include <set>

namespace aegis_access {
namespace {

GroupValidation Unknown(GroupValidationError error) {
  return GroupValidation{GroupPresence::kPresent, GroupSelection::kUnknown,
                         error};
}

bool HasCompleteSchemeSet(const std::vector<RequestScheme>& schemes) {
  if (schemes.size() != 4) {
    return false;
  }
  const std::set<RequestScheme> actual(schemes.begin(), schemes.end());
  const std::set<RequestScheme> expected = {
      RequestScheme::kHttp, RequestScheme::kHttps, RequestScheme::kWs,
      RequestScheme::kWss};
  return actual == expected;
}

}  // namespace

bool IsSiteProxyTransportCompatible(const SiteProxyTransportRule& candidate,
                                    const SiteProxyTransportRule& existing) {
  if (candidate.host.empty() || candidate.include_subdomains ||
      (candidate.mode != AccessMode::kDirect &&
       candidate.mode != AccessMode::kProxy) ||
      (candidate.mode == AccessMode::kProxy) == candidate.proxy_group_id.empty()) {
    return false;
  }
  const bool overlaps =
      candidate.host == existing.host ||
      (existing.include_subdomains && !existing.host.empty() &&
       candidate.host.size() > existing.host.size() &&
       candidate.host.ends_with(existing.host) &&
       candidate.host[candidate.host.size() - existing.host.size() - 1] == '.');
  if (!overlaps || existing.mode == AccessMode::kReject) {
    return true;
  }
  return candidate.mode == existing.mode &&
         candidate.proxy_group_id == existing.proxy_group_id;
}

GroupValidation ValidateSiteProxyRuleGroup(
    const OwnershipKey& expected_owner,
    const SiteProxyRuleGroup* group,
    const std::vector<SiteProxyRuleMember>& members) {
  if (group == nullptr) {
    return GroupValidation{GroupPresence::kAbsent, GroupSelection::kUnknown,
                           GroupValidationError::kMissingGroup};
  }
  if (group->site_toggle_id.empty() || group->canonical_host.empty() ||
      !IsCompleteOwner(group->owner) || group->http_top_level_site.empty() ||
      group->https_top_level_site.empty() ||
      group->http_top_level_site == group->https_top_level_site ||
      group->revision == 0 || group->last_operation_sequence == 0) {
    return Unknown(GroupValidationError::kInvalidGroup);
  }
  if (!IsCompleteOwner(expected_owner) || group->owner != expected_owner) {
    return Unknown(GroupValidationError::kOwnershipMismatch);
  }
  if (members.size() != 2) {
    return Unknown(GroupValidationError::kMemberCountMismatch);
  }
  if (group->member_rule_ids.size() != 2 ||
      group->member_rule_ids[0].empty() ||
      group->member_rule_ids[1].empty() ||
      group->member_rule_ids[0] == group->member_rule_ids[1]) {
    return Unknown(GroupValidationError::kMemberIdsMismatch);
  }
  if (members[0].rule_id.empty() || members[1].rule_id.empty() ||
      members[0].rule_id == members[1].rule_id) {
    return Unknown(GroupValidationError::kDuplicateMember);
  }

  const std::set<std::string> expected_ids(group->member_rule_ids.begin(),
                                            group->member_rule_ids.end());
  const std::set<std::string> actual_ids = {members[0].rule_id,
                                            members[1].rule_id};
  if (actual_ids != expected_ids) {
    return Unknown(GroupValidationError::kMemberIdsMismatch);
  }

  for (const SiteProxyRuleMember& member : members) {
    if (!IsCompleteOwner(member.owner) || member.owner != group->owner ||
        member.site_toggle_id != group->site_toggle_id) {
      return Unknown(GroupValidationError::kOwnershipMismatch);
    }
  }
  for (const SiteProxyRuleMember& member : members) {
    if (member.exact_host != group->canonical_host) {
      return Unknown(GroupValidationError::kHostMismatch);
    }
  }

  const std::set<std::string> expected_sites = {group->http_top_level_site,
                                                group->https_top_level_site};
  const std::set<std::string> actual_sites = {members[0].top_level_site,
                                              members[1].top_level_site};
  if (actual_sites != expected_sites || actual_sites.size() != 2) {
    return Unknown(GroupValidationError::kTopLevelSiteMismatch);
  }

  for (const SiteProxyRuleMember& member : members) {
    if (member.group_revision != group->revision) {
      return Unknown(GroupValidationError::kRevisionMismatch);
    }
  }
  for (const SiteProxyRuleMember& member : members) {
    if (member.last_operation_sequence != group->last_operation_sequence) {
      return Unknown(GroupValidationError::kOperationSequenceMismatch);
    }
  }
  for (const SiteProxyRuleMember& member : members) {
    if (!HasCompleteSchemeSet(member.schemes)) {
      return Unknown(GroupValidationError::kSchemesMismatch);
    }
  }
  for (const SiteProxyRuleMember& member : members) {
    if (member.ports != PortScope::kAllBrowserPermitted) {
      return Unknown(GroupValidationError::kPortsMismatch);
    }
  }
  for (const SiteProxyRuleMember& member : members) {
    if (member.include_subdomains) {
      return Unknown(GroupValidationError::kSubdomainsNotAllowed);
    }
  }
  for (const SiteProxyRuleMember& member : members) {
    if (member.protection_override != ProtectionOverride::kNone) {
      return Unknown(GroupValidationError::kProtectionOverrideNotAllowed);
    }
  }
  for (const SiteProxyRuleMember& member : members) {
    if (member.mode != AccessMode::kDirect &&
        member.mode != AccessMode::kProxy) {
      return Unknown(GroupValidationError::kUnsupportedMode);
    }
  }

  if (members[0].mode != members[1].mode) {
    return Unknown(GroupValidationError::kModeMismatch);
  }
  if (members[0].mode == AccessMode::kDirect) {
    if (!members[0].proxy_group_id.empty() ||
        !members[1].proxy_group_id.empty()) {
      return Unknown(GroupValidationError::kProxyGroupMismatch);
    }
    return GroupValidation{GroupPresence::kPresent, GroupSelection::kDisabled,
                           GroupValidationError::kNone};
  }
  if (members[0].proxy_group_id.empty() ||
      members[0].proxy_group_id != members[1].proxy_group_id) {
    return Unknown(GroupValidationError::kProxyGroupMismatch);
  }
  return GroupValidation{GroupPresence::kPresent, GroupSelection::kEnabled,
                         GroupValidationError::kNone};
}

}  // namespace aegis_access
