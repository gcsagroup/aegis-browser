// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_controller_client.cc

#include "chrome/browser/aegis/aegis_phish_controller_client.h"

#include <string>
#include <utility>

#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/webui_url_constants.h"
#include "components/security_interstitials/content/settings_page_helper.h"
#include "components/security_interstitials/core/metrics_helper.h"
#include "content/public/browser/web_contents.h"

namespace aegis {

// static
std::unique_ptr<security_interstitials::MetricsHelper>
AegisPhishControllerClient::GetMetricsHelper(const GURL& url) {
  security_interstitials::MetricsHelper::ReportDetails settings;
  settings.metric_prefix = "aegis_phish";
  return std::make_unique<security_interstitials::MetricsHelper>(url, settings,
                                                                 nullptr);
}

AegisPhishControllerClient::AegisPhishControllerClient(
    content::WebContents* web_contents,
    const GURL& request_url)
    : SecurityInterstitialControllerClient(
          web_contents,
          GetMetricsHelper(request_url),
          Profile::FromBrowserContext(web_contents->GetBrowserContext())
              ->GetPrefs(),
          g_browser_process->GetApplicationLocale(),
          chrome::ChromeUINewTabURLAsGURL(),
          /*settings_page_helper=*/nullptr),
      request_url_(request_url) {}

AegisPhishControllerClient::~AegisPhishControllerClient() = default;

void AegisPhishControllerClient::GoBack() {
  SecurityInterstitialControllerClient::GoBackAfterNavigationCommitted();
}

void AegisPhishControllerClient::Proceed() {
  AegisService::GetInstance()->AllowPhishHostForSession(
      std::string(request_url_.host()));
  Reload();
}

}  // namespace aegis
