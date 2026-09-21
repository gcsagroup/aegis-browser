// Copyright 2026 GCSA
#include "chrome/browser/ui/webui/help/aegis_github_update.h"

#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/single_thread_task_runner.h"
#include "base/test/task_environment.h"
#include "base/values.h"
#include "base/version.h"
#include "crypto/hash.h"
#include "mojo/core/embedder/embedder.h"
#include "net/http/http_status_code.h"
#include "services/network/public/cpp/weak_wrapper_shared_url_loader_factory.h"
#include "services/network/test/test_url_loader_factory.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {
constexpr char kPlatform[] = "mac-arm64.dmg";
constexpr char kPayload[] = "representative update package";

// 下载回归始终构造当前产品的下一主版本，避免换代后意外只覆盖防降级分支。
std::string FutureVersion() {
  return base::NumberToString(base::Version(kProductVersion).components()[0] +
                              1) +
         ".0.0.1";
}

base::DictValue Release(std::string version = FutureVersion()) {
  base::DictValue asset;
  const std::string name = "GCSA-aegis-" + version + "-" + kPlatform;
  asset.Set("name", name);
  asset.Set("state", "uploaded");
  asset.Set("size", static_cast<int>(std::string(kPayload).size()));
  asset.Set("digest", "sha256:" + base::ToLowerASCII(base::HexEncode(
                                      crypto::hash::Sha256(kPayload))));
  asset.Set("browser_download_url",
            "https://github.com/gcsagroup/aegis-browser/releases/download/v" +
                version + "/" + name);
  base::ListValue assets;
  assets.Append(std::move(asset));
  base::DictValue release;
  release.Set("draft", false);
  release.Set("prerelease", false);
  release.Set("tag_name", "v" + version);
  release.Set("assets", std::move(assets));
  return release;
}
std::string JSON(const base::DictValue& value) {
  return base::WriteJson(value).value();
}
ReleaseResult Parse(const base::DictValue& value) {
  return ParseGitHubRelease(JSON(value), kProductVersion, kPlatform);
}

TEST(GitHubReleaseTest, NumericVersionsAndNoDowngrade) {
  EXPECT_EQ(Parse(Release()).state, ReleaseState::kAvailable);
  for (const char* newer : {"1.1.0.999", "1.1.0.9999", "2.0.0.1"}) {
    EXPECT_EQ(
        ParseGitHubRelease(JSON(Release(newer)), "1.1.0.100", kPlatform).state,
        ReleaseState::kAvailable);
  }
  EXPECT_EQ(Parse(Release("1.1.0.1")).state, ReleaseState::kLocalNewer);
  EXPECT_EQ(Parse(Release("1.0.0.999")).state, ReleaseState::kLocalNewer);
  EXPECT_EQ(Parse(Release("151.0.7922")).state, ReleaseState::kInvalid);
  EXPECT_EQ(Parse(Release("1.1.0.02")).state, ReleaseState::kInvalid);
}
TEST(GitHubReleaseTest, RejectsDraftPrereleaseAndMalformed) {
  for (const char* key : {"draft", "prerelease"}) {
    auto release = Release();
    release.Set(key, true);
    EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
    release.Remove(key);
    EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
  }
  EXPECT_EQ(ParseGitHubRelease("broken", kProductVersion, kPlatform).state,
            ReleaseState::kInvalid);
  EXPECT_EQ(Parse(Release("1.1.0.2-beta")).state, ReleaseState::kInvalid);
}
TEST(GitHubReleaseTest, RequiresUniqueMatchingPlatformAndDigest) {
  auto release = Release();
  EXPECT_EQ(
      ParseGitHubRelease(JSON(release), kProductVersion, "win-x64.exe").state,
      ReleaseState::kMissingAsset);
  auto& asset = (*release.FindList("assets"))[0].GetDict();
  asset.Remove("digest");
  EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
  asset.Set("digest", "sha256:" + std::string(64, 'z'));
  EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
  release = Release();
  auto* assets = release.FindList("assets");
  assets->Append((*assets)[0].Clone());
  EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
}
TEST(GitHubReleaseTest, RejectsWrongURLSizeAndState) {
  auto release = Release();
  auto& asset = (*release.FindList("assets"))[0].GetDict();
  asset.Set("browser_download_url",
            "https://github.com/attacker/installer.exe");
  EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
  for (double size : {-1.0, 0.0, 1.5, 2147483649.0}) {
    release = Release();
    (*release.FindList("assets"))[0].GetDict().Set("size", size);
    EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
  }
  release = Release();
  (*release.FindList("assets"))[0].GetDict().Set("state", "new");
  EXPECT_EQ(Parse(release).state, ReleaseState::kInvalid);
}
TEST(GitHubReleaseTest, RedirectTrustBoundary) {
  EXPECT_TRUE(IsAllowedReleaseDownloadURL(
      GURL("https://release-assets.githubusercontent.com/file?token=value")));
  for (const char* url :
       {"http://github.com/file", "https://github.com.evil.test/file",
        "https://user:password@github.com/file", "https://github.com:444/file",
        "https://evil.test/file", "file:///tmp/file"}) {
    EXPECT_FALSE(IsAllowedReleaseDownloadURL(GURL(url))) << url;
  }
}
TEST(GitHubReleaseTest, StagesOnlyVerifiedPackageAndPreservesExistingFiles) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  auto temporary = directory.GetPath().AppendASCII("payload.part");
  auto asset = Parse(Release()).asset;
  ASSERT_TRUE(base::WriteFile(temporary, kPayload));
  auto saved = StageVerifiedRelease(temporary, asset, directory.GetPath());
  ASSERT_FALSE(saved.empty());
  EXPECT_TRUE(base::StartsWith(saved.DirName().BaseName().AsUTF8Unsafe(),
                               ".GCSA-update-"));
  std::string body;
  ASSERT_TRUE(base::ReadFileToString(saved, &body));
  EXPECT_EQ(body, kPayload);
  EXPECT_FALSE(base::PathExists(temporary));
  ASSERT_TRUE(base::WriteFile(temporary, kPayload));
  auto second = StageVerifiedRelease(temporary, asset, directory.GetPath());
  EXPECT_NE(saved, second);
  EXPECT_TRUE(base::PathExists(saved));
}
TEST(GitHubReleaseTest, DeletesCorruptTruncatedAndUnsafePackages) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  auto temporary = directory.GetPath().AppendASCII("payload.part");
  auto asset = Parse(Release()).asset;
  for (const std::string& payload :
       {std::string("truncated"),
        std::string(std::string(kPayload).size(), 'x')}) {
    ASSERT_TRUE(base::WriteFile(temporary, payload));
    EXPECT_TRUE(
        StageVerifiedRelease(temporary, asset, directory.GetPath()).empty());
    EXPECT_FALSE(base::PathExists(temporary));
  }
  ASSERT_TRUE(base::WriteFile(temporary, kPayload));
  asset.name = "../escape.dmg";
  EXPECT_TRUE(
      StageVerifiedRelease(temporary, asset, directory.GetPath()).empty());
  EXPECT_FALSE(base::PathExists(temporary));
}

