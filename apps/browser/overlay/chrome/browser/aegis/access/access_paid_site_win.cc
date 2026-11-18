// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_paid_site_mac.h"

#include <windows.h>

#include <algorithm>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/utf_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "base/uuid.h"
#include "chrome/browser/aegis/access/access_account_win.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/aegis/aegis_profile_support.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/global_features.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "ui/base/base_window.h"
#include "ui/base/mojom/ui_base_types.mojom.h"
#include "components/constrained_window/constrained_window_views.h"
#include "ui/base/interaction/element_identifier.h"
#include "ui/base/models/dialog_model.h"
#include "ui/views/bubble/bubble_dialog_model_host.h"
#include "ui/views/widget/widget.h"


namespace aegis::access {
namespace {

const char kLeaseKey[] = "aegis-account-node";

DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kPrivateOrigin);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kPrivateAccount);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kPrivateToken);

using PrivateAuthorizationDone =
    base::OnceCallback<void(std::optional<PrivateAccountBinding>)>;

void AuthorizePrivate(Profile* profile, PrivateAuthorizationDone done) {
  auto* features = g_browser_process ? g_browser_process->GetFeatures() : nullptr;
  auto* browsers = features ? features->global_browser_collection() : nullptr;
  auto* browser = browsers ? browsers->GetLastActiveBrowser() : nullptr;
  if (!browser || browser->GetProfile() != profile || !browser->GetWindow() ||
      !browser->GetWindow()->IsActive()) {
    std::move(done).Run(std::nullopt);
    return;
  }
  ui::DialogModel::Builder builder;
  auto completion = std::make_shared<PrivateAuthorizationDone>(std::move(done));
  builder.SetTitle(u"Authorize private Access session")
      .AddTextfield(kPrivateOrigin, u"Account service origin", {})
      .AddTextfield(kPrivateAccount, u"Account ID", {})
      .AddPasswordField(kPrivateToken, u"Private account session",
                        u"Private account session", {})
      .AddOkButton(base::BindOnce(
          [](ui::DialogModel* model,
             std::shared_ptr<PrivateAuthorizationDone> completion) {
            if (!*completion) return;
            std::move(*completion).Run(PrivateAccountBinding{
                base::UTF16ToUTF8(model->GetTextfieldByUniqueId(kPrivateOrigin)->text()),
                base::UTF16ToUTF8(model->GetTextfieldByUniqueId(kPrivateAccount)->text()),
                base::UTF16ToUTF8(model->GetPasswordFieldByUniqueId(kPrivateToken)->text())});
          }, base::Unretained(builder.model()), completion),
          ui::DialogModel::Button::Params().SetLabel(u"Authorize"))
      .AddCancelButton(base::DoNothing())
      .SetDialogDestroyingCallback(base::BindOnce(
          [](std::shared_ptr<PrivateAuthorizationDone> completion) {
            if (*completion) std::move(*completion).Run(std::nullopt);
          }, completion));
  auto host = views::BubbleDialogModelHost::CreateModal(
      builder.Build(), ui::mojom::ModalType::kWindow);
  constrained_window::CreateBrowserModalDialogViews(
      std::move(host), browser->GetWindow()->GetNativeWindow())->Show();
}

int64_t NowMs() {
  return base::Time::Now().InMillisecondsSinceUnixEpoch();
}

int64_t RenewalTime(int64_t now, int64_t expires) {
  return expires - std::min<int64_t>(5000, (expires - now) / 2);
}

class SiteLease final : public base::SupportsUserData::Data {
 public:
  explicit SiteLease(Profile* profile) : profile_(profile) {}
  ~SiteLease() override { Reset(); }

  AccountNodeStatus Status(const std::string& site) const {
    if (!sites_.contains(site)) return AccountNodeStatus::kOff;
    if (grant_) {
      auto* transport = AccessNetworkContextTransport::Get(profile_);
      return transport && !transport->AccountDispatchBlocked(GURL("https://" + site + "/"))
          ? AccountNodeStatus::kAssigned : AccountNodeStatus::kAcquiring;
    }
    return in_flight_ ? AccountNodeStatus::kAcquiring : AccountNodeStatus::kUnavailable;
  }
  bool HasSites() const { return !sites_.empty(); }

  void Toggle(const std::string& site, base::OnceClosure on_assigned = {}) {
    if (sites_.erase(site)) {
      assigned_.erase(site);
      if (sites_.empty()) Reset();
      Publish();
      return;
    }
    if (grant_ && (NowMs() >= grant_->expires_ms || Changed())) Reset();
    sites_.insert(site);
    if (!Publish()) {
      sites_.erase(site);
      return;
    }
    if (on_assigned) assigned_.emplace(site, std::move(on_assigned));
    if (grant_ || in_flight_) return;
    in_flight_ = true;
    if (profile_->IsOffTheRecord()) {
      AuthorizePrivate(profile_, base::BindOnce(&SiteLease::PrivateAuthorized,
                                               weak_.GetWeakPtr(), site));
    } else {
      Issue(std::nullopt);
    }
  }

