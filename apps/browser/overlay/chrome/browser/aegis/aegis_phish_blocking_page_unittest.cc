// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/aegis_phish_blocking_page_unittest.cc

#include "chrome/browser/aegis/aegis_phish_blocking_page.h"

#include <memory>
#include <string>
#include <utility>

#include "base/values.h"
#include "chrome/browser/aegis/aegis_phish_controller_client.h"
#include "chrome/test/base/chrome_render_view_host_test_harness.h"
#include "chrome/test/base/scoped_browser_locale.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

class TestAegisPhishBlockingPage : public AegisPhishBlockingPage {
 public:
  using AegisPhishBlockingPage::AegisPhishBlockingPage;

  void PopulateForTesting(base::DictValue& load_time_data) {
    PopulateInterstitialStrings(load_time_data);
  }
};

class AegisPhishBlockingPageTest : public ChromeRenderViewHostTestHarness {
 protected:
  std::unique_ptr<TestAegisPhishBlockingPage> MakePage(
      PhishAssessment assessment) {
    const GURL url("https://phish.example.test/login");
    auto controller =
        std::make_unique<AegisPhishControllerClient>(web_contents(), url);
    return std::make_unique<TestAegisPhishBlockingPage>(
        web_contents(), url, std::move(assessment), std::move(controller));
  }
};

TEST_F(AegisPhishBlockingPageTest, ShowsEnglishReasonsOnFirstScreen) {
  ScopedBrowserLocale locale("en-US");
  PhishAssessment assessment;
  assessment.score = 80;
  assessment.should_block = true;
  assessment.reasons = {
      {"brand_spoof_host", 30, "pay<script>alert(1)</script>pal"},
      {"credential_form", 25, ""},
  };
  auto page = MakePage(std::move(assessment));
  base::DictValue load_time_data;

  page->PopulateForTesting(load_time_data);

  const std::string* primary = load_time_data.FindString("primaryParagraph");
  const std::string* heading = load_time_data.FindString("heading");
  ASSERT_TRUE(primary);
  ASSERT_TRUE(heading);
  EXPECT_EQ("Aegis detected phishing signals", *heading);
  EXPECT_NE(std::string::npos, primary->find("Risk score 80"));
  EXPECT_NE(std::string::npos, primary->find("Page is collecting credentials"));
  EXPECT_NE(std::string::npos, primary->find("&lt;script&gt;"));
  EXPECT_EQ(std::string::npos, primary->find("<script>"));
  EXPECT_LT(primary->find("Page is collecting credentials"),
            primary->find("Risk score 80"));
  EXPECT_EQ(std::string::npos, primary->find("(+"));
  const std::string* proceed = load_time_data.FindString("proceedButtonText");
  const std::string* explanation =
      load_time_data.FindString("explanationParagraph");
  ASSERT_TRUE(proceed);
  ASSERT_TRUE(explanation);
  EXPECT_EQ("Continue once", *proceed);
  EXPECT_TRUE(explanation->empty());
}

TEST_F(AegisPhishBlockingPageTest, ShowsChineseReasonsOnFirstScreen) {
  ScopedBrowserLocale locale("zh-CN");
  PhishAssessment assessment;
  assessment.score = 75;
  assessment.should_block = true;
  assessment.reasons = {
      {"insecure_http", 20, ""},
      {"password_on_risky_origin", 35, ""},
  };
  auto page = MakePage(std::move(assessment));
  base::DictValue load_time_data;

  page->PopulateForTesting(load_time_data);

  const std::string* primary = load_time_data.FindString("primaryParagraph");
  const std::string* heading = load_time_data.FindString("heading");
  ASSERT_TRUE(primary);
  ASSERT_TRUE(heading);
  EXPECT_EQ("Aegis 检测到疑似钓鱼线索", *heading);
  EXPECT_NE(std::string::npos, primary->find("没有使用 HTTPS"));
  EXPECT_NE(std::string::npos, primary->find("在可疑网站上出现了密码框"));
  EXPECT_NE(std::string::npos, primary->find("风险分 75"));
  EXPECT_LT(primary->find("没有使用 HTTPS"), primary->find("风险分 75"));
  const std::string* proceed = load_time_data.FindString("proceedButtonText");
  ASSERT_TRUE(proceed);
  EXPECT_EQ("仅继续一次", *proceed);
}

}  // namespace
}  // namespace aegis
