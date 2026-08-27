// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_cookie_janitor.cc

#include "chrome/browser/aegis/aegis_cookie_janitor.h"

#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/logging.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/after_startup_task_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/cookie_classify.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"

namespace aegis {

CookieJanitor::CookieJanitor(Profile* profile) : profile_(profile) {}

CookieJanitor::~CookieJanitor() = default;

void CookieJanitor::Start() {
  BindListener();
  AfterStartupTaskUtils::PostTask(
      FROM_HERE, base::SequencedTaskRunner::GetCurrentDefault(),
      base::BindOnce(&CookieJanitor::SweepExisting,
                     weak_factory_.GetWeakPtr()));
}

void CookieJanitor::Stop() {
  receiver_.reset();
}

void CookieJanitor::BindListener() {
  network::mojom::CookieManager* manager = cookie_manager();
  if (!manager || receiver_.is_bound()) {
    return;
  }
  manager->AddGlobalChangeListener(receiver_.BindNewPipeAndPassRemote());
  receiver_.set_disconnect_handler(base::BindOnce(
      [](base::WeakPtr<CookieJanitor> self) {
        if (!self) {
          return;
        }
        self->receiver_.reset();
        self->BindListener();
      },
      weak_factory_.GetWeakPtr()));
}

void CookieJanitor::SweepExisting() {
  network::mojom::CookieManager* manager = cookie_manager();
  if (!manager) {
    return;
  }
  manager->GetAllCookies(base::BindOnce(&CookieJanitor::OnGotAllCookies,
                                        weak_factory_.GetWeakPtr()));
}

void CookieJanitor::OnGotAllCookies(
    const std::vector<net::CanonicalCookie>& cookies) {
  for (const net::CanonicalCookie& cookie : cookies) {
    MaybeDelete(cookie);
  }
}

void CookieJanitor::OnCookieChange(const net::CookieChangeInfo& change) {
  if (change.cause != net::CookieChangeCause::INSERTED) {
    return;
  }
  MaybeDelete(change.cookie);
}

void CookieJanitor::MaybeDelete(const net::CanonicalCookie& cookie) {
  if (!AegisService::GetInstance()->IsCookieJanitorEnabled()) {
    return;
  }
  if (AegisService::GetInstance()->IsSitePaused(cookie.Domain())) {
    return;
  }
  const bool session = !cookie.IsPersistent();
  std::optional<base::Time> expiry;
  if (cookie.IsPersistent()) {
    expiry = cookie.ExpiryDate();
  }
  const CookieCategory category =
      ClassifyCookie(cookie.Name(), cookie.Domain(), session, expiry);
  if (!ShouldRejectCookie(category)) {
    return;
  }
  network::mojom::CookieManager* manager = cookie_manager();
  if (!manager) {
    return;
  }
  VLOG(1) << "Aegis: deleting " << cookie.Name() << " on " << cookie.Domain();
  AegisService::GetInstance()->RecordDeletedCookie(
      cookie.Name(), cookie.Domain(),
      FormatDeletedCookieDetail(cookie.Name(), cookie.Domain(), category));
  manager->DeleteCanonicalCookie(cookie, base::DoNothing());
}

network::mojom::CookieManager* CookieJanitor::cookie_manager() const {
  if (!profile_) {
    return nullptr;
  }
  return profile_->GetDefaultStoragePartition()
      ->GetCookieManagerForBrowserProcess();
}

}  // namespace aegis