class GitHubUpdateTest : public testing::Test {
 protected:
  void SetUp() override {
    mojo::core::Init();
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
  }
  GitHubUpdate::Callback Callback() {
    return base::BindRepeating(
        [](GitHubUpdate::State* state, int* count, GitHubUpdate::State next,
           int, const std::string&) {
          *state = next;
          ++*count;
        },
        &state_, &callbacks_);
  }
  base::test::TaskEnvironment tasks_;
  base::ScopedTempDir directory_;
  network::TestURLLoaderFactory factory_;
  GitHubUpdate::State state_ = GitHubUpdate::State::kEmpty;
  int callbacks_ = 0;
};
TEST_F(GitHubUpdateTest, NoPublishedReleaseIsNotUpToDate) {
  factory_.AddResponse(kReleaseAPI, "{}", net::HTTP_NOT_FOUND);
  GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                      kPlatform);
  update.Check(Callback());
  tasks_.RunUntilIdle();
  EXPECT_EQ(state_, GitHubUpdate::State::kEmpty);
}
TEST_F(GitHubUpdateTest, DownloadsAndVerifiesWithoutExecuting) {
  auto release = Release();
  auto asset = Parse(release).asset;
  factory_.AddResponse(kReleaseAPI, JSON(release));
  factory_.AddResponse(asset.url.spec(), kPayload);
  GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                      kPlatform);
  update.Check(Callback());
  tasks_.RunUntilIdle();
  EXPECT_EQ(state_, GitHubUpdate::State::kReady);
  EXPECT_GE(callbacks_, 4);
  EXPECT_FALSE(update.GetDownloadedUpdatePath().empty());
  EXPECT_TRUE(base::StartsWith(
      update.GetDownloadedUpdatePath().DirName().BaseName().AsUTF8Unsafe(),
      "GCSA-update-"));
  update.Check(Callback());
  EXPECT_EQ(state_, GitHubUpdate::State::kReady);
  EXPECT_EQ(factory_.NumPending(), 0);
}
TEST_F(GitHubUpdateTest, ClosingPageDoesNotSkipDownloadFinalization) {
  auto release = Release();
  auto asset = Parse(release).asset;
  factory_.AddResponse(kReleaseAPI, JSON(release));
  factory_.AddResponse(asset.url.spec(), kPayload);
  auto update = std::make_unique<GitHubUpdate>(factory_.GetSafeWeakWrapper(),
                                               directory_.GetPath(), kPlatform);
  update->Check(base::BindRepeating(
      [](std::unique_ptr<GitHubUpdate>* update, GitHubUpdate::State state,
         int progress, const std::string& message) {
        if (state == GitHubUpdate::State::kVerifying && progress == 99) {
          base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
              FROM_HERE, base::BindOnce(
                             [](std::unique_ptr<GitHubUpdate>* update) {
                               update->reset();
                             },
                             update));
        }
      },
      &update));
  tasks_.RunUntilIdle();
  EXPECT_FALSE(update);
  base::FileEnumerator directories(directory_.GetPath(), false,
                                   base::FileEnumerator::DIRECTORIES);
  const auto published = directories.Next();
  ASSERT_FALSE(published.empty());
  EXPECT_TRUE(
      base::StartsWith(published.BaseName().AsUTF8Unsafe(), "GCSA-update-"));
  EXPECT_TRUE(directories.Next().empty());
  std::string body;
  ASSERT_TRUE(base::ReadFileToString(published.AppendASCII(asset.name), &body));
  EXPECT_EQ(kPayload, body);
}

