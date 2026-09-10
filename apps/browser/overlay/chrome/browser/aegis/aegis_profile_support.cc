// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_profile_support.h"

#include "build/chromeos_buildflags.h"
#include "chrome/browser/profiles/profile.h"

#if BUILDFLAG(IS_CHROMEOS)
#include "chromeos/ash/components/browser_context_helper/browser_context_types.h"
#endif

namespace aegis {

bool IsAegisProfileSupported(const Profile* profile) {
  if (!profile || profile->IsGuestSession() || profile->IsSystemProfile()) {
    return false;
  }
#if BUILDFLAG(IS_CHROMEOS)
  if (!ash::IsUserBrowserContext(profile)) {
    return false;
  }
#endif
  return profile->IsRegularProfile() ||
         (profile->IsIncognitoProfile() && profile->IsPrimaryOTRProfile());
}

}  // namespace aegis