 private:
  bool Changed() const {
    return grant_ && grant_->binding_state && !grant_->binding_state.Run().empty();
  }

  void PrivateAuthorized(std::string site,
                         std::optional<PrivateAccountBinding> binding) {
    if (!binding) {
      sites_.erase(site);
      Reset();
      Publish();
      return;
    }
    Issue(std::move(binding));
  }

  void Issue(std::optional<PrivateAccountBinding> binding) {
    IssueWindowsAccessNode(profile_->IsOffTheRecord() ? base::FilePath()
                                                     : profile_->GetPath(),
        std::move(binding), base::Uuid::GenerateRandomV4().AsLowercaseString(),
        base::BindOnce([](base::WeakPtr<SiteLease> self,
                          std::optional<AccountNodeGrant> grant) {
          if (self) self->Accept(std::move(grant));
        }, weak_.GetWeakPtr()));
  }

  bool Publish() {
    auto* route = AccessNetworkContextTransport::Get(profile_);
    const std::vector<std::string> sites(sites_.begin(), sites_.end());
    return route && (grant_
        ? route->SetAccountNodeSites(sites, grant_->host, grant_->port, grant_->authorization)
        : route->SetAccountNodeSites(sites, {}, 0, {}));
  }

  void Accept(std::optional<AccountNodeGrant> grant) {
    in_flight_ = false;
    grant_ = std::move(grant);
    const auto now = NowMs();
    if (!grant_ || now >= grant_->expires_ms || Changed() || !Publish()) {
      Reset();
      Publish();
      return;
    }
    renew_at_ = RenewalTime(now, grant_->expires_ms);
    guard_.Start(FROM_HERE, base::Milliseconds(200),
                 base::BindRepeating(&SiteLease::Check, weak_.GetWeakPtr()));
  }

  void Check() {
    const auto now = NowMs();
    if (now >= grant_->expires_ms || Changed()) {
      Reset();
      Publish();
      return;
    }
    for (auto it = assigned_.begin(); it != assigned_.end();) {
      if (it->second.IsCancelled()) {
        it = assigned_.erase(it);
      } else if (Status(it->first) == AccountNodeStatus::kAssigned) {
        auto callback = assigned_.extract(it);
        std::move(callback.mapped()).Run();
        return;
      } else {
        ++it;
      }
    }
    if (!in_flight_ && now >= renew_at_) {
      in_flight_ = true;
      grant_->renew.Run(base::BindOnce(&SiteLease::Renewed, weak_.GetWeakPtr()));
    }
  }

  void Renewed(int64_t expiry) {
    in_flight_ = false;
    const auto now = NowMs();
    if (now >= grant_->expires_ms || now >= expiry || Changed()) {
      Reset();
      Publish();
      return;
    }
    renew_at_ = expiry > grant_->expires_ms ? RenewalTime(now, expiry) : expiry;
    grant_->expires_ms = expiry;
  }

  void Reset() {
    weak_.InvalidateWeakPtrs();
    guard_.Stop();
    assigned_.clear();
    grant_.reset();
    in_flight_ = false;
  }

  raw_ptr<Profile> profile_;
  std::set<std::string> sites_;
  std::map<std::string, base::OnceClosure> assigned_;
  std::optional<AccountNodeGrant> grant_;
  bool in_flight_ = false;
  int64_t renew_at_ = 0;
  base::RepeatingTimer guard_;
  base::WeakPtrFactory<SiteLease> weak_{this};
};

SiteLease* Lease(Profile* profile) {
  return static_cast<SiteLease*>(profile->GetUserData(kLeaseKey));
}

}  // namespace

bool UsesAccountNode(Profile* profile, bool local_node_available) {
  if (!aegis::IsAegisProfileSupported(profile)) return false;
  if (auto* lease = Lease(profile); lease && lease->HasSites()) return true;
  if (profile->IsOffTheRecord() && !local_node_available) return true;
  const auto path = profile->GetOriginalProfile()->GetPath().AppendASCII(
      "AegisAccessAccount.json");
  const DWORD attrs = ::GetFileAttributesW(path.value().c_str());
  if (attrs != INVALID_FILE_ATTRIBUTES) return true;
  const DWORD error = ::GetLastError();
  return error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND;
}

AccountNodeStatus AccountNodeForSite(Profile* profile, const std::string& site) {
  auto* lease = Lease(profile);
  return lease ? lease->Status(site) : AccountNodeStatus::kOff;
}

void DisableAccountNodeSite(Profile* profile, const std::string& site) {
  auto* lease = Lease(profile);
  if (lease && lease->Status(site) != AccountNodeStatus::kOff) lease->Toggle(site);
}

void ToggleAccountNodeSite(Profile* profile, const std::string& site,
                           base::OnceClosure on_assigned) {
  if (!aegis::IsAegisProfileSupported(profile) || site.empty()) return;
  auto* lease = Lease(profile);
  if (!lease) {
    auto created = std::make_unique<SiteLease>(profile);
    lease = created.get();
    profile->SetUserData(kLeaseKey, std::move(created));
  }
  lease->Toggle(site, std::move(on_assigned));
}

}  // namespace aegis::access
