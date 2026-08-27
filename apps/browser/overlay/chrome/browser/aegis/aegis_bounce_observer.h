// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_bounce_observer.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_BOUNCE_OBSERVER_H_
#define CHROME_BROWSER_AEGIS_AEGIS_BOUNCE_OBSERVER_H_

#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/supports_user_data.h"
#include "base/types/pass_key.h"
#include "content/public/browser/btm_redirect.h"
#include "content/public/browser/btm_service.h"

class Profile;

namespace aegis {

// Observes Chromium BTM redirect chains and immediately deletes cookies for
// bounce hops that match Aegis tracker rules, instead of waiting for BTM's
// default grace period. Lifetime is tied to BtmService via UserData.
class BounceObserver : public content::BtmService::Observer,
                       public base::SupportsUserData::Data {
 public:
  using PassKey = base::PassKey<BounceObserver>;

  BounceObserver(PassKey, content::BtmService* btm_service, Profile* profile);
  BounceObserver(const BounceObserver&) = delete;
  BounceObserver& operator=(const BounceObserver&) = delete;
  ~BounceObserver() override;

  static void CreateFor(content::BtmService* btm_service, Profile* profile);

  // content::BtmService::Observer:
  void OnChainHandled(const std::vector<content::BtmRedirectPtr>& redirects,
                      const content::BtmRedirectChainPtr& chain) override;

 private:
  void DeleteSiteCookies(const std::string& site);

  raw_ptr<content::BtmService> btm_service_;
  raw_ptr<Profile> profile_;
  static const int kUserDataKey = 0;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_BOUNCE_OBSERVER_H_
