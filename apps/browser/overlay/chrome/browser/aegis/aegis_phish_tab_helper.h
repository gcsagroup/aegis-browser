// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_tab_helper.h

#ifndef CHROME_BROWSER_AEGIS_AEGIS_PHISH_TAB_HELPER_H_
#define CHROME_BROWSER_AEGIS_AEGIS_PHISH_TAB_HELPER_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "chrome/common/aegis/phish_score.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "url/gurl.h"

namespace content {
class NavigationHandle;
class RenderFrameHost;
}  // namespace content

namespace aegis {

class PhishTabHelperTestPeer;

// After the main frame finishes loading, asks the renderer for password/form
// counts and page text, then reloads into the phishing interstitial if the
// combined score crosses the block threshold.
class PhishTabHelper : public content::WebContentsObserver,
                       public content::WebContentsUserData<PhishTabHelper> {
 public:
  PhishTabHelper(const PhishTabHelper&) = delete;
  PhishTabHelper& operator=(const PhishTabHelper&) = delete;
  ~PhishTabHelper() override;

  std::optional<PhishAssessment> TakeStashedAssessment(const GURL& url);
  void AllowNextNavigationOnce(const GURL& url);
  bool ConsumeOneTimeNavigationBypass(const GURL& url, int64_t navigation_id);
  void CancelOneTimeNavigationBypass(int64_t navigation_id);

  // content::WebContentsObserver:
  void DidFinishNavigation(
      content::NavigationHandle* navigation_handle) override;
  void DOMContentLoaded(content::RenderFrameHost* render_frame_host) override;

 private:
  friend class PhishTabHelperTestPeer;
  friend class content::WebContentsUserData<PhishTabHelper>;
  explicit PhishTabHelper(content::WebContents* web_contents);

  void InvalidatePageSignalCheck();
  void OnPageSignalCollectionFailed(content::WeakDocumentPtr source_document);
  void OnPageSignalsCollected(content::WeakDocumentPtr source_document,
                              int32_t password_fields,
                              int32_t forms,
                              const std::vector<std::string>& form_actions,
                              const std::string& title,
                              const std::string& text_sample);
  void OnPageSignals(content::WeakDocumentPtr source_document,
                     const GURL& url,
                     int32_t password_fields,
                     int32_t forms,
                     const std::vector<std::string>& form_actions,
                     const std::string& title,
                     const std::string& text_sample);

  std::optional<PhishAssessment> stashed_;
  GURL stashed_url_;
  GURL one_time_bypass_url_;
  GURL bypassed_navigation_url_;
  std::optional<int64_t> bypassed_navigation_id_;
  content::WeakDocumentPtr bypassed_document_;
  content::WeakDocumentPtr checking_document_;
  bool checking_ = false;
  base::WeakPtrFactory<PhishTabHelper> weak_factory_{this};

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_AEGIS_PHISH_TAB_HELPER_H_
