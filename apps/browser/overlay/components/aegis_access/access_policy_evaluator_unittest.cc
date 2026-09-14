// Copyright 2026 GCSA

#include "components/aegis_access/access_policy_evaluator.h"

#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/check.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis_access {
namespace {

OwnershipKey TestOwner() {
  return OwnershipKey{ChannelNamespace::kBeta, "profile-beta",
                      "partition-main"};
}

RequestPolicyContext DocumentContext(
    const std::string& target_url = "https://cdn.example.test/resource",
    const std::string& top_frame_url = "https://www.example.test/page") {
  const BrowserOwnedRequestMetadata metadata{
      "request-1", TestOwner(), RequestAttributionKind::kDocument,
      "document-1", {}, net::SchemefulSite(GURL(top_frame_url))};
  RequestPolicyContextResult result =
      CanonicalizeBrowserOwnedRequest(metadata, GURL(target_url));
  CHECK(result.context.has_value());
  return std::move(*result.context);
}

RequestPolicyContext ProfileOnlyContext(
    const std::string& target_url = "https://cdn.example.test/resource") {
  const BrowserOwnedRequestMetadata metadata{
      "request-profile", TestOwner(), RequestAttributionKind::kProfileOnly,
      {}, {}, std::nullopt};
  RequestPolicyContextResult result =
      CanonicalizeBrowserOwnedRequest(metadata, GURL(target_url));
  CHECK(result.context.has_value());
  return std::move(*result.context);
}

AccessPolicyRule Rule(std::string rule_id,
                      PolicyScope scope,
                      std::string host,
                      AccessMode mode) {
  return AccessPolicyRule{
      std::move(rule_id),
      TestOwner(),
      scope,
      scope == PolicyScope::kSite ? "https://example.test" : "",
      std::move(host),
      false,
      {RequestScheme::kHttp, RequestScheme::kHttps, RequestScheme::kWs,
       RequestScheme::kWss},
      RulePortSelector{PortScope::kAllBrowserPermitted, {}},
      mode,
      mode == AccessMode::kProxy ? "proxy-primary" : "",
      ProtectionOverride::kNone,
      1,
      1};
}

PublishedAccessPolicySnapshot Snapshot(std::vector<AccessPolicyRule> rules) {
  return PublishedAccessPolicySnapshot{TestOwner(), 7, std::move(rules)};
}

struct GoldenPolicyVector {
  std::string name;
  std::string target_url;
  std::string top_frame_url;
  RequestAttributionKind attribution_kind;
  std::vector<AccessPolicyRule> rules;
  PolicyState expected_state;
  AccessMode expected_mode;
  PolicyScope expected_scope;
  std::string expected_rule_id;
  PolicyMatchReason expected_reason;
};

std::vector<GoldenPolicyVector> BuildGoldenPolicyVectors() {
  std::vector<GoldenPolicyVector> vectors;
#include "policy_matcher_golden_vectors.inc"
  return vectors;
}

void ExpectMatch(const PolicyMatchResult& result,
                 const std::string& rule_id,
                 PolicyScope scope,
                 AccessMode mode) {
  EXPECT_EQ(result.policy_state, PolicyState::kValid);
  EXPECT_EQ(result.reason, PolicyMatchReason::kNone);
  EXPECT_EQ(result.matched_rule_id, rule_id);
  EXPECT_EQ(result.policy_scope, scope);
  EXPECT_EQ(result.effective_mode, mode);
  EXPECT_EQ(result.policy_generation, 7u);
}

TEST(AccessPolicyEvaluatorTest, SharedPolicyMatcherContract) {
  const std::vector<GoldenPolicyVector> vectors = BuildGoldenPolicyVectors();
  ASSERT_EQ(vectors.size(), 14u);
  for (const GoldenPolicyVector& vector : vectors) {
    RequestPolicyContext context =
        vector.attribution_kind == RequestAttributionKind::kProfileOnly
            ? ProfileOnlyContext(vector.target_url)
            : DocumentContext(vector.target_url, vector.top_frame_url);
    const PublishedAccessPolicySnapshot snapshot = Snapshot(vector.rules);
    const PolicyMatchResult first = EvaluateAccessPolicy(context, snapshot);
    const PolicyMatchResult second = EvaluateAccessPolicy(context, snapshot);
    EXPECT_EQ(first.policy_state, vector.expected_state) << vector.name;
    EXPECT_EQ(first.effective_mode, vector.expected_mode) << vector.name;
    EXPECT_EQ(first.policy_scope, vector.expected_scope) << vector.name;
    EXPECT_EQ(first.matched_rule_id, vector.expected_rule_id) << vector.name;
    EXPECT_EQ(first.reason, vector.expected_reason) << vector.name;
    EXPECT_EQ(first.policy_generation, 7u) << vector.name;
    EXPECT_EQ(first, second) << vector.name;
  }
}

TEST(AccessPolicyEvaluatorTest, SiteScopeBeatsProfileScope) {
  AccessPolicyRule site = Rule("site-proxy", PolicyScope::kSite,
                               "cdn.example.test", AccessMode::kProxy);
  AccessPolicyRule profile = Rule("profile-reject", PolicyScope::kProfile,
                                  "cdn.example.test", AccessMode::kReject);
  ExpectMatch(EvaluateAccessPolicy(DocumentContext(),
                                   Snapshot({profile, site})),
              "site-proxy", PolicyScope::kSite, AccessMode::kProxy);
}

TEST(AccessPolicyEvaluatorTest, ExactHostBeatsExplicitSuffix) {
  AccessPolicyRule suffix =
      Rule("suffix", PolicyScope::kSite, "example.test", AccessMode::kReject);
  suffix.include_subdomains = true;
  AccessPolicyRule exact = Rule("exact", PolicyScope::kSite, "cdn.example.test",
                                AccessMode::kDirect);
  ExpectMatch(
      EvaluateAccessPolicy(DocumentContext(), Snapshot({suffix, exact})),
      "exact", PolicyScope::kSite, AccessMode::kDirect);

  AccessPolicyRule exact_root = Rule("exact-root", PolicyScope::kProfile,
                                     "example.test", AccessMode::kReject);
  AccessPolicyRule narrower_suffix =
      Rule("narrower-suffix", PolicyScope::kProfile, "example.test",
           AccessMode::kDirect);
  narrower_suffix.include_subdomains = true;
  narrower_suffix.schemes = {RequestScheme::kHttps};
  narrower_suffix.ports = RulePortSelector{PortScope::kExplicitSubset, {443}};

  for (const std::vector<AccessPolicyRule>& rules :
       {std::vector<AccessPolicyRule>{exact_root, narrower_suffix},
        std::vector<AccessPolicyRule>{narrower_suffix, exact_root}}) {
    ExpectMatch(EvaluateAccessPolicy(
                    ProfileOnlyContext("https://example.test/resource"),
                    Snapshot(rules)),
                "exact-root", PolicyScope::kProfile, AccessMode::kReject);
  }

  AccessPolicyRule same_selector_suffix = narrower_suffix;
  same_selector_suffix.rule_id = "same-selector-suffix";
  same_selector_suffix.schemes = exact_root.schemes;
  same_selector_suffix.ports = exact_root.ports;
  for (const std::vector<AccessPolicyRule>& rules :
       {std::vector<AccessPolicyRule>{exact_root, same_selector_suffix},
        std::vector<AccessPolicyRule>{same_selector_suffix, exact_root}}) {
    ExpectMatch(EvaluateAccessPolicy(
                    ProfileOnlyContext("https://example.test/resource"),
                    Snapshot(rules)),
                "exact-root", PolicyScope::kProfile, AccessMode::kReject);
  }
}

TEST(AccessPolicyEvaluatorTest, LongestDnsLabelSuffixWins) {
  AccessPolicyRule broad =
      Rule("broad", PolicyScope::kSite, "example.test", AccessMode::kReject);
  broad.include_subdomains = true;
  AccessPolicyRule narrow = Rule("narrow", PolicyScope::kSite,
                                 "cdn.example.test", AccessMode::kProxy);
  narrow.include_subdomains = true;
  ExpectMatch(EvaluateAccessPolicy(
                  DocumentContext("https://asset.cdn.example.test/file"),
                  Snapshot({broad, narrow})),
              "narrow", PolicyScope::kSite, AccessMode::kProxy);
}

TEST(AccessPolicyEvaluatorTest, NarrowerSchemeAndPortSelectorWins) {
  AccessPolicyRule broad = Rule("broad", PolicyScope::kSite,
                                "cdn.example.test", AccessMode::kReject);
  AccessPolicyRule narrow = Rule("narrow", PolicyScope::kSite,
                                 "cdn.example.test", AccessMode::kProxy);
  narrow.schemes = {RequestScheme::kHttps};
  narrow.ports = RulePortSelector{PortScope::kExplicitSubset, {443}};
  ExpectMatch(EvaluateAccessPolicy(DocumentContext(),
                                   Snapshot({broad, narrow})),
              "narrow", PolicyScope::kSite, AccessMode::kProxy);
}

TEST(AccessPolicyEvaluatorTest, IncomparableSelectorsFailClosed) {
  AccessPolicyRule scheme_specific =
      Rule("scheme", PolicyScope::kSite, "cdn.example.test",
           AccessMode::kDirect);
  scheme_specific.schemes = {RequestScheme::kHttps};
  AccessPolicyRule port_specific =
      Rule("port", PolicyScope::kSite, "cdn.example.test",
           AccessMode::kProxy);
  port_specific.ports =
      RulePortSelector{PortScope::kExplicitSubset, {443}};
  const PolicyMatchResult result = EvaluateAccessPolicy(
      DocumentContext(), Snapshot({scheme_specific, port_specific}));
  EXPECT_EQ(result.policy_state, PolicyState::kConflict);
  EXPECT_EQ(result.reason, PolicyMatchReason::kPolicyConflict);
}

TEST(AccessPolicyEvaluatorTest, DuplicateNormalizedKeyFailsClosed) {
  AccessPolicyRule first = Rule("first", PolicyScope::kSite,
                                "cdn.example.test", AccessMode::kDirect);
  AccessPolicyRule second = first;
  second.rule_id = "second";
  second.mode = AccessMode::kReject;
  const PolicyMatchResult result =
      EvaluateAccessPolicy(DocumentContext(), Snapshot({first, second}));
  EXPECT_EQ(result.policy_state, PolicyState::kConflict);
  EXPECT_EQ(result.reason, PolicyMatchReason::kPolicyConflict);
}

TEST(AccessPolicyEvaluatorTest, DuplicateRuleIdentityFailsClosed) {
  AccessPolicyRule first = Rule("duplicate", PolicyScope::kSite,
                                "cdn.example.test", AccessMode::kDirect);
  AccessPolicyRule second = Rule("duplicate", PolicyScope::kProfile,
                                 "other.example.test", AccessMode::kReject);
  const PolicyMatchResult result =
      EvaluateAccessPolicy(DocumentContext(), Snapshot({first, second}));
  EXPECT_EQ(result.policy_state, PolicyState::kConflict);
  EXPECT_EQ(result.reason, PolicyMatchReason::kPolicyConflict);
}

TEST(AccessPolicyEvaluatorTest, UnreliableSiteOwnershipUsesProfileRuleOnly) {
  AccessPolicyRule site = Rule("site", PolicyScope::kSite,
                               "cdn.example.test", AccessMode::kProxy);
  AccessPolicyRule profile = Rule("profile", PolicyScope::kProfile,
                                  "cdn.example.test", AccessMode::kDirect);
  ExpectMatch(EvaluateAccessPolicy(ProfileOnlyContext(),
                                   Snapshot({site, profile})),
              "profile", PolicyScope::kProfile, AccessMode::kDirect);
}

TEST(AccessPolicyEvaluatorTest, NoRuleReturnsInheritance) {
  const PolicyMatchResult result = EvaluateAccessPolicy(
      DocumentContext(),
      Snapshot({Rule("other", PolicyScope::kSite, "other.example.test",
                     AccessMode::kReject)}));
  EXPECT_EQ(result.policy_state, PolicyState::kAbsent);
  EXPECT_EQ(result.effective_mode, AccessMode::kNone);
  EXPECT_EQ(result.policy_scope, PolicyScope::kNone);
  EXPECT_EQ(result.reason, PolicyMatchReason::kNoMatchingRule);
}

TEST(AccessPolicyEvaluatorTest, PrivatePslPreventsCrossTenantSuffix) {
  AccessPolicyRule invalid = Rule("invalid-private-suffix",
                                  PolicyScope::kProfile, "appspot.com",
                                  AccessMode::kReject);
  invalid.include_subdomains = true;
  const PolicyMatchResult invalid_result = EvaluateAccessPolicy(
      ProfileOnlyContext("https://asset.foo.appspot.com/file"),
      Snapshot({invalid}));
  EXPECT_EQ(invalid_result.policy_state, PolicyState::kInvalid);
  EXPECT_EQ(invalid_result.reason, PolicyMatchReason::kInvalidRule);

  AccessPolicyRule tenant = Rule("tenant", PolicyScope::kProfile,
                                 "foo.appspot.com", AccessMode::kProxy);
  tenant.include_subdomains = true;
  ExpectMatch(EvaluateAccessPolicy(
                  ProfileOnlyContext("https://asset.foo.appspot.com/file"),
                  Snapshot({tenant})),
              "tenant", PolicyScope::kProfile, AccessMode::kProxy);

  const PolicyMatchResult other_tenant = EvaluateAccessPolicy(
      ProfileOnlyContext("https://asset.bar.appspot.com/file"),
      Snapshot({tenant}));
  EXPECT_EQ(other_tenant.policy_state, PolicyState::kAbsent);
}

TEST(AccessPolicyEvaluatorTest, InvalidStoredNormalizationFailsClosed) {
  AccessPolicyRule host = Rule("host", PolicyScope::kSite,
                               "CDN.EXAMPLE.TEST", AccessMode::kDirect);
  EXPECT_EQ(EvaluateAccessPolicy(DocumentContext(), Snapshot({host})).reason,
            PolicyMatchReason::kInvalidRule);

  AccessPolicyRule schemes = Rule("schemes", PolicyScope::kSite,
                                  "cdn.example.test", AccessMode::kDirect);
  schemes.schemes = {RequestScheme::kHttps, RequestScheme::kHttp};
  EXPECT_EQ(
      EvaluateAccessPolicy(DocumentContext(), Snapshot({schemes})).reason,
      PolicyMatchReason::kInvalidRule);

  AccessPolicyRule ports = Rule("ports", PolicyScope::kSite,
                                "cdn.example.test", AccessMode::kDirect);
  ports.ports = RulePortSelector{PortScope::kExplicitSubset, {443, 443}};
  EXPECT_EQ(EvaluateAccessPolicy(DocumentContext(), Snapshot({ports})).reason,
            PolicyMatchReason::kInvalidRule);
}

TEST(AccessPolicyEvaluatorTest, OwnershipMismatchFailsClosed) {
  PublishedAccessPolicySnapshot snapshot = Snapshot(
      {Rule("rule", PolicyScope::kSite, "cdn.example.test",
            AccessMode::kDirect)});
  snapshot.owner.profile_token = "profile-other";
  const PolicyMatchResult result =
      EvaluateAccessPolicy(DocumentContext(), snapshot);
  EXPECT_EQ(result.policy_state, PolicyState::kInvalid);
  EXPECT_EQ(result.reason, PolicyMatchReason::kOwnershipMismatch);
}

TEST(AccessPolicyEvaluatorTest, ProxyCarriesLimitedProtectionOverride) {
  AccessPolicyRule rule = Rule("allow", PolicyScope::kSite,
                               "cdn.example.test", AccessMode::kProxy);
  rule.protection_override = ProtectionOverride::kTracker;
  const PolicyMatchResult result =
      EvaluateAccessPolicy(DocumentContext(), Snapshot({rule}));
  ExpectMatch(result, "allow", PolicyScope::kSite, AccessMode::kProxy);
  EXPECT_EQ(result.protection_override, ProtectionOverride::kTracker);
}

}  // namespace
}  // namespace aegis_access
