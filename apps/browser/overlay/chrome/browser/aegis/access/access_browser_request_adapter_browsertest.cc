// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_browser_request_adapter.h"

#include <optional>

#include "base/functional/bind.h"
#include "chrome/browser/aegis/access/access_network_context_transport.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/test/base/in_process_browser_test.h"
#include "chrome/test/base/ui_test_utils.h"
#include "content/public/browser/page.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/prerender_test_util.h"
#include "net/base/schemeful_site.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

class AccessBrowserRequestAdapterBrowserTest : public InProcessBrowserTest {
 public:
  AccessBrowserRequestAdapterBrowserTest()
      : prerender_helper_(base::BindRepeating(
            &AccessBrowserRequestAdapterBrowserTest::web_contents,
            base::Unretained(this))) {}
  ~AccessBrowserRequestAdapterBrowserTest() override = default;

  void SetUpOnMainThread() override {
    InProcessBrowserTest::SetUpOnMainThread();
    ASSERT_TRUE(embedded_test_server()->Start());
    ASSERT_NE(AccessNetworkContextTransport::GetOrCreate(browser()->profile()),
              nullptr);
  }

 protected:
  content::WebContents* web_contents() {
    return browser()->tab_strip_model()->GetActiveWebContents();
  }

  base::RepeatingCallback<content::WebContents*()> WebContentsGetter() {
    return base::BindRepeating(
        &AccessBrowserRequestAdapterBrowserTest::web_contents,
        base::Unretained(this));
  }

  content::test::PrerenderTestHelper prerender_helper_;
};

IN_PROC_BROWSER_TEST_F(AccessBrowserRequestAdapterBrowserTest,
                       PrimaryPageUsesItsOwnBrowserIdentity) {
  const GURL primary_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), primary_url));

  content::RenderFrameHost* primary_frame = web_contents()->GetPrimaryMainFrame();
  ASSERT_NE(primary_frame, nullptr);
  ASSERT_TRUE(primary_frame->GetPage().IsPrimary());

  AccessBrowserRequestMetadataResult result = BuildBrowserOwnedRequestMetadata(
      browser()->profile(), WebContentsGetter(),
      primary_frame->GetFrameTreeNodeId(), std::nullopt);

  EXPECT_EQ(result.status, AccessBrowserRequestMetadataStatus::kOk);
  ASSERT_TRUE(result.metadata.has_value());
  EXPECT_EQ(result.metadata->attribution_kind,
            aegis_access::RequestAttributionKind::kDocument);
}

IN_PROC_BROWSER_TEST_F(AccessBrowserRequestAdapterBrowserTest,
                       PendingNavigationUsesDestinationSiteNotOldDocument) {
  const GURL primary_url = embedded_test_server()->GetURL("/title1.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), primary_url));

  content::RenderFrameHost* primary_frame =
      web_contents()->GetPrimaryMainFrame();
  ASSERT_NE(primary_frame, nullptr);
  constexpr int64_t kNavigationId = 42;
  AccessBrowserRequestMetadataResult metadata =
      BuildBrowserOwnedRequestMetadata(
          browser()->profile(), WebContentsGetter(),
          primary_frame->GetFrameTreeNodeId(), kNavigationId);

  ASSERT_EQ(metadata.status, AccessBrowserRequestMetadataStatus::kOk);
  ASSERT_TRUE(metadata.metadata.has_value());
  EXPECT_EQ(metadata.metadata->attribution_kind,
            aegis_access::RequestAttributionKind::kPendingNavigation);
  EXPECT_TRUE(metadata.metadata->document_token.empty());
  EXPECT_FALSE(metadata.metadata->pending_navigation_token.empty());
  EXPECT_FALSE(metadata.metadata->top_frame_site.has_value());

  const GURL destination("https://destination.example/path");
  aegis_access::RequestPolicyContextResult context =
      aegis_access::CanonicalizeBrowserOwnedRequest(*metadata.metadata,
                                                    destination);
  ASSERT_TRUE(context.context.has_value());
  EXPECT_TRUE(context.context->site_ownership_reliable());
  EXPECT_EQ(context.context->top_level_site(),
            net::SchemefulSite(destination).Serialize());
  EXPECT_NE(context.context->top_level_site(),
            net::SchemefulSite(primary_url).Serialize());
}

IN_PROC_BROWSER_TEST_F(AccessBrowserRequestAdapterBrowserTest,
                       PrerenderPageCannotInheritPrimaryPageIdentity) {
  const GURL primary_url = embedded_test_server()->GetURL("/title1.html");
  const GURL prerender_url = embedded_test_server()->GetURL("/title2.html");
  ASSERT_TRUE(ui_test_utils::NavigateToURL(browser(), primary_url));

  const content::PrerenderHostId host_id =
      prerender_helper_.AddPrerender(prerender_url);
  content::RenderFrameHost* prerender_frame =
      prerender_helper_.GetPrerenderedMainFrameHost(host_id);
  ASSERT_NE(prerender_frame, nullptr);
  ASSERT_FALSE(prerender_frame->GetPage().IsPrimary());

  AccessBrowserRequestMetadataResult result = BuildBrowserOwnedRequestMetadata(
      browser()->profile(), WebContentsGetter(),
      prerender_frame->GetFrameTreeNodeId(), std::nullopt);

  EXPECT_EQ(result.status,
            AccessBrowserRequestMetadataStatus::kInvalidAttribution);
  EXPECT_FALSE(result.metadata.has_value());
}

}  // namespace
}  // namespace aegis::access
