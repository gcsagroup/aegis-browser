// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_blocking_page.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_PHISH_BLOCKING_PAGE_H_
#define CHROME_BROWSER_AEGIS_AEGIS_PHISH_BLOCKING_PAGE_H_

#include <memory>
#include <string>

#include "chrome/common/aegis/phish_score.h"
#include "components/security_interstitials/content/security_interstitial_page.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}  // namespace content

namespace aegis {

class AegisPhishControllerClient;

// Full-page warning when navigation matches a phishing seed rule or URL
// heuristic score. Reason codes are shown on the page (explain, don't just
// warn).
class AegisPhishBlockingPage
    : public security_interstitials::SecurityInterstitialPage {
 public:
  static const security_interstitials::SecurityInterstitialPage::TypeID
      kTypeForTesting;

  AegisPhishBlockingPage(
      content::WebContents* web_contents,
      const GURL& request_url,
      PhishAssessment assessment,
      std::unique_ptr<AegisPhishControllerClient> controller_client);

  AegisPhishBlockingPage(const AegisPhishBlockingPage&) = delete;
  AegisPhishBlockingPage& operator=(const AegisPhishBlockingPage&) = delete;

  ~AegisPhishBlockingPage() override;

  security_interstitials::SecurityInterstitialPage::TypeID GetTypeForTesting()
      override;

 protected:
  void CommandReceived(const std::string& command) override;
  void PopulateInterstitialStrings(base::DictValue& load_time_data) override;
  void OnInterstitialClosing() override {}
  bool ShouldDisplayURL() const override;

 private:
  void PopulateValuesForSharedHTML(base::DictValue& load_time_data);

  const PhishAssessment assessment_;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_PHISH_BLOCKING_PAGE_H_
