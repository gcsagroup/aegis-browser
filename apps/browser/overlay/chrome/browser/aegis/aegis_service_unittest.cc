// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_service.h"

#include <utility>
#include <vector>

#include "base/test/test_future.h"
#include "base/values.h"
#include "chrome/common/aegis/pref_names.h"
#include "chrome/test/base/chrome_render_view_host_test_harness.h"
#include "chrome/test/base/testing_browser_process.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "net/http/http_request_headers.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

class AegisServiceDocumentIdTest : public ChromeRenderViewHostTestHarness {};

PageSnapshot PublicSnapshot(std::string url) {
  PageSnapshot snapshot;
  snapshot.url = std::move(url);
  snapshot.title = "Public article";
  snapshot.text_sample = "A public article for the model integration test.";
  return snapshot;
}

PreparedSummary PreparedFor(const PageSnapshot& snapshot) {
  PreparedSummary prepared;
  prepared.schema_version = kPreparedSummarySchemaVersion;
  prepared.snapshot.url = snapshot.url;
  prepared.snapshot.title = snapshot.title;
  prepared.snapshot.text_sample = snapshot.text_sample;
  prepared.snapshot.password_fields = snapshot.password_fields;
  prepared.snapshot.forms = snapshot.forms;
  prepared.summary = "Local fallback summary.";
  prepared.bullets = {"Local fallback bullet."};
  return prepared;
}

TEST_F(AegisServiceDocumentIdTest, ChangesAcrossSameSiteDocuments) {
  NavigateAndCommit(GURL("https://example.test/first"));
  content::RenderFrameHost* first_frame = web_contents()->GetPrimaryMainFrame();
  const std::string first_id =
      AegisService::DocumentIdForWebContents(web_contents());
  EXPECT_EQ(first_frame->GetReportingSource().ToString(), first_id);

  NavigateAndCommit(GURL("https://example.test/second"));
  content::RenderFrameHost* second_frame =
      web_contents()->GetPrimaryMainFrame();
  const std::string second_id =
      AegisService::DocumentIdForWebContents(web_contents());
  EXPECT_EQ(second_frame->GetReportingSource().ToString(), second_id);
  EXPECT_NE(first_id, second_id);
}

class AegisServiceModelSettingsTest : public ChromeRenderViewHostTestHarness {
 protected:
  void SetUp() override {
    ChromeRenderViewHostTestHarness::SetUp();
    TestingBrowserProcess::GetGlobal()->SetSharedURLLoaderFactory(
        test_url_loader_factory_.GetSafeWeakWrapper());
    AegisService::GetInstance()->InitializeForProfile(profile());
  }

  void TearDown() override {
    AegisService::GetInstance()->OnProfileWillBeDestroyed(profile());
    TestingBrowserProcess::GetGlobal()->SetSharedURLLoaderFactory(nullptr);
    ChromeRenderViewHostTestHarness::TearDown();
  }

  network::TestURLLoaderFactory test_url_loader_factory_;
};

TEST_F(AegisServiceModelSettingsTest,
       NewProfileDefaultsToOpenAIWithoutMigration) {
  AegisService* service = AegisService::GetInstance();
  EXPECT_EQ("openai", service->ConfiguredModelProvider());
  EXPECT_EQ("https://api.openai.com/v1", service->ConfiguredModelBaseUrl());
  EXPECT_EQ("gpt-4.1-mini", service->ConfiguredModelName());
  EXPECT_FALSE(profile()
                   ->GetPrefs()
                   ->FindPreference(prefs::kOllamaBaseUrl)
                   ->HasUserSetting());
  EXPECT_FALSE(profile()
                   ->GetPrefs()
                   ->FindPreference(prefs::kModelBaseUrl)
                   ->HasUserSetting());
}

