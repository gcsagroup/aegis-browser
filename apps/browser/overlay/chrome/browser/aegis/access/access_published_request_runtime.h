// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PUBLISHED_REQUEST_RUNTIME_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PUBLISHED_REQUEST_RUNTIME_H_

#include <cstdint>
#include <map>
#include <string>

#include "base/supports_user_data.h"
#include "chrome/browser/aegis/access/access_rule_store.h"
#include "components/aegis_access/access_policy_evaluator.h"
#include "components/aegis_access/request_generation_tuple_builder.h"

class Profile;

namespace aegis::access {

enum class AccessPolicyPublicationStatus {
  kPublished,
  kUnchanged,
  kStaleGeneration,
  kConflictingGeneration,
  kInvalidSnapshot,
  kMissingTransport,
  kOwnershipMismatch,
};

struct AccessPolicyPublicationResult {
  AccessPolicyPublicationStatus status =
      AccessPolicyPublicationStatus::kInvalidSnapshot;
  uint64_t policy_generation = 0;
};

// Profile-owned publication boundary between durable AccessRuleStore state and
// request-time routing. Database reads are promoted here into immutable
// in-memory policy snapshots; request dispatch never reads SQLite.
//
// Generation tuples are assembled only for a concrete committed PROXY group.
// DIRECT/absent policy paths must preserve Chromium's native routing and do not
// receive a fabricated selection generation.
class AccessPublishedRequestRuntime : public base::SupportsUserData::Data {
 public:
  static AccessPublishedRequestRuntime* Get(Profile* profile);
  static AccessPublishedRequestRuntime* GetOrCreate(Profile* profile);

  AccessPublishedRequestRuntime(const AccessPublishedRequestRuntime&) = delete;
  AccessPublishedRequestRuntime& operator=(
      const AccessPublishedRequestRuntime&) = delete;
  ~AccessPublishedRequestRuntime() override;

  AccessPolicyPublicationResult PublishCommittedPolicySnapshot(
      const StoredPolicySnapshot& stored);

  const aegis_access::PublishedAccessPolicySnapshot*
  GetPublishedPolicySnapshot(const aegis_access::OwnershipKey& owner) const;

  bool InvalidatePublishedPolicySnapshot(
      const aegis_access::OwnershipKey& owner);

  aegis_access::RequestGenerationTupleBuildResult BuildProxyGenerationTuple(
      const aegis_access::OwnershipKey& owner,
      const std::string& proxy_group_id) const;

 private:
  explicit AccessPublishedRequestRuntime(Profile* profile);

  Profile* const profile_;
  std::map<std::string, aegis_access::PublishedAccessPolicySnapshot>
      policy_snapshots_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PUBLISHED_REQUEST_RUNTIME_H_
