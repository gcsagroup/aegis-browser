// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_PLANNER_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_PLANNER_CONTRACT_TEST_H_

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "components/aegis_access/access_route_planner.h"
#include "components/aegis_access/site_proxy_rule_group.h"

namespace aegis_access::test {

class ContractTestObserver {
 public:
  virtual ~ContractTestObserver() = default;
  virtual void Expect(bool condition, const std::string& label) = 0;
};

struct GoldenRouteVector {
  std::string name;
  RouteInput input;
  RouteAction expected_action;
  RouteReason expected_reason;
  std::optional<std::string> expected_registration_id;
};

inline OwnershipKey TestOwner() {
  return OwnershipKey{ChannelNamespace::kBeta, "profile-beta.example",
                      "partition-main.example"};
}

inline GenerationTuple TestGenerations() {
  return GenerationTuple{7, 11, 13, 17, 19};
}

inline RouteInput ReadyProxyInput() {
  const OwnershipKey owner = TestOwner();
  const GenerationTuple generations = TestGenerations();
  return RouteInput{
      PolicyState::kValid,
      AccessMode::kProxy,
      PolicyScope::kSite,
      "proxy-group-primary.example",
      true,
      true,
      owner,
      SnapshotState::kPublished,
      owner,
      generations,
      generations,
      ProtectionRestriction::kNone,
      ManagedRestriction::kNone,
      ProxyRuntimeState::kReady,
      RegisteredProxyEntry{"entry-beta-main.example",
                           "proxy-group-primary.example", owner, generations},
  };
}

inline std::vector<GoldenRouteVector> BuildGoldenRouteVectors() {
  std::vector<GoldenRouteVector> vectors;
#include "route_planner_golden_vectors.inc"
  return vectors;
}

inline void RunRoutePlannerContractTests(ContractTestObserver& observer) {
  const std::vector<GoldenRouteVector> vectors = BuildGoldenRouteVectors();
  observer.Expect(vectors.size() == 42, "shared vector count");
  for (const GoldenRouteVector& vector : vectors) {
    const RouteInput before = vector.input;
    const RoutePlan first = PlanAccessRoute(vector.input);
    const RoutePlan second = PlanAccessRoute(vector.input);
    observer.Expect(first.action == vector.expected_action,
                    vector.name + ": action");
    observer.Expect(first.reason == vector.expected_reason,
                    vector.name + ": reason");
    observer.Expect(first.effective_mode == vector.input.effective_mode,
                    vector.name + ": mode is preserved");
    observer.Expect(first.generations == vector.input.request_generations,
                    vector.name + ": request generations are preserved");
    observer.Expect(vector.input == before, vector.name + ": input is immutable");
    observer.Expect(first == second, vector.name + ": result is deterministic");
    observer.Expect(first.registered_proxy_entry.has_value() ==
                        vector.expected_registration_id.has_value(),
                    vector.name + ": entry presence");
    if (first.registered_proxy_entry.has_value() &&
        vector.expected_registration_id.has_value()) {
      observer.Expect(first.registered_proxy_entry->registration_id ==
                          *vector.expected_registration_id,
                      vector.name + ": opaque registration id");
      observer.Expect(first.registered_proxy_entry->proxy_group_id ==
                          vector.input.effective_proxy_group_id,
                      vector.name + ": logical proxy group binding");
    }
  }

  RouteInput input = ReadyProxyInput();
  input.effective_mode = static_cast<AccessMode>(999);
  observer.Expect(PlanAccessRoute(input).action == RouteAction::kFail,
                  "out-of-range mode fails");
  input = ReadyProxyInput();
  input.runtime_state = static_cast<ProxyRuntimeState>(999);
  observer.Expect(PlanAccessRoute(input).action == RouteAction::kFail,
                  "out-of-range runtime fails");
  input = ReadyProxyInput();
  input.request_owner.channel = static_cast<ChannelNamespace>(999);
  observer.Expect(PlanAccessRoute(input).action == RouteAction::kFail,
                  "out-of-range channel fails");
}

inline SiteProxyRuleGroup ValidGroup() {
  return SiteProxyRuleGroup{
      "site-toggle-example", "www.example.test", TestOwner(),
      "http://example.test", "https://example.test",
      {"rule-http-example", "rule-https-example"}, 23, 29};
}

inline std::vector<SiteProxyRuleMember> ValidMembers(AccessMode mode) {
  const std::string proxy_group =
      mode == AccessMode::kProxy ? "proxy-group-primary.example" : "";
  const std::vector<RequestScheme> schemes = {
      RequestScheme::kHttp, RequestScheme::kHttps, RequestScheme::kWs,
      RequestScheme::kWss};
  return {
      SiteProxyRuleMember{
          "rule-http-example", TestOwner(), "site-toggle-example", 23,
          "http://example.test", "www.example.test", schemes,
          PortScope::kAllBrowserPermitted, false, mode, proxy_group,
          ProtectionOverride::kNone, 29},
      SiteProxyRuleMember{
          "rule-https-example", TestOwner(), "site-toggle-example", 23,
          "https://example.test", "www.example.test", schemes,
          PortScope::kAllBrowserPermitted, false, mode, proxy_group,
          ProtectionOverride::kNone, 29},
  };
}

inline void ExpectGroup(ContractTestObserver& observer,
                        const std::string& label,
                        const OwnershipKey& expected_owner,
                        const SiteProxyRuleGroup* group,
                        const std::vector<SiteProxyRuleMember>& members,
                        GroupPresence presence,
                        GroupSelection selection,
                        GroupValidationError error) {
  const std::optional<SiteProxyRuleGroup> group_before =
      group == nullptr ? std::nullopt
                       : std::optional<SiteProxyRuleGroup>(*group);
  const std::vector<SiteProxyRuleMember> members_before = members;
  const GroupValidation first =
      ValidateSiteProxyRuleGroup(expected_owner, group, members);
  const GroupValidation second =
      ValidateSiteProxyRuleGroup(expected_owner, group, members);
  observer.Expect(first.presence == presence, label + ": presence");
  observer.Expect(first.selection == selection, label + ": selection");
  observer.Expect(first.error == error, label + ": error");
  observer.Expect(first == second, label + ": deterministic");
  observer.Expect(members == members_before, label + ": members immutable");
  if (group != nullptr) {
    observer.Expect(group_before.has_value() && *group == *group_before,
                    label + ": group immutable");
  }
}

inline void ExpectUnknown(ContractTestObserver& observer,
                          const std::string& label,
                          const SiteProxyRuleGroup& group,
                          const std::vector<SiteProxyRuleMember>& members,
                          GroupValidationError error) {
  ExpectGroup(observer, label, TestOwner(), &group, members,
              GroupPresence::kPresent, GroupSelection::kUnknown, error);
}

inline void RunSiteProxyRuleGroupContractTests(
    ContractTestObserver& observer) {
  SiteProxyRuleGroup group = ValidGroup();
  std::vector<SiteProxyRuleMember> members = ValidMembers(AccessMode::kDirect);
  ExpectGroup(observer, "valid direct group", TestOwner(), &group, members,
              GroupPresence::kPresent, GroupSelection::kDisabled,
              GroupValidationError::kNone);

  members = ValidMembers(AccessMode::kProxy);
  ExpectGroup(observer, "valid proxy group", TestOwner(), &group, members,
              GroupPresence::kPresent, GroupSelection::kEnabled,
              GroupValidationError::kNone);
  std::reverse(members.begin(), members.end());
  ExpectGroup(observer, "valid proxy group reversed", TestOwner(), &group,
              members, GroupPresence::kPresent, GroupSelection::kEnabled,
              GroupValidationError::kNone);

  ExpectGroup(observer, "absent group", TestOwner(), nullptr, {},
              GroupPresence::kAbsent, GroupSelection::kUnknown,
              GroupValidationError::kMissingGroup);

  group = ValidGroup();
  group.site_toggle_id.clear();
  ExpectUnknown(observer, "empty group id", group,
                ValidMembers(AccessMode::kDirect),
                GroupValidationError::kInvalidGroup);

  group = ValidGroup();
  OwnershipKey other_owner = TestOwner();
  other_owner.profile_token = "profile-other.example";
  ExpectGroup(observer, "external owner mismatch", other_owner, &group,
              ValidMembers(AccessMode::kDirect), GroupPresence::kPresent,
              GroupSelection::kUnknown,
              GroupValidationError::kOwnershipMismatch);

  group = ValidGroup();
  members = ValidMembers(AccessMode::kDirect);
  members.pop_back();
  ExpectUnknown(observer, "missing member", group, members,
                GroupValidationError::kMemberCountMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members.push_back(members.back());
  ExpectUnknown(observer, "extra member", group, members,
                GroupValidationError::kMemberCountMismatch);

  members = ValidMembers(AccessMode::kDirect);
  members[1].rule_id = members[0].rule_id;
  ExpectUnknown(observer, "duplicate member", group, members,
                GroupValidationError::kDuplicateMember);
  members = ValidMembers(AccessMode::kDirect);
  members[1].rule_id = "rule-not-listed.example";
  ExpectUnknown(observer, "member ids differ from group", group, members,
                GroupValidationError::kMemberIdsMismatch);

  members = ValidMembers(AccessMode::kDirect);
  members[1].owner.channel = ChannelNamespace::kAlpha;
  ExpectUnknown(observer, "member channel mismatch", group, members,
                GroupValidationError::kOwnershipMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].owner.profile_token = "profile-other.example";
  ExpectUnknown(observer, "member profile mismatch", group, members,
                GroupValidationError::kOwnershipMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].owner.storage_partition_token = "partition-other.example";
  ExpectUnknown(observer, "member partition mismatch", group, members,
                GroupValidationError::kOwnershipMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].site_toggle_id = "site-toggle-other";
  ExpectUnknown(observer, "member group id mismatch", group, members,
                GroupValidationError::kOwnershipMismatch);

  members = ValidMembers(AccessMode::kDirect);
  members[1].exact_host = "sub.www.example.test";
  ExpectUnknown(observer, "exact host mismatch", group, members,
                GroupValidationError::kHostMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].top_level_site = "https://other.example";
  ExpectUnknown(observer, "top-level site mismatch", group, members,
                GroupValidationError::kTopLevelSiteMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].group_revision = 22;
  ExpectUnknown(observer, "revision mismatch", group, members,
                GroupValidationError::kRevisionMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].last_operation_sequence = 28;
  ExpectUnknown(observer, "operation sequence mismatch", group, members,
                GroupValidationError::kOperationSequenceMismatch);

  members = ValidMembers(AccessMode::kDirect);
  members[1].schemes.pop_back();
  ExpectUnknown(observer, "scheme missing", group, members,
                GroupValidationError::kSchemesMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].schemes[3] = RequestScheme::kHttp;
  ExpectUnknown(observer, "scheme duplicate", group, members,
                GroupValidationError::kSchemesMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].ports = PortScope::kExplicitSubset;
  ExpectUnknown(observer, "explicit port subset", group, members,
                GroupValidationError::kPortsMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].include_subdomains = true;
  ExpectUnknown(observer, "subdomain expansion", group, members,
                GroupValidationError::kSubdomainsNotAllowed);
  members = ValidMembers(AccessMode::kDirect);
  members[1].protection_override = ProtectionOverride::kTracker;
  ExpectUnknown(observer, "protection override", group, members,
                GroupValidationError::kProtectionOverrideNotAllowed);
  members = ValidMembers(AccessMode::kDirect);
  members[1].mode = AccessMode::kReject;
  ExpectUnknown(observer, "reject member", group, members,
                GroupValidationError::kUnsupportedMode);
  members = ValidMembers(AccessMode::kDirect);
  members[1].mode = AccessMode::kProxy;
  members[1].proxy_group_id = "proxy-group-primary.example";
  ExpectUnknown(observer, "mixed modes", group, members,
                GroupValidationError::kModeMismatch);
  members = ValidMembers(AccessMode::kDirect);
  members[1].proxy_group_id = "proxy-group-primary.example";
  ExpectUnknown(observer, "direct member has proxy group", group, members,
                GroupValidationError::kProxyGroupMismatch);
  members = ValidMembers(AccessMode::kProxy);
  members[1].proxy_group_id = "proxy-group-other.example";
  ExpectUnknown(observer, "proxy group mismatch", group, members,
                GroupValidationError::kProxyGroupMismatch);

  members = ValidMembers(AccessMode::kDirect);
  members[0].exact_host = "host-error.example";
  members[1].owner.profile_token = "profile-error.example";
  ExpectUnknown(observer, "double error owner before host", group, members,
                GroupValidationError::kOwnershipMismatch);
  std::reverse(members.begin(), members.end());
  ExpectUnknown(observer, "double error owner before host reversed", group,
                members, GroupValidationError::kOwnershipMismatch);

  members = ValidMembers(AccessMode::kDirect);
  members[0].schemes.pop_back();
  members[1].group_revision = 22;
  ExpectUnknown(observer, "double error revision before schemes", group,
                members, GroupValidationError::kRevisionMismatch);
  std::reverse(members.begin(), members.end());
  ExpectUnknown(observer, "double error revision before schemes reversed",
                group, members, GroupValidationError::kRevisionMismatch);
}

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_PLANNER_CONTRACT_TEST_H_