TEST_F(AegisServiceModelSettingsTest,
       ProfileBoundaryRejectsOtherAndOffTheRecordProfiles) {
  AegisService* service = AegisService::GetInstance();
  auto other_profile = TestingProfile::Builder().Build();
  Profile* off_the_record =
      profile()->GetPrimaryOTRProfile(/*create_if_needed=*/true);

  EXPECT_TRUE(service->IsInitializedForProfile(profile()));
  EXPECT_FALSE(service->IsInitializedForProfile(nullptr));
  EXPECT_FALSE(service->IsInitializedForProfile(other_profile.get()));
  EXPECT_FALSE(service->IsInitializedForProfile(off_the_record));

  // 无痕 Profile 的初始化尝试不得挤掉已绑定的普通 Profile。
  service->InitializeForProfile(off_the_record);
  EXPECT_TRUE(service->IsInitializedForProfile(profile()));
  EXPECT_FALSE(service->IsInitializedForProfile(off_the_record));
}

TEST_F(AegisServiceModelSettingsTest, EncryptsAndClearsProviderApiKey) {
  constexpr char kApiKey[] = "sk-test-provider-secret";
  constexpr char kBaseUrl[] = "http://127.0.0.1:8000/v1";
  constexpr char kCredentialKey[] = "openai|http://127.0.0.1:8000/v1";
  AegisService* service = AegisService::GetInstance();
  base::test::TestFuture<bool, std::string> saved;
  service->SetModelSettings("openai", kBaseUrl, "gpt-test-model", kApiKey,
                            false, saved.GetCallback());

  ASSERT_TRUE(saved.Get<0>()) << saved.Get<1>();
  EXPECT_EQ("openai", service->ConfiguredModelProvider());
  EXPECT_EQ(kBaseUrl, service->ConfiguredModelBaseUrl());
  EXPECT_EQ("gpt-test-model", service->ConfiguredModelName());
  EXPECT_TRUE(service->HasModelApiKey("openai", kBaseUrl));
  EXPECT_TRUE(service->HasModelApiKey("openai", "http://127.0.0.1:8000/v1/"));
  EXPECT_FALSE(service->HasModelApiKey(
      "openai", "https://gateway.example/custom/prefix"));
  const std::string* ciphertext = profile()
                                      ->GetPrefs()
                                      ->GetDict(prefs::kModelApiKeyCiphertexts)
                                      .FindString(kCredentialKey);
  ASSERT_TRUE(ciphertext);
  EXPECT_FALSE(ciphertext->empty());
  EXPECT_EQ(std::string::npos, ciphertext->find(kApiKey));

  base::test::TestFuture<bool, std::string> switched;
  service->SetModelSettings("openai", "https://gateway.example/custom/prefix/",
                            "gateway-model", std::string(), false,
                            switched.GetCallback());
  ASSERT_TRUE(switched.Get<0>()) << switched.Get<1>();
  EXPECT_EQ("https://gateway.example/custom/prefix",
            service->ConfiguredModelBaseUrl());
  EXPECT_TRUE(service->HasModelApiKey("openai", kBaseUrl));
  EXPECT_FALSE(service->HasModelApiKey(
      "openai", "https://gateway.example/custom/prefix"));

  const GURL models_endpoint("https://gateway.example/custom/prefix/models");
  base::test::TestFuture<bool, std::string, std::vector<std::string>> listed;
  service->ListModels("openai", "https://gateway.example/custom/prefix/", "",
                      listed.GetCallback());
  test_url_loader_factory_.WaitForRequest(models_endpoint);
  const network::ResourceRequest* request = nullptr;
  ASSERT_TRUE(
      test_url_loader_factory_.IsPending(models_endpoint.spec(), &request));
  ASSERT_TRUE(request);
  EXPECT_FALSE(
      request->headers.HasHeader(net::HttpRequestHeaders::kAuthorization));
  ASSERT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      models_endpoint.spec(), R"({"data":[{"id":"gateway-model"}]})"));
  EXPECT_TRUE(listed.Get<0>()) << listed.Get<1>();
  ASSERT_EQ(1u, listed.Get<2>().size());
  EXPECT_EQ("gateway-model", listed.Get<2>()[0]);

  base::test::TestFuture<bool, std::string> gateway_key_saved;
  service->SetModelSettings("openai", "https://gateway.example/custom/prefix",
                            "gateway-model", "gateway-test-secret", false,
                            gateway_key_saved.GetCallback());
  ASSERT_TRUE(gateway_key_saved.Get<0>()) << gateway_key_saved.Get<1>();
  EXPECT_TRUE(service->HasModelApiKey("openai",
                                      "https://gateway.example/custom/prefix"));

  base::test::TestFuture<bool, std::string> cleared;
  service->SetModelSettings("openai", "https://gateway.example/custom/prefix",
                            "gateway-model", std::string(), true,
                            cleared.GetCallback());
  ASSERT_TRUE(cleared.Get<0>()) << cleared.Get<1>();
  EXPECT_TRUE(service->HasModelApiKey("openai", kBaseUrl));
  EXPECT_FALSE(service->HasModelApiKey(
      "openai", "https://gateway.example/custom/prefix"));
  EXPECT_TRUE(profile()
                  ->GetPrefs()
                  ->GetDict(prefs::kModelApiKeyCiphertexts)
                  .contains(kCredentialKey));
}

