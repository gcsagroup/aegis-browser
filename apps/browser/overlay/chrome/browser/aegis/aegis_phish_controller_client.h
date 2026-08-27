// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_controller_client.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_PHISH_CONTROLLER_CLIENT_H_
#define CHROME_BROWSER_AEGIS_AEGIS_PHISH_CONTROLLER_CLIENT_H_

#include <memory>

#include "components/security_interstitials/content/security_interstitial_controller_client.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}  // namespace content

namespace aegis {

class AegisPhishControllerClient
    : public security_interstitials::SecurityInterstitialControllerClient {
 public:
  static std::unique_ptr<security_interstitials::MetricsHelper>
  GetMetricsHelper(const GURL& url);

  AegisPhishControllerClient(content::WebContents* web_contents,
                             const GURL& request_url);
  ~AegisPhishControllerClient() override;

  AegisPhishControllerClient(const AegisPhishControllerClient&) = delete;
  AegisPhishControllerClient& operator=(const AegisPhishControllerClient&) =
      delete;

  void GoBack() override;
  void Proceed() override;

 private:
  const GURL request_url_;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_PHISH_CONTROLLER_CLIENT_H_
