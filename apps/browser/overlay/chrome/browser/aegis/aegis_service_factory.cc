// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_service_factory.h"

#include "base/feature_list.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/features.h"
#include "content/public/browser/browser_context.h"

namespace aegis {

// static
AegisServiceFactory* AegisServiceFactory::GetInstance() {
  static base::NoDestructor<AegisServiceFactory> factory{
      base::PassKey<AegisServiceFactory>()};
  return factory.get();
}

// static
void AegisServiceFactory::EnsureIncognitoGuardForProfile(Profile* profile) {
  GetForProfileImpl(profile, /*create=*/true);
}

// static
AegisService* AegisServiceFactory::GetForProfile(Profile* profile) {
  if (!base::FeatureList::IsEnabled(features::kAegisEnabled)) {
    return nullptr;
  }
  return GetForProfileImpl(profile, /*create=*/true);
}

// static
AegisService* AegisServiceFactory::GetForProfileIfExists(Profile* profile) {
  if (!base::FeatureList::IsEnabled(features::kAegisEnabled)) {
    return nullptr;
  }
  return GetForProfileImpl(profile, /*create=*/false);
}

// static
AegisService* AegisServiceFactory::GetForProfileImpl(Profile* profile,
                                                     bool create) {
  if (!IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  return static_cast<AegisService*>(
      GetInstance()->GetServiceForBrowserContext(profile, create));
}

AegisServiceFactory::AegisServiceFactory(base::PassKey<AegisServiceFactory>)
    : ProfileKeyedServiceFactory(
          "AegisService",
          ProfileSelections::BuildForRegularAndIncognito()) {}

AegisServiceFactory::~AegisServiceFactory() = default;

bool AegisServiceFactory::ServiceIsCreatedWithBrowserContext() const {
  // PostProfileInit eagerly requests regular-Profile services so their OTR
  // observer exists before the first Browser or renderer. Primary Incognito
  // services are still requested by their renderer/WebUI entry points.
  return false;
}

std::unique_ptr<KeyedService>
AegisServiceFactory::BuildServiceInstanceForBrowserContext(
    content::BrowserContext* context) const {
  Profile* profile = Profile::FromBrowserContext(context);
  if (!IsAegisProfileSupported(profile)) {
    return nullptr;
  }
  return std::make_unique<AegisService>(profile);
}

}  // namespace aegis
