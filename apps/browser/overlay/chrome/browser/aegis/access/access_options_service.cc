// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_options_service.h"
#include "base/task/thread_pool.h"
#include "base/functional/bind.h"
#include "chrome/browser/aegis/access/access_service_coordinator.h"
#include "chrome/browser/aegis/access/access_build_channel.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/profiles/profile.h"
#include "content/public/browser/browser_thread.h"
namespace aegis::access {
namespace { const char kOptionsServiceKey[] = "aegis-access-options-service"; }
AccessOptionsService* AccessOptionsService::GetOrCreate(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !aegis::IsAegisProfileSupported(profile) ||
      !CanUseAccessOptionsForCurrentBuild(aegis_access::AccessOptionsOperation::kRead))
    return nullptr;
  auto* service = static_cast<AccessOptionsService*>(profile->GetUserData(kOptionsServiceKey));
  if (!service) {
    auto owned = std::unique_ptr<AccessOptionsService>(new AccessOptionsService(profile));
    service = owned.get();
    profile->SetUserData(kOptionsServiceKey, std::move(owned));
  }
  return service;
}
AccessOptionsService::AccessOptionsService(Profile* profile)
    : profile_(profile), store_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE}),
          AccessBuildIdentityForCurrentBuild(), profile->GetPath(),
          "aegis-access-profile:" + profile->GetPath().AsUTF8Unsafe(),
          profile->IsOffTheRecord()) {}
AccessOptionsService::~AccessOptionsService() = default;
bool AccessOptionsService::Admitted(aegis_access::AccessOptionsOperation operation) const {
  return CanUseAccessOptionsForCurrentBuild(operation);
}
void AccessOptionsService::Read(
    base::OnceCallback<void(StoreResult<AccessOptionsSnapshot>)> callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!Admitted(aegis_access::AccessOptionsOperation::kRead)) {
    std::move(callback).Run({StoreStatus::kConflict, std::nullopt, "channel_not_admitted"});
    return;
  }
  auto* product = AccessServiceCoordinator::GetOrCreate(profile_);
  if (!product) {
    std::move(callback).Run({StoreStatus::kRecoveryRequired, std::nullopt, "product_store_missing"});
    return;
  }
  product->CheckOptionsStoreBinding(base::BindOnce(&AccessOptionsService::OnProductStoreChecked,
      weak_factory_.GetWeakPtr(), std::move(callback)));
}
void AccessOptionsService::OnProductStoreChecked(
    base::OnceCallback<void(StoreResult<AccessOptionsSnapshot>)> callback, StoreStatus status) {
  if (status != StoreStatus::kValid) {
    std::move(callback).Run({status, std::nullopt, "product_store_not_ready"});
    return;
  }
  store_.AsyncCall(&AccessOptionsStore::OpenAndRead).Then(std::move(callback));
}
}  // namespace aegis::access
