// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AEGIS_AGENT_SERVICE_FACTORY_H_
#define CHROME_BROWSER_AEGIS_AGENT_AEGIS_AGENT_SERVICE_FACTORY_H_

#include "base/no_destructor.h"
#include "base/types/pass_key.h"
#include "chrome/browser/profiles/profile_keyed_service_factory.h"

class Profile;

namespace aegis::agent {

class AegisAgentService;

class AegisAgentServiceFactory : public ProfileKeyedServiceFactory {
 public:
  explicit AegisAgentServiceFactory(base::PassKey<AegisAgentServiceFactory>);
  AegisAgentServiceFactory(const AegisAgentServiceFactory&) = delete;
  AegisAgentServiceFactory& operator=(const AegisAgentServiceFactory&) = delete;

  static AegisAgentServiceFactory* GetInstance();
  static AegisAgentService* GetForProfile(Profile* profile);
  static AegisAgentService* GetForProfileIfExists(Profile* profile);

 private:
  ~AegisAgentServiceFactory() override;

  std::unique_ptr<KeyedService> BuildServiceInstanceForBrowserContext(
      content::BrowserContext* context) const override;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AEGIS_AGENT_SERVICE_FACTORY_H_