TEST_F(AegisServiceModelSettingsTest,
       SendsPublicSummaryButKeepsSensitiveHostLocal) {
  AegisService* service = AegisService::GetInstance();
  base::test::TestFuture<bool, std::string> saved;
  service->SetModelSettings("openai", "https://api.openai.com/v1",
                            "gpt-test-model", "sk-test-provider-secret", false,
                            saved.GetCallback());
  ASSERT_TRUE(saved.Get<0>()) << saved.Get<1>();

  const PageSnapshot public_snapshot =
      PublicSnapshot("https://news.example.test/article");
  base::test::TestFuture<SummarizeResult> remote_future;
  service->SummarizePreparedPage(
      public_snapshot, PreparedFor(public_snapshot), "en-US",
      service->ConfiguredModelProvider(), service->ConfiguredModelBaseUrl(),
      service->ConfiguredModelName(), remote_future.GetCallback());

  const GURL endpoint("https://api.openai.com/v1/chat/completions");
  test_url_loader_factory_.WaitForRequest(endpoint);
  ASSERT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"choices":[{"message":{"content":"{\"summary\":\"remote ok\",\"bullets\":[\"selected model\"],\"risks\":[]}"}}]})"));
  const SummarizeResult remote = remote_future.Take();
  EXPECT_TRUE(remote.ok);
  EXPECT_EQ("openai", remote.backend);
  EXPECT_EQ("remote ok", remote.summary);
  EXPECT_TRUE(remote.model_ready);
  EXPECT_FALSE(remote.stayed_on_device);
  EXPECT_EQ("https://api.openai.com/v1", remote.destination);
  EXPECT_GT(remote.chars_sent, 0);
  EXPECT_FALSE(test_url_loader_factory_.IsPending(endpoint.spec()));

  const PageSnapshot sensitive_snapshot =
      PublicSnapshot("https://secure-bank.example.test/account");
  base::test::TestFuture<SummarizeResult> local_future;
  service->SummarizePreparedPage(
      sensitive_snapshot, PreparedFor(sensitive_snapshot), "en-US",
      service->ConfiguredModelProvider(), service->ConfiguredModelBaseUrl(),
      service->ConfiguredModelName(), local_future.GetCallback());
  const SummarizeResult local = local_future.Take();
  EXPECT_TRUE(local.ok);
  EXPECT_EQ("heuristic", local.backend);
  EXPECT_TRUE(local.stayed_on_device);
  EXPECT_EQ("local", local.destination);
  EXPECT_EQ(0, local.chars_sent);
  EXPECT_NE(std::string::npos, local.error.find("sensitive host label"));
  EXPECT_FALSE(test_url_loader_factory_.IsPending(endpoint.spec()));
}

