// Copyright 2026 GCSA
#include "chrome/browser/aegis/aegis_service.h"

#include <utility>

#include "base/functional/bind.h"
#include "chrome/browser/aegis/access/access_account_win.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/global_features.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "ui/base/base_window.h"

namespace aegis {

void AegisService::InitializeAccessAccountRefresh() {
  if (!profile_->IsRegularProfile() || profile_->IsOffTheRecord()) return;
  AccessAccountApplicationStateChanged();
  // Views activation is per window. Sample the OS-backed activation to also
  // detect switching to another application when Chromium stays open.
  access_account_activity_timer_.Start(
      FROM_HERE, base::Milliseconds(250),
      base::BindRepeating(&AegisService::AccessAccountApplicationStateChanged,
                          weak_ptr_factory_.GetWeakPtr()));
}

void AegisService::AccessAccountApplicationStateChanged() {
  auto* features = g_browser_process ? g_browser_process->GetFeatures() : nullptr;
  auto* browsers = features ? features->global_browser_collection() : nullptr;
  auto* browser = browsers ? browsers->GetLastActiveBrowser() : nullptr;
  const bool active = browser && browser->GetWindow() &&
                      browser->GetWindow()->IsActive();
  const auto state = std::pair(active, browser && browser->GetProfile() == profile_);
  if (access_account_activity_ == state) return;
  access_account_activity_ = state;
  UpdateAccessAccountActivity(state.first, state.second);
}

void AegisService::RequestAccessAccountSnapshot() {
  access::QueryWindowsAccessAccount(profile_->GetPath(),
      base::BindOnce([](base::WeakPtr<AegisService> service,
                        access::AccountSnapshot snapshot) {
        if (service && service->IsInitializedForProfile(service->profile()))
          service->OnAccessAccountReady(std::move(snapshot));
      }, weak_ptr_factory_.GetWeakPtr()));
}

}  // namespace aegis
