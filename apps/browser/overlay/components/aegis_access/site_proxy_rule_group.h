// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_SITE_PROXY_RULE_GROUP_H_
#define COMPONENTS_AEGIS_ACCESS_SITE_PROXY_RULE_GROUP_H_

#include <cstdint>
#include <string>
#include <vector>

#include "components/aegis_access/access_route_types.h"

namespace aegis_access {

enum class RequestScheme {
  kHttp,
  kHttps,
  kWs,
  kWss,
  kInvalid,
};

enum class PortScope {
  kAllBrowserPermitted,
  kExplicitSubset,
  kInvalid,
};

enum class ProtectionOverride {
  kNone,
  kTracker,
  kEasyList,
  kCname,
  kInvalid,
};

struct SiteProxyRuleGroup {
  std::string site_toggle_id;
  std::string canonical_host;
  OwnershipKey owner;
  std::string http_top_level_site;
  std::string https_top_level_site;
  std::vector<std::string> member_rule_ids;
  uint64_t revision = 0;
  uint64_t last_operation_sequence = 0;

  friend bool operator==(const SiteProxyRuleGroup&,
                         const SiteProxyRuleGroup&) = default;
};

struct SiteProxyRuleMember {
  std::string rule_id;
  OwnershipKey owner;
  std::string site_toggle_id;
  uint64_t group_revision = 0;
  std::string top_level_site;
  std::string exact_host;
  std::vector<RequestScheme> schemes;
  PortScope ports = PortScope::kInvalid;
  bool include_subdomains = false;
  AccessMode mode = AccessMode::kInvalid;
  std::string proxy_group_id;
  ProtectionOverride protection_override = ProtectionOverride::kInvalid;
  uint64_t last_operation_sequence = 0;

  friend bool operator==(const SiteProxyRuleMember&,
                         const SiteProxyRuleMember&) = default;
};

enum class GroupSelection {
  kEnabled,
  kDisabled,
  kUnknown,
};

enum class GroupPresence {
  kAbsent,
  kPresent,
};

enum class GroupValidationError {
  kNone,
  kMissingGroup,
  kInvalidGroup,
  kMemberCountMismatch,
  kMemberIdsMismatch,
  kDuplicateMember,
  kOwnershipMismatch,
  kHostMismatch,
  kTopLevelSiteMismatch,
  kRevisionMismatch,
  kOperationSequenceMismatch,
  kSchemesMismatch,
  kPortsMismatch,
  kSubdomainsNotAllowed,
  kProtectionOverrideNotAllowed,
  kUnsupportedMode,
  kModeMismatch,
  kProxyGroupMismatch,
};

struct GroupValidation {
  GroupPresence presence = GroupPresence::kPresent;
  GroupSelection selection = GroupSelection::kUnknown;
  GroupValidationError error = GroupValidationError::kInvalidGroup;

  friend bool operator==(const GroupValidation&, const GroupValidation&) =
      default;
};

// Validates the atomic HTTP/HTTPS member pair supplied by a trusted adapter.
// expected_owner comes from the native service/storage context, independently
// of the stored group. The other inputs must already contain canonical
// browser-owned identifiers; this function does not parse URLs, derive
// registrable domains, or perform I/O. An absent group remains absent/unknown;
// only a later matcher with a published snapshot may resolve inheritance.
GroupValidation ValidateSiteProxyRuleGroup(
    const OwnershipKey& expected_owner,
    const SiteProxyRuleGroup* group,
    const std::vector<SiteProxyRuleMember>& members);

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_SITE_PROXY_RULE_GROUP_H_