TEST_F(AegisServiceModelSettingsTest,
       NumericLoopbackStaysLocalForAnthropicFormat) {
  AegisService* service = AegisService::GetInstance();
  base::test::TestFuture<bool, std::string> saved;
  service->SetModelSettings("anthropic", "http://127.0.0.1:8000/v1",
                            "local-claude-compatible", std::string(), false,
                            saved.GetCallback());
  ASSERT_TRUE(saved.Get<0>()) << saved.Get<1>();

  const PageSnapshot snapshot =
      PublicSnapshot("https://news.example.test/local-article");
  base::test::TestFuture<SummarizeResult> summarized;
  service->SummarizePreparedPage(
      snapshot, PreparedFor(snapshot), "en-US",
      service->ConfiguredModelProvider(), service->ConfiguredModelBaseUrl(),
      service->ConfiguredModelName(), summarized.GetCallback());

  const GURL endpoint("http://127.0.0.1:8000/v1/messages");
  test_url_loader_factory_.WaitForRequest(endpoint);
  ASSERT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      endpoint.spec(),
      R"({"content":[{"type":"text","text":"{\"summary\":\"local compatible ok\",\"bullets\":[],\"risks\":[]}"}]})"));
  const SummarizeResult result = summarized.Take();
  EXPECT_TRUE(result.ok);
  EXPECT_EQ("anthropic", result.backend);
  EXPECT_EQ("local compatible ok", result.summary);
  EXPECT_TRUE(result.model_ready);
  EXPECT_TRUE(result.stayed_on_device);
  EXPECT_EQ("http://127.0.0.1:8000/v1", result.destination);
}

TEST_F(AegisServiceModelSettingsTest, SensitivePageSkipsNumericLoopbackModel) {
  AegisService* service = AegisService::GetInstance();
  base::test::TestFuture<bool, std::string> saved;
  service->SetModelSettings("anthropic", "http://127.0.0.1:8000/v1",
                            "local-claude-compatible", std::string(), false,
                            saved.GetCallback());
  ASSERT_TRUE(saved.Get<0>()) << saved.Get<1>();

  const PageSnapshot snapshot =
      PublicSnapshot("https://secure-bank.example.test/account");
  base::test::TestFuture<SummarizeResult> summarized;
  service->SummarizePreparedPage(
      snapshot, PreparedFor(snapshot), "en-US",
      service->ConfiguredModelProvider(), service->ConfiguredModelBaseUrl(),
      service->ConfiguredModelName(), summarized.GetCallback());

  const SummarizeResult result = summarized.Take();
  EXPECT_TRUE(result.ok);
  EXPECT_EQ("heuristic", result.backend);
  EXPECT_FALSE(result.model_ready);
  EXPECT_TRUE(result.stayed_on_device);
  EXPECT_EQ("local", result.destination);
  EXPECT_EQ(0, result.chars_sent);
  EXPECT_NE(std::string::npos, result.error.find("sensitive host label"));
  EXPECT_FALSE(
      test_url_loader_factory_.IsPending("http://127.0.0.1:8000/v1/messages"));
}

