// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_SOURCE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_SOURCE_H_

#include <cstdint>

#include "base/supports_user_data.h"
#include "components/aegis_access/access_identity_generation_state.h"

class Profile;

namespace aegis::access {

// Profile-owned bridge from committed Access service identity transitions to the
// identity_generation component of GenerationTuple. This type does not perform
// authentication or guest bootstrap. Callers may commit only after those
// operations have succeeded and the identity change is authoritative.
class AccessIdentityGenerationSource : public base::SupportsUserData::Data {
 public:
  static AccessIdentityGenerationSource* Get(Profile* profile);
  static AccessIdentityGenerationSource* GetOrCreate(Profile* profile);

  AccessIdentityGenerationSource(const AccessIdentityGenerationSource&) =
      delete;
  AccessIdentityGenerationSource& operator=(
      const AccessIdentityGenerationSource&) = delete;
  ~AccessIdentityGenerationSource() override;

  uint64_t identity_generation() const { return state_.generation(); }
  bool exhausted() const { return state_.exhausted(); }
  const std::optional<aegis_access::AccessIdentityBinding>& binding() const {
    return state_.binding();
  }

  aegis_access::IdentityGenerationCommitResult CommitIdentity(
      aegis_access::AccessIdentityBinding binding);

 private:
  AccessIdentityGenerationSource();

  aegis_access::IdentityGenerationState state_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_SOURCE_H_
