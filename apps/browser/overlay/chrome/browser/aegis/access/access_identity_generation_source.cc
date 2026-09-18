// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_identity_generation_source.h"

#include <memory>
#include <utility>

#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"

namespace aegis::access {
namespace {

const void* const kIdentityGenerationSourceUserDataKey =
    &kIdentityGenerationSourceUserDataKey;

}  // namespace

// static
AccessIdentityGenerationSource* AccessIdentityGenerationSource::Get(
    Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessIdentityGenerationSource*>(
      profile->GetUserData(kIdentityGenerationSourceUserDataKey));
}

// static
AccessIdentityGenerationSource* AccessIdentityGenerationSource::GetOrCreate(
    Profile* profile) {
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  if (auto* existing = Get(profile)) {
    return existing;
  }
  auto source = std::unique_ptr<AccessIdentityGenerationSource>(
      new AccessIdentityGenerationSource());
  auto* result = source.get();
  profile->SetUserData(kIdentityGenerationSourceUserDataKey, std::move(source));
  return result;
}

AccessIdentityGenerationSource::AccessIdentityGenerationSource() = default;

AccessIdentityGenerationSource::~AccessIdentityGenerationSource() = default;

aegis_access::IdentityGenerationCommitResult
AccessIdentityGenerationSource::CommitIdentity(
    aegis_access::AccessIdentityBinding binding) {
  return state_.Commit(std::move(binding));
}

}  // namespace aegis::access
