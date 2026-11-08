// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_INTENT_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_INTENT_H_

#include <map>
#include <optional>
#include <string>
#include <string_view>

#include "chrome/browser/aegis/access/access_rule_store.h"
#include "components/aegis_access/access_route_types.h"
#include "components/aegis_access/site_proxy_rule_group.h"

namespace aegis::access {

// Product-facing per-host Access intent. Distinct from publication/ACK and
// from connection health. Ordinary CommitSiteGroupMutation admits only the
// Direct/Proxy pair; block stays a local refuse-Access intent.
enum class AccessSiteIntent {
  kOff,
  kAllow,
  kBlock,
};

enum class AccessSiteIntentParseStatus {
  kOk,
  kUnknownIntent,
};

// Exact-host product key. Must match site proxy rule group canonical hosts:
// lowercase, no scheme/path/userinfo/port, no trailing dot.
struct AccessSiteHost {
  std::string value;

  friend bool operator==(const AccessSiteHost&,
                         const AccessSiteHost&) = default;
  friend bool operator<(const AccessSiteHost& left,
                        const AccessSiteHost& right) {
    return left.value < right.value;
  }
};

enum class AccessSiteHostStatus {
  kOk,
  kEmpty,
  kNotCanonical,
  kContainsSchemeOrPath,
};

struct AccessSiteHostResult {
  AccessSiteHostStatus status = AccessSiteHostStatus::kEmpty;
  std::optional<AccessSiteHost> host;
};

enum class AccessSiteIntentMutationStatus {
  // Ready for AccessServiceCoordinator::CommitSiteGroupMutation.
  kReady,
  kInvalidHost,
  kInvalidOwner,
  kMissingProxyGroup,
  // Block is product-local refuse; not an ordinary site-group mutation.
  // Callers must not treat this as silent DIRECT success.
  kBlockNotOrdinary,
  kInvalidArgument,
};

struct AccessSiteIntentMutationInput {
  AccessSiteIntent intent = AccessSiteIntent::kOff;
  AccessSiteHost host;
  OwnershipKey owner;
  std::string site_toggle_id;
  std::string operation_id;
  std::string request_fingerprint;
  // Required for kAllow; must be empty for kOff.
  std::string proxy_group_id;
  uint64_t expected_revision = 0;
};

struct AccessSiteIntentMutationResult {
  AccessSiteIntentMutationStatus status =
      AccessSiteIntentMutationStatus::kInvalidArgument;
  // Set only when status == kReady. Never invents DIRECT for allow/block.
  std::optional<SiteGroupMutationRequest> request;
  // Set for kReady: kProxy (allow) or kDirect (off).
  std::optional<aegis_access::AccessMode> ordinary_mode;
};

AccessSiteIntentParseStatus ParseAccessSiteIntent(std::string_view raw,
                                                  AccessSiteIntent* out);
std::string_view AccessSiteIntentToString(AccessSiteIntent intent);

// Accepts only an already-canonical exact host.
AccessSiteHostResult MakeAccessSiteHost(std::string_view exact_host);
// Strips scheme/userinfo/path/port and lowercases into an exact-host key.
AccessSiteHostResult NormalizeAccessSiteHost(std::string_view raw);

// Maps product intent onto ordinary site-group AccessMode boundaries.
// allow -> kProxy, off -> kDirect, block -> nullopt (not ordinary).
std::optional<aegis_access::AccessMode> OrdinaryAccessModeForIntent(
    AccessSiteIntent intent);

// Builds a SiteGroupMutationRequest for allow/off only. Fail-closed for block
// and invalid inputs: never returns a PROXY request for off/block, and never
// returns a DIRECT request for allow.
AccessSiteIntentMutationResult BuildOrdinarySiteGroupMutation(
    const AccessSiteIntentMutationInput& input);

// In-memory product intent store. Off entries are omitted. Does not publish,
// ACK, or call AccessServiceCoordinator.
class AccessSiteIntentStore {
 public:
  AccessSiteIntent Get(const AccessSiteHost& host) const;
  void Set(const AccessSiteHost& host, AccessSiteIntent intent);
  const std::map<AccessSiteHost, AccessSiteIntent>& All() const {
    return values_;
  }

 private:
  std::map<AccessSiteHost, AccessSiteIntent> values_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SITE_INTENT_H_
