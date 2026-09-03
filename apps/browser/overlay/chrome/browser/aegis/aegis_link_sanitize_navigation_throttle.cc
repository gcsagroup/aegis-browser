// Copyright 2026 GCSA
// Intended path:
// chrome/browser/aegis/aegis_link_sanitize_navigation_throttle.cc

#include "chrome/browser/aegis/aegis_link_sanitize_navigation_throttle.h"

#include <memory>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/aegis_service_factory.h"
#include "chrome/browser/preloading/prefetch/no_state_prefetch/chrome_no_state_prefetch_contents_delegate.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/tracking_query_params.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"

namespace aegis {

AegisLinkSanitizeNavigationThrottle::AegisLinkSanitizeNavigationThrottle(
    content::NavigationThrottleRegistry& registry)
    : content::NavigationThrottle(registry) {}

AegisLinkSanitizeNavigationThrottle::~AegisLinkSanitizeNavigationThrottle() =
    default;

content::NavigationThrottle::ThrottleCheckResult
AegisLinkSanitizeNavigationThrottle::WillStartRequest() {
  return MaybeRewrite();
}

content::NavigationThrottle::ThrottleCheckResult
AegisLinkSanitizeNavigationThrottle::WillRedirectRequest() {
  return MaybeRewrite();
}

const char* AegisLinkSanitizeNavigationThrottle::GetNameForLogging() {
  return "AegisLinkSanitizeNavigationThrottle";
}

content::NavigationThrottle::ThrottleCheckResult
AegisLinkSanitizeNavigationThrottle::MaybeRewrite() {
  content::NavigationHandle* handle = navigation_handle();
  if (!handle->IsInOutermostMainFrame()) {
    return content::NavigationThrottle::PROCEED;
  }

  const GURL& url = handle->GetURL();
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return content::NavigationThrottle::PROCEED;
  }
  content::WebContents* web_contents = handle->GetWebContents();
  Profile* profile =
      web_contents
          ? Profile::FromBrowserContext(web_contents->GetBrowserContext())
          : nullptr;
  AegisService* service = AegisServiceFactory::GetForProfile(profile);
  if (!service || service->IsSitePaused(std::string(url.host()))) {
    return content::NavigationThrottle::PROCEED;
  }

  std::vector<std::string> removed;

  const GURL cleaned = SanitizeTrackingDecorations(url, &removed);
  if (cleaned == url) {
    return content::NavigationThrottle::PROCEED;
  }
  service->RecordStrippedParams(std::string(url.host()), removed,
                                /*document_id=*/std::string(),
                                /*site_key=*/std::string(url.host()));

  content::OpenURLParams params =
      content::OpenURLParams::FromNavigationHandle(handle);
  params.url = cleaned;

  // Browser logs can outlive an Incognito session. Never emit the original
  // or rewritten URL (including host, query, or fragment).
  LOG(INFO) << "Aegis: sanitized " << removed.size()
            << " tracking parameter(s)";
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<content::WebContents> contents,
                        content::OpenURLParams params) {
                       if (!contents) {
                         return;
                       }
                       contents->OpenURL(std::move(params),
                                         /*navigation_handle_callback=*/{});
                     },
                     web_contents->GetWeakPtr(), std::move(params)));
  return content::NavigationThrottle::CANCEL_AND_IGNORE;
}

// static
void AegisLinkSanitizeNavigationThrottle::MaybeCreateAndAdd(
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
  Profile* profile =
      web_contents
          ? Profile::FromBrowserContext(web_contents->GetBrowserContext())
          : nullptr;
  AegisService* service = AegisServiceFactory::GetForProfile(profile);
  if (!service || !service->IsLinkSanitizeEnabled()) {
    return;
  }
  registry.AddThrottle(
      std::make_unique<AegisLinkSanitizeNavigationThrottle>(registry));
}

}  // namespace aegis
