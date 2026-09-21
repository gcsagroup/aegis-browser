// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_STATE_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_STATE_H_

#include <cstdint>
#include <optional>
#include <string>

namespace aegis_access {

enum class AccessIdentityKind {
  kInstallationGuest,
  kAuthenticated,
  kSignedOut,
  kInvalid,
};

struct AccessIdentityBinding {
  AccessIdentityKind kind = AccessIdentityKind::kInvalid;
  std::string principal_id;
  std::string entitlement_account_id;
  std::string service_environment;
  std::string service_realm;

  friend bool operator==(const AccessIdentityBinding&,
                         const AccessIdentityBinding&) = default;
};

enum class IdentityGenerationCommitStatus {
  kCommitted,
  kUnchanged,
  kInvalidIdentity,
  kExhausted,
};

struct IdentityGenerationCommitResult {
  IdentityGenerationCommitStatus status =
      IdentityGenerationCommitStatus::kInvalidIdentity;
  uint64_t generation = 0;
};

// Browser-owned monotonic generation for one committed Access service identity.
// Zero is reserved for "identity not published". Candidate authentication or
// bootstrap work must remain outside this state until the caller has committed
// the identity transition.
class IdentityGenerationState {
 public:
  IdentityGenerationState();
  ~IdentityGenerationState();

  IdentityGenerationState(const IdentityGenerationState&) = delete;
  IdentityGenerationState& operator=(const IdentityGenerationState&) = delete;

  uint64_t generation() const { return generation_; }
  bool exhausted() const { return exhausted_; }
  const std::optional<AccessIdentityBinding>& binding() const {
    return binding_;
  }

  IdentityGenerationCommitResult Commit(AccessIdentityBinding binding);

 private:
  friend class IdentityGenerationStateTestPeer;

  bool exhausted_ = false;
  uint64_t generation_ = 0;
  std::optional<AccessIdentityBinding> binding_;
};

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_IDENTITY_GENERATION_STATE_H_