TEST_F(GitHubUpdateTest, CorruptDownloadFails) {
  auto release = Release();
  factory_.AddResponse(kReleaseAPI, JSON(release));
  factory_.AddResponse(Parse(release).asset.url.spec(), "corrupt");
  GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                      kPlatform);
  update.Check(Callback());
  tasks_.RunUntilIdle();
  EXPECT_EQ(state_, GitHubUpdate::State::kError);
}
TEST_F(GitHubUpdateTest, RateLimitCanRetryAndDuplicateChecksAreCoalesced) {
  GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                      kPlatform);
  update.Check(Callback());
  update.Check(Callback());
  EXPECT_EQ(factory_.NumPending(), 1);
  factory_.AddResponse(kReleaseAPI, "{}", net::HTTP_FORBIDDEN);
  tasks_.RunUntilIdle();
  EXPECT_EQ(state_, GitHubUpdate::State::kError);
  factory_.AddResponse(kReleaseAPI, JSON(Release(kProductVersion)));
  update.Check(Callback());
  tasks_.RunUntilIdle();
  EXPECT_EQ(state_, GitHubUpdate::State::kCurrent);
}

TEST_F(GitHubUpdateTest, SharedStateMatchesEveryAboutCallback) {
  auto release = Release();
  factory_.AddResponse(kReleaseAPI, JSON(release));
  factory_.AddResponse(Parse(release).asset.url.spec(), kPayload);
  GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                      kPlatform, "zh-CN");
  update.Check(base::BindRepeating(
      [](GitHubUpdate::State state, int progress, const std::string& text) {
        const auto& shared = GetProductUpdateStatus();
        EXPECT_EQ(shared.state, state);
        EXPECT_EQ(shared.progress, progress);
        EXPECT_EQ(shared.message, text);
      }));
  tasks_.RunUntilIdle();
  EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kReady);
  EXPECT_EQ(GetProductUpdateStatus().message, "安装包已就绪，请手动安装。");
}
TEST_F(GitHubUpdateTest, ClosingDuringRequestDoesNotLeaveCheckingStatus) {
  {
    GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                        kPlatform);
    update.Check(Callback());
    EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kChecking);
  }
  EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kUnchecked);
}
TEST_F(GitHubUpdateTest, ClosingOlderPageDoesNotClearNewerResult) {
  auto older = std::make_unique<GitHubUpdate>(factory_.GetSafeWeakWrapper(),
                                              directory_.GetPath(), kPlatform);
  older->Check(Callback());
  GitHubUpdate newer(factory_.GetSafeWeakWrapper(), directory_.GetPath(), "");
  newer.Check(Callback());
  EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kError);
  older.reset();
  EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kError);
}
TEST_F(GitHubUpdateTest, LocalNewerIsDistinctFromLatestRelease) {
  factory_.AddResponse(kReleaseAPI, JSON(Release("1.0.0.1")));
  GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                      kPlatform);
  update.Check(Callback());
  tasks_.RunUntilIdle();
  EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kLocalNewer);
  EXPECT_EQ(GetProductUpdateStatus().message,
            "This version is newer than the published release.");
  EXPECT_EQ(Parse(Release(kProductVersion)).state, ReleaseState::kCurrent);
}
TEST_F(GitHubUpdateTest, TraditionalEmptyStateAndFailureAreNotCurrent) {
  factory_.AddResponse(kReleaseAPI, "{}", net::HTTP_NOT_FOUND);
  GitHubUpdate update(factory_.GetSafeWeakWrapper(), directory_.GetPath(),
                      kPlatform, "zh-TW");
  update.Check(Callback());
  tasks_.RunUntilIdle();
  EXPECT_EQ(GetProductUpdateStatus().message, "暫無可用的正式版更新。");
  EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kEmpty);
  factory_.AddResponse(kReleaseAPI, "{}", net::HTTP_FORBIDDEN);
  update.Check(Callback());
  tasks_.RunUntilIdle();
  EXPECT_EQ(GetProductUpdateStatus().state, GitHubUpdate::State::kError);
}
}  // namespace
}  // namespace aegis
