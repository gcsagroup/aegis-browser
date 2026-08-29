// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/aegis_agent_service_factory.h"

#include "base/feature_list.h"
#include "chrome/browser/actor/actor_keyed_service_factory.h"
#include "chrome/browser/aegis/agent/aegis_agent_service.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/features.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"

namespace aegis::agent {

// static
AegisAgentServiceFactory* AegisAgentServiceFactory::GetInstance() {
  static base::NoDestructor<AegisAgentServiceFactory> factory{
      base::PassKey<AegisAgentServiceFactory>()};
  return factory.get();
}

// static
AegisAgentService* AegisAgentServiceFactory::GetForProfile(Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AegisAgentService*>(
      GetInstance()->GetServiceForBrowserContext(profile, /*create=*/true));
}

// static
AegisAgentService* AegisAgentServiceFactory::GetForProfileIfExists(
    Profile* profile) {
  if (!profile) {
    return nullptr;
  }
  return static_cast<AegisAgentService*>(
      GetInstance()->GetServiceForBrowserContext(profile, /*create=*/false));
}

AegisAgentServiceFactory::AegisAgentServiceFactory(
    base::PassKey<AegisAgentServiceFactory>)
    : ProfileKeyedServiceFactory("AegisAgentService",
                                 ProfileSelections::BuildForRegularProfile()) {
  DependsOn(actor::ActorKeyedServiceFactory::GetInstance());
}

AegisAgentServiceFactory::~AegisAgentServiceFactory() = default;

std::unique_ptr<KeyedService>
AegisAgentServiceFactory::BuildServiceInstanceForBrowserContext(
    content::BrowserContext* context) const {
  Profile* profile = Profile::FromBrowserContext(context);
  if (!profile || !base::FeatureList::IsEnabled(aegis::features::kAegisAgent) ||
      !profile->GetPrefs()->GetBoolean(aegis::prefs::kAgentEnabled)) {
    return nullptr;
  }
  return std::make_unique<AegisAgentService>(profile);
}

}  // namespace aegis::agent
