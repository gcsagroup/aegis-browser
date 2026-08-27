// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_cookie_janitor.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_COOKIE_JANITOR_H_
#define CHROME_BROWSER_AEGIS_AEGIS_COOKIE_JANITOR_H_

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "net/cookies/cookie_change_dispatcher.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

class Profile;

namespace aegis {

// Deletes analytics/advertising cookies as they are written, and sweeps the
// existing jar once when started.
class CookieJanitor : public network::mojom::CookieChangeListener {
 public:
  explicit CookieJanitor(Profile* profile);
  CookieJanitor(const CookieJanitor&) = delete;
  CookieJanitor& operator=(const CookieJanitor&) = delete;
  ~CookieJanitor() override;

  void Start();
  void Stop();

  // network::mojom::CookieChangeListener:
  void OnCookieChange(const net::CookieChangeInfo& change) override;

 private:
  void BindListener();
  void SweepExisting();
  void OnGotAllCookies(const std::vector<net::CanonicalCookie>& cookies);
  void MaybeDelete(const net::CanonicalCookie& cookie);
  network::mojom::CookieManager* cookie_manager() const;

  raw_ptr<Profile> profile_;
  mojo::Receiver<network::mojom::CookieChangeListener> receiver_{this};
  base::WeakPtrFactory<CookieJanitor> weak_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_COOKIE_JANITOR_H_
