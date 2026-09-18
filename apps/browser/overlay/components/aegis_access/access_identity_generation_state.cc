// Copyright 2026 GCSA

#include "components/aegis_access/access_identity_generation_state.h"

#include <limits>
#include <utility>

namespace aegis_access {
namespace {

bool HasServiceScope(const AccessIdentityBinding& binding) {
  return !binding.service_environment.empty() && !binding.service_realm.empty();
}

bool IsValidIdentityBinding(const AccessIdentityBinding& binding) {
  if (!HasServiceScope(binding)) {
    return false;
  }

  switch (binding.kind) {
    case AccessIdentityKind::kInstallationGuest:
    case AccessIdentityKind::kAuthenticated:
      return !binding.principal_id.empty() &&
             !binding.entitlement_account_id.empty();
    case AccessIdentityKind::kSignedOut:
      return binding.principal_id.empty() &&
             binding.entitlement_account_id.empty();
    case AccessIdentityKind::kInvalid:
      return false;
  }
  return false;
}

}  // namespace

IdentityGenerationCommitResult IdentityGenerationState::Commit(
    AccessIdentityBinding binding) {
  if (exhausted_) {
    return {IdentityGenerationCommitStatus::kExhausted, 0};
  }
  if (!IsValidIdentityBinding(binding)) {
    return {IdentityGenerationCommitStatus::kInvalidIdentity, generation_};
  }
  if (binding_.has_value() && *binding_ == binding) {
    return {IdentityGenerationCommitStatus::kUnchanged, generation_};
  }
  if (generation_ == std::numeric_limits<uint64_t>::max()) {
    exhausted_ = true;
    generation_ = 0;
    binding_.reset();
    return {IdentityGenerationCommitStatus::kExhausted, 0};
  }

  ++generation_;
  binding_ = std::move(binding);
  return {IdentityGenerationCommitStatus::kCommitted, generation_};
}

}  // namespace aegis_access