TEST_F(AegisServiceModelSettingsTest,
       UsesPreviewedModelDestinationAfterSettingsChange) {
  AegisService* service = AegisService::GetInstance();
  base::test::TestFuture<bool, std::string> local_saved;
  service->SetModelSettings("openai", "http://127.0.0.1:8000/v1",
                            "previewed-local-model", std::string(), false,
                            local_saved.GetCallback());
  ASSERT_TRUE(local_saved.Get<0>()) << local_saved.Get<1>();
  const std::string previewed_provider = service->ConfiguredModelProvider();
  const std::string previewed_base_url = service->ConfiguredModelBaseUrl();
  const std::string previewed_model = service->ConfiguredModelName();

  base::test::TestFuture<bool, std::string> remote_saved;
  service->SetModelSettings("openai", "https://gateway.example.test/v1",
                            "later-remote-model", std::string(), false,
                            remote_saved.GetCallback());
  ASSERT_TRUE(remote_saved.Get<0>()) << remote_saved.Get<1>();

  const PageSnapshot snapshot =
      PublicSnapshot("https://news.example.test/config-race");
  base::test::TestFuture<SummarizeResult> summarized;
  service->SummarizePreparedPage(snapshot, PreparedFor(snapshot), "en-US",
                                 previewed_provider, previewed_base_url,
                                 previewed_model, summarized.GetCallback());

  const GURL local_endpoint("http://127.0.0.1:8000/v1/chat/completions");
  test_url_loader_factory_.WaitForRequest(local_endpoint);
  EXPECT_FALSE(test_url_loader_factory_.IsPending(
      "https://gateway.example.test/v1/chat/completions"));
  ASSERT_TRUE(test_url_loader_factory_.SimulateResponseForPendingRequest(
      local_endpoint.spec(),
      R"({"choices":[{"message":{"content":"previewed destination"}}]})"));
  const SummarizeResult result = summarized.Take();
  EXPECT_TRUE(result.ok);
  EXPECT_EQ("previewed destination", result.summary);
  EXPECT_EQ(previewed_base_url, result.destination);
  EXPECT_TRUE(result.stayed_on_device);
}

class AegisServiceLegacyMigrationTest : public ChromeRenderViewHostTestHarness {
 protected:
  void SetUp() override {
    ChromeRenderViewHostTestHarness::SetUp();
    TestingBrowserProcess::GetGlobal()->SetSharedURLLoaderFactory(
        test_url_loader_factory_.GetSafeWeakWrapper());
  }

  void TearDown() override {
    AegisService::GetInstance()->OnProfileWillBeDestroyed(profile());
    TestingBrowserProcess::GetGlobal()->SetSharedURLLoaderFactory(nullptr);
    ChromeRenderViewHostTestHarness::TearDown();
  }

  network::TestURLLoaderFactory test_url_loader_factory_;
};

TEST_F(AegisServiceLegacyMigrationTest,
       MigratesRealLegacyOllamaUserSettingsToOpenAIFormat) {
  profile()->GetPrefs()->SetString(prefs::kOllamaBaseUrl,
                                   "http://127.0.0.1:8000");
  profile()->GetPrefs()->SetString(prefs::kOllamaModel, "legacy-local-model");
  ASSERT_TRUE(profile()
                  ->GetPrefs()
                  ->FindPreference(prefs::kOllamaBaseUrl)
                  ->HasUserSetting());

  AegisService* service = AegisService::GetInstance();
  service->InitializeForProfile(profile());
  EXPECT_EQ("openai", service->ConfiguredModelProvider());
  EXPECT_EQ("http://127.0.0.1:8000/v1", service->ConfiguredModelBaseUrl());
  EXPECT_EQ("legacy-local-model", service->ConfiguredModelName());
}

TEST_F(AegisServiceLegacyMigrationTest,
       MigratesExplicitOllamaProviderWithoutReusingProviderOnlyKey) {
  profile()->GetPrefs()->SetString(prefs::kModelProvider, "ollama");
  profile()->GetPrefs()->SetString(prefs::kModelBaseUrl,
                                   "http://127.0.0.1:8000");
  profile()->GetPrefs()->SetString(prefs::kModelName, "legacy-local-model");
  base::DictValue legacy_keys;
  legacy_keys.Set("ollama", "not-a-valid-ciphertext");
  profile()->GetPrefs()->SetDict(prefs::kModelApiKeyCiphertexts,
                                 std::move(legacy_keys));

  AegisService* service = AegisService::GetInstance();
  service->InitializeForProfile(profile());
  EXPECT_EQ("openai", service->ConfiguredModelProvider());
  EXPECT_EQ("http://127.0.0.1:8000/v1", service->ConfiguredModelBaseUrl());
  EXPECT_EQ("legacy-local-model", service->ConfiguredModelName());
  EXPECT_FALSE(service->HasModelApiKey("openai", "http://127.0.0.1:8000/v1"));
}

}  // namespace
}  // namespace aegis
