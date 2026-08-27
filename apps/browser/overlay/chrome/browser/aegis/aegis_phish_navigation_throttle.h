// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_navigation_throttle.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_PHISH_NAVIGATION_THROTTLE_H_
#define CHROME_BROWSER_AEGIS_AEGIS_PHISH_NAVIGATION_THROTTLE_H_

#include "chrome/common/aegis/phish_score.h"
#include "content/public/browser/navigation_throttle.h"
#include "url/gurl.h"

namespace content {
class NavigationThrottleRegistry;
}  // namespace content

namespace aegis {

// Cancels main-frame navigations that match built-in phishing seed rules or
// URL heuristics, and shows an explainable security interstitial.
class AegisPhishNavigationThrottle : public content::NavigationThrottle {
 public:
  explicit AegisPhishNavigationThrottle(
      content::NavigationThrottleRegistry& registry);
  ~AegisPhishNavigationThrottle() override;

  AegisPhishNavigationThrottle(const AegisPhishNavigationThrottle&) = delete;
  AegisPhishNavigationThrottle& operator=(const AegisPhishNavigationThrottle&) =
      delete;

  // content::NavigationThrottle:
  ThrottleCheckResult WillStartRequest() override;
  ThrottleCheckResult WillRedirectRequest() override;
  const char* GetNameForLogging() override;

  static void MaybeCreateAndAdd(content::NavigationThrottleRegistry& registry);

 private:
  ThrottleCheckResult MaybeIntercept();
  ThrottleCheckResult ShowInterstitial(const GURL& request_url,
                                       const PhishAssessment& assessment);
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_PHISH_NAVIGATION_THROTTLE_H_
