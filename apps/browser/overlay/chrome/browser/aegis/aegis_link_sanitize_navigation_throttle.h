// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_link_sanitize_navigation_throttle.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_LINK_SANITIZE_NAVIGATION_THROTTLE_H_
#define CHROME_BROWSER_AEGIS_AEGIS_LINK_SANITIZE_NAVIGATION_THROTTLE_H_

#include "content/public/browser/navigation_throttle.h"

namespace content {
class NavigationThrottleRegistry;
}  // namespace content

namespace aegis {

// Rewrites main-frame navigations to strip known tracking query decorations.
class AegisLinkSanitizeNavigationThrottle : public content::NavigationThrottle {
 public:
  explicit AegisLinkSanitizeNavigationThrottle(
      content::NavigationThrottleRegistry& registry);
  ~AegisLinkSanitizeNavigationThrottle() override;

  AegisLinkSanitizeNavigationThrottle(
      const AegisLinkSanitizeNavigationThrottle&) = delete;
  AegisLinkSanitizeNavigationThrottle& operator=(
      const AegisLinkSanitizeNavigationThrottle&) = delete;

  ThrottleCheckResult WillStartRequest() override;
  ThrottleCheckResult WillRedirectRequest() override;
  const char* GetNameForLogging() override;

  static void MaybeCreateAndAdd(content::NavigationThrottleRegistry& registry);

 private:
  ThrottleCheckResult MaybeRewrite();
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_LINK_SANITIZE_NAVIGATION_THROTTLE_H_
