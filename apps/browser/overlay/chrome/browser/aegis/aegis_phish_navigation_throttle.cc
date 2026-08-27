// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_navigation_throttle.cc

#include "chrome/browser/aegis/aegis_phish_navigation_throttle.h"

#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/logging.h"
#include "chrome/browser/aegis/aegis_phish_blocking_page.h"
#include "chrome/browser/aegis/aegis_phish_controller_client.h"
#include "chrome/browser/aegis/aegis_phish_tab_helper.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/preloading/prefetch/no_state_prefetch/chrome_no_state_prefetch_contents_delegate.h"
#include "components/security_interstitials/content/security_interstitial_tab_helper.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/web_contents.h"
#include "net/base/net_errors.h"
#include "url/gurl.h"

namespace aegis {

AegisPhishNavigationThrottle::AegisPhishNavigationThrottle(
    content::NavigationThrottleRegistry& registry)
    : content::NavigationThrottle(registry) {}

AegisPhishNavigationThrottle::~AegisPhishNavigationThrottle() = default;

content::NavigationThrottle::ThrottleCheckResult
AegisPhishNavigationThrottle::WillStartRequest() {
  return MaybeIntercept();
}

content::NavigationThrottle::ThrottleCheckResult
AegisPhishNavigationThrottle::WillRedirectRequest() {
  return MaybeIntercept();
}

const char* AegisPhishNavigationThrottle::GetNameForLogging() {
  return "AegisPhishNavigationThrottle";
}

content::NavigationThrottle::ThrottleCheckResult
AegisPhishNavigationThrottle::MaybeIntercept() {
  content::NavigationHandle* handle = navigation_handle();
  if (!handle->IsInOutermostMainFrame()) {
    return content::NavigationThrottle::PROCEED;
  }

  const GURL& url = handle->GetURL();
  if (content::WebContents* web_contents = handle->GetWebContents()) {
    if (PhishTabHelper* helper = PhishTabHelper::FromWebContents(web_contents)) {
      if (std::optional<PhishAssessment> stashed =
              helper->TakeStashedAssessment(url)) {
        LOG(INFO) << "AegisPhishNavigationThrottle: blocking " << url
                  << " score=" << stashed->score << " (page-sense)";
        return ShowInterstitial(url, *stashed);
      }
    }
  }
  std::optional<PhishAssessment> assessment =
      AegisService::GetInstance()->EvaluatePhish(url);
  if (!assessment) {
    return content::NavigationThrottle::PROCEED;
  }

  LOG(INFO) << "AegisPhishNavigationThrottle: blocking " << url
            << " score=" << assessment->score;
  return ShowInterstitial(url, *assessment);
}

content::NavigationThrottle::ThrottleCheckResult
AegisPhishNavigationThrottle::ShowInterstitial(
    const GURL& request_url,
    const PhishAssessment& assessment) {
  content::NavigationHandle* handle = navigation_handle();
  content::WebContents* web_contents = handle->GetWebContents();

  std::string reason;
  if (!assessment.reasons.empty()) {
    reason = assessment.reasons.front().code;
    if (!assessment.reasons.front().detail.empty()) {
      reason += " (" + assessment.reasons.front().detail + ")";
    }
  }
  AegisService::GetInstance()->RecordPhishBlock(
      request_url.has_host() ? std::string(request_url.host()) : request_url.spec(),
      reason);

  auto controller =
      std::make_unique<AegisPhishControllerClient>(web_contents, request_url);
  auto blocking_page = std::make_unique<AegisPhishBlockingPage>(
      web_contents, request_url, assessment, std::move(controller));

  std::optional<std::string> error_page_contents =
      blocking_page->GetHTMLContents();

  security_interstitials::SecurityInterstitialTabHelper::AssociateBlockingPage(
      handle, std::move(blocking_page));

  return ThrottleCheckResult(content::NavigationThrottle::CANCEL,
                             net::ERR_BLOCKED_BY_CLIENT, error_page_contents);
}

// static
void AegisPhishNavigationThrottle::MaybeCreateAndAdd(
    content::NavigationThrottleRegistry& registry) {
  auto& navigation_handle = registry.GetNavigationHandle();
  content::WebContents* web_contents = navigation_handle.GetWebContents();

  if (prerender::ChromeNoStatePrefetchContentsDelegate::FromWebContents(
          web_contents)) {
    return;
  }

  if (!navigation_handle.IsInOutermostMainFrame()) {
    return;
  }

  if (!AegisService::GetInstance()->IsPhishInterstitialEnabled()) {
    return;
  }

  registry.AddThrottle(
      std::make_unique<AegisPhishNavigationThrottle>(registry));
}

}  // namespace aegis
