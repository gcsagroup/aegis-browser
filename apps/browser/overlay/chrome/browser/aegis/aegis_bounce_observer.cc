// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_bounce_observer.cc

#include "chrome/browser/aegis/aegis_bounce_observer.h"

#include <memory>

#include "base/functional/callback_helpers.h"
#include "base/logging.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/filter_list_matcher.h"
#include "content/public/browser/storage_partition.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

namespace aegis {
namespace {

bool RedirectUsedStorage(content::BtmDataAccessType access) {
  switch (access) {
    case content::BtmDataAccessType::kRead:
    case content::BtmDataAccessType::kWrite:
    case content::BtmDataAccessType::kReadWrite:
      return true;
    case content::BtmDataAccessType::kUnknown:
    case content::BtmDataAccessType::kNone:
      return false;
  }
}

bool HadUserActivation(const content::BtmRedirect& redirect) {
  if (redirect.has_sticky_activation) {
    return true;
  }
  return redirect.site_had_user_activation.value_or(false);
}

}  // namespace

BounceObserver::BounceObserver(PassKey,
                               content::BtmService* btm_service,
                               Profile* profile)
    : btm_service_(btm_service), profile_(profile) {
  btm_service_->AddObserver(this);
}

BounceObserver::~BounceObserver() {
  btm_service_->RemoveObserver(this);
}

// static
void BounceObserver::CreateFor(content::BtmService* btm_service,
                               Profile* profile) {
  if (!btm_service || btm_service->GetUserData(&kUserDataKey)) {
    return;
  }
  btm_service->SetUserData(&kUserDataKey, std::make_unique<BounceObserver>(
                                              PassKey(), btm_service, profile));
}

void BounceObserver::OnChainHandled(
    const std::vector<content::BtmRedirectPtr>& redirects,
    const content::BtmRedirectChainPtr& chain) {
  if (!AegisService::GetInstance()->IsBounceTrackingEnabled()) {
    return;
  }
  if (!chain || chain->is_partial_chain) {
    return;
  }

  for (const content::BtmRedirectPtr& redirect : redirects) {
    if (!redirect) {
      continue;
    }
    if (HadUserActivation(*redirect) ||
        !RedirectUsedStorage(redirect->access_type)) {
      continue;
    }
    if (!FilterListMatcher::GetInstance()->ShouldBlock(
            redirect->redirector_url)) {
      continue;
    }
    LOG(INFO) << "Aegis: clearing cookies for bounce tracker "
              << redirect->site;
    AegisService::GetInstance()->RecordBounceClear(redirect->site);
    DeleteSiteCookies(redirect->site);
  }
}

void BounceObserver::DeleteSiteCookies(const std::string& site) {
  if (site.empty() || !profile_) {
    return;
  }
  network::mojom::CookieManager* manager =
      profile_->GetDefaultStoragePartition()
          ->GetCookieManagerForBrowserProcess();
  if (!manager) {
    return;
  }
  auto filter = network::mojom::CookieDeletionFilter::New();
  filter->including_domains = std::vector<std::string>{site};
  manager->DeleteCookies(std::move(filter), base::DoNothing());
}

const int BounceObserver::kUserDataKey;

}  // namespace aegis
