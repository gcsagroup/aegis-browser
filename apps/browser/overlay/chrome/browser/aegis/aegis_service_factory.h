// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AEGIS_SERVICE_FACTORY_H_
#define CHROME_BROWSER_AEGIS_AEGIS_SERVICE_FACTORY_H_

#include "base/no_destructor.h"
#include "base/types/pass_key.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile_keyed_service_factory.h"

class Profile;

namespace aegis {

class AegisService;

class AegisServiceFactory : public ProfileKeyedServiceFactory {
 public:
  explicit AegisServiceFactory(base::PassKey<AegisServiceFactory>);
  AegisServiceFactory(const AegisServiceFactory&) = delete;
  AegisServiceFactory& operator=(const AegisServiceFactory&) = delete;

  static AegisServiceFactory* GetInstance();
  // Installs the minimal regular-Profile observer that enforces process-wide
  // Incognito safety even when the user-facing Aegis feature is disabled.
  static void EnsureIncognitoGuardForProfile(Profile* profile);
  static AegisService* GetForProfile(Profile* profile);
  static AegisService* GetForProfileIfExists(Profile* profile);

 private:
  static AegisService* GetForProfileImpl(Profile* profile, bool create);

  ~AegisServiceFactory() override;

  bool ServiceIsCreatedWithBrowserContext() const override;
  std::unique_ptr<KeyedService> BuildServiceInstanceForBrowserContext(
      content::BrowserContext* context) const override;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_SERVICE_FACTORY_H_
