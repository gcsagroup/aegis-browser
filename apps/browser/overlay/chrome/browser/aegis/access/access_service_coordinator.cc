// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_service_coordinator.h"

#include <memory>

#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"

namespace aegis::access {

namespace {
const void* const kAccessServiceCoordinatorKey = &kAccessServiceCoordinatorKey;
}

AccessServiceCoordinator::AccessServiceCoordinator() = default;

AccessServiceCoordinator::~AccessServiceCoordinator() = default;

AccessServiceCoordinator* AccessServiceCoordinator::Get(Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AccessServiceCoordinator*>(
      profile->GetUserData(kAccessServiceCoordinatorKey));
}

AccessServiceCoordinator* AccessServiceCoordinator::GetOrCreate(
    Profile* profile) {
  if (!profile || !aegis::IsAegisProfileSupported(profile)) {
    return nullptr;
  }

  auto* existing = Get(profile);
  if (existing) {
    return existing;
  }

  auto coordinator = std::unique_ptr<AccessServiceCoordinator>(
      new AccessServiceCoordinator());
  auto* result = coordinator.get();
  profile->SetUserData(kAccessServiceCoordinatorKey, std::move(coordinator));
  return result;
}

}  // namespace aegis::access
