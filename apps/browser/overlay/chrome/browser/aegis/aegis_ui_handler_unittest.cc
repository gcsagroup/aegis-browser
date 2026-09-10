// Copyright 2026 GCSA

#include "chrome/browser/ui/webui/aegis/aegis_ui_handler.h"

#include <string>
#include <utility>
#include <vector>

#include "base/values.h"
#include "build/build_config.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/webui/aegis/aegis_ui.h"
#include "chrome/test/base/browser_with_test_window_test.h"
#include "chrome/test/base/testing_profile_manager.h"
#include "content/public/browser/web_contents.h"
#include "content/public/test/test_web_ui.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

class AegisUIHandlerTest : public BrowserWithTestWindowTest {};

class TestAegisUIHandler : public AegisUIHandler {
 public:
  using content::WebUIMessageHandler::set_web_ui;
};

TEST_F(AegisUIHandlerTest, SelectsNearestHttpTabInSameWindow) {
  AddTab(browser(), GURL("https://left.example/"));
  AddTab(browser(), GURL("chrome://aegis/"));
  AddTab(browser(), GURL("https://right.example/"));
  TabStripModel* model = browser()->tab_strip_model();
  content::WebContents* settings = model->GetWebContentsAt(1);

  EXPECT_EQ(model->GetWebContentsAt(0),
            FindSummarySourceTabInModel(model, settings));

  NavigateAndCommit(model->GetWebContentsAt(0), GURL("about:blank"));
  EXPECT_EQ(model->GetWebContentsAt(2),
            FindSummarySourceTabInModel(model, settings));

  NavigateAndCommit(model->GetWebContentsAt(2), GURL("about:blank"));
  EXPECT_EQ(nullptr, FindSummarySourceTabInModel(model, settings));
}

TEST_F(AegisUIHandlerTest, RejectsTabFromAnotherWindowModel) {
  AddTab(browser(), GURL("https://source.example/"));
  TabStripModel* model = browser()->tab_strip_model();
  auto foreign = content::WebContents::Create(
      content::WebContents::CreateParams(profile()));

  EXPECT_EQ(nullptr, FindSummarySourceTabInModel(model, foreign.get()));
}

TEST_F(AegisUIHandlerTest, WebUIConfigAllowsOnlySupportedProfiles) {
  AegisUIConfig config;
  EXPECT_TRUE(config.IsWebUIEnabled(profile()));

  Profile* primary_otr =
      profile()->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  ASSERT_TRUE(primary_otr);
#if BUILDFLAG(IS_ANDROID)
  EXPECT_FALSE(config.IsWebUIEnabled(primary_otr));
#else
  EXPECT_TRUE(config.IsWebUIEnabled(primary_otr));
#endif

  Profile* auxiliary_otr = profile()->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  ASSERT_TRUE(auxiliary_otr);
  EXPECT_FALSE(config.IsWebUIEnabled(auxiliary_otr));

  TestingProfile* guest = profile_manager()->CreateGuestProfile();
  ASSERT_TRUE(guest);
  EXPECT_FALSE(config.IsWebUIEnabled(guest));

#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  TestingProfile* system = profile_manager()->CreateSystemProfile();
  ASSERT_TRUE(system);
  EXPECT_FALSE(config.IsWebUIEnabled(system));
#endif
}

TEST_F(AegisUIHandlerTest, AdvancedDownloadsRejectUnsupportedProfiles) {
  Profile* auxiliary_otr = profile()->GetOffTheRecordProfile(
      Profile::OTRProfileID::CreateUniqueForTesting(),
      /*create_if_needed=*/true);
  TestingProfile* guest = profile_manager()->CreateGuestProfile();
  ASSERT_TRUE(auxiliary_otr);
  ASSERT_TRUE(guest);
  std::vector<Profile*> unsupported_profiles = {auxiliary_otr, guest};
#if !BUILDFLAG(IS_CHROMEOS) && !BUILDFLAG(IS_ANDROID)
  TestingProfile* system = profile_manager()->CreateSystemProfile();
  ASSERT_TRUE(system);
  unsupported_profiles.push_back(system);
#endif

  for (Profile* unsupported : unsupported_profiles) {
    auto contents = content::WebContents::Create(
        content::WebContents::CreateParams(unsupported));
    content::TestWebUI web_ui;
    web_ui.set_web_contents(contents.get());
    TestAegisUIHandler handler;
    handler.set_web_ui(&web_ui);
    handler.RegisterMessages();

    std::vector<std::pair<std::string, base::ListValue>> messages;
    base::ListValue parse_metalink;
    parse_metalink.Append("parse-metalink");
    parse_metalink.Append("<metalink/>");
    messages.emplace_back("parseMetalink", std::move(parse_metalink));
    base::ListValue start_metalink;
    start_metalink.Append("start-metalink");
    start_metalink.Append("request-id");
    messages.emplace_back("startMetalinkDownload", std::move(start_metalink));
#if BUILDFLAG(IS_MAC)
    base::ListValue parse_torrent;
    parse_torrent.Append("parse-torrent");
    parse_torrent.Append("AA==");
    messages.emplace_back("parseTorrent", std::move(parse_torrent));
    base::ListValue parse_magnet;
    parse_magnet.Append("parse-magnet");
    parse_magnet.Append("magnet:?xt=urn:btih:test");
    messages.emplace_back("parseMagnet", std::move(parse_magnet));
    base::ListValue start_torrent;
    start_torrent.Append("start-torrent");
    start_torrent.Append("request-id");
    start_torrent.Append(base::ListValue());
    start_torrent.Append(base::DictValue());
    start_torrent.Append(true);
    messages.emplace_back("startTorrent", std::move(start_torrent));
    base::ListValue torrent_status;
    torrent_status.Append("torrent-status");
    torrent_status.Append("regular-task-id");
    messages.emplace_back("getTorrentStatus", std::move(torrent_status));
    base::ListValue control_torrent;
    control_torrent.Append("control-torrent");
    control_torrent.Append("regular-task-id");
    control_torrent.Append("pause");
    messages.emplace_back("controlTorrent", std::move(control_torrent));
#endif

    for (const auto& [message, args] : messages) {
      web_ui.ClearTrackedCalls();
      web_ui.HandleReceivedMessage(message, args);
      ASSERT_EQ(1u, web_ui.call_data().size()) << message;
      const content::TestWebUI::CallData& response = *web_ui.call_data().back();
      EXPECT_EQ("cr.webUIResponse", response.function_name()) << message;
      ASSERT_TRUE(response.arg2()) << message;
      EXPECT_TRUE(response.arg2()->GetBool()) << message;
      ASSERT_TRUE(response.arg3()) << message;
      ASSERT_TRUE(response.arg3()->is_dict()) << message;
      const base::DictValue& body = response.arg3()->GetDict();
      EXPECT_FALSE(body.FindBool("ok").value_or(true)) << message;
      EXPECT_FALSE(body.FindBool("found").value_or(true)) << message;
      const std::string* error = body.FindString("error");
      ASSERT_TRUE(error) << message;
      EXPECT_EQ("Aegis is unavailable for this profile", *error) << message;
    }
  }
}

}  // namespace
}  // namespace aegis
