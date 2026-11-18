// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_account_win.h"

#include <windows.h>

#include <atomic>
#include <memory>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "base/uuid.h"
#include "base/win/scoped_handle.h"
#include "chrome/browser/aegis/access/access_private_files_win.h"
#include "net/test/embedded_test_server/http_response.h"
#include "net/test/embedded_test_server/embedded_test_server.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessAccountWindowsTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(root_.CreateUniqueTempDir());
    profile_ = root_.GetPath().AppendASCII("Windows Profile");
    ASSERT_TRUE(CreatePrivateAccessDirectory(profile_));
    server_.RegisterRequestHandler(base::BindRepeating(
        &AccessAccountWindowsTest::Reply, base::Unretained(this)));
    ASSERT_TRUE(server_.Start());
  }

  base::FilePath File() const {
    return profile_.AppendASCII("AegisAccessAccount.json");
  }

  void WriteBinding() {
    auto bytes = base::WriteJson(base::DictValue()
        .Set("origin", server_.base_url().spec())
        .Set("accountId", "fixture-account")
        .Set("generation", base::Uuid::GenerateRandomV4().AsLowercaseString())
        .Set("token", "fixture_token"));
    ASSERT_TRUE(bytes);
    ASSERT_TRUE(base::WriteFile(File(), *bytes));
  }

  std::unique_ptr<net::test_server::HttpResponse> Reply(
      const net::test_server::HttpRequest& request) {
    ++requests_;
    auto response = std::make_unique<net::test_server::BasicHttpResponse>();
    auto auth = request.headers.find("Authorization");
    if (request.relative_url != "/v1/me/entitlement" || auth == request.headers.end() ||
        auth->second != "Bearer fixture_token") {
      response->set_code(net::HTTP_UNAUTHORIZED);
    } else if (redirect_.load()) {
      response->set_code(net::HTTP_TEMPORARY_REDIRECT);
      response->AddCustomHeader("Location", "/unexpected");
    } else {
      response->set_content_type("application/json");
      response->set_content(R"({
        "entitlementAccountId":"fixture-account","status":"active",
        "planId":"fixture-plan","periodId":"fixture-period","periodStart":1000,
        "periodEnd":2000000000000,"expiresAt":2000000000000,
        "uploadedBytes":"1","downloadedBytes":"2","usedBytes":"3",
        "quotaBytes":"10","remainingBytes":"7","measuredAt":2000,
        "receivedAt":2000,"snapshotAgeMs":0,"freshness":"current"
      })");
    }
    return response;
  }
  base::test::TaskEnvironment environment_;
  base::ScopedTempDir root_;
  base::FilePath profile_;
  std::atomic<int> requests_{0};
  std::atomic<bool> redirect_{false};
  net::EmbeddedTestServer server_;
};

TEST_F(AccessAccountWindowsTest, ValidatesAccountAndRetiresRemovedBinding) {
  ASSERT_NO_FATAL_FAILURE(WriteBinding());
  base::test::TestFuture<AccountSnapshot> result;
  QueryWindowsAccessAccount(profile_, result.GetCallback());
  auto snapshot = result.Take();
  auto active = snapshot.Run();
  ASSERT_TRUE(active.FindString("state"));
  EXPECT_EQ(*active.FindString("state"), "available");
  ASSERT_TRUE(active.FindDict("entitlement"));
  const auto* remaining = active.FindDict("entitlement")->FindString("remainingBytes");
  ASSERT_TRUE(remaining);
  EXPECT_EQ(*remaining, "7");
  // Signing out must release the filename even while the UI holds a snapshot.
  ASSERT_TRUE(base::DeleteFile(File()));
  EXPECT_FALSE(base::PathExists(File()));
  auto removed = snapshot.Run();
  ASSERT_TRUE(removed.FindString("state"));
  EXPECT_EQ(*removed.FindString("state"), "signed_out");
  EXPECT_FALSE(removed.FindDict("entitlement"));
  ASSERT_NO_FATAL_FAILURE(WriteBinding());
  auto replaced = snapshot.Run();
  ASSERT_TRUE(replaced.FindString("state"));
  EXPECT_EQ(*replaced.FindString("state"), "superseded");
}

TEST_F(AccessAccountWindowsTest, RebindsBeforeOldSnapshotIsPolled) {
  ASSERT_NO_FATAL_FAILURE(WriteBinding());
  base::test::TestFuture<AccountSnapshot> result;
  QueryWindowsAccessAccount(profile_, result.GetCallback());
  auto previous = result.Take();
  ASSERT_TRUE(base::DeleteFile(File()));
  ASSERT_NO_FATAL_FAILURE(WriteBinding());
  auto stale = previous.Run();
  ASSERT_TRUE(stale.FindString("state"));
  EXPECT_EQ(*stale.FindString("state"), "superseded");
  EXPECT_FALSE(stale.FindDict("entitlement"));
}

TEST_F(AccessAccountWindowsTest, PollsSnapshotWithoutReadingBindingContents) {
  ASSERT_NO_FATAL_FAILURE(WriteBinding());
  base::test::TestFuture<AccountSnapshot> result;
  QueryWindowsAccessAccount(profile_, result.GetCallback());
  auto snapshot = result.Take();
  // Metadata queries are allowed while other readers of file data are denied.
  base::win::ScopedHandle guard(::CreateFileW(
      File().value().c_str(), GENERIC_READ, FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  ASSERT_TRUE(guard.is_valid());
  auto active = snapshot.Run();
  ASSERT_TRUE(active.FindString("state"));
  EXPECT_EQ(*active.FindString("state"), "available");
}

TEST_F(AccessAccountWindowsTest, RejectsRedirectWithoutContactingDestination) {
  redirect_ = true;
  ASSERT_NO_FATAL_FAILURE(WriteBinding());
  base::test::TestFuture<AccountSnapshot> result;
  QueryWindowsAccessAccount(profile_, result.GetCallback());
  auto reply = result.Take().Run();
  ASSERT_TRUE(reply.FindString("state"));
  EXPECT_EQ(*reply.FindString("state"), "unavailable");
  EXPECT_EQ(requests_.load(), 1);
}

}  // namespace
}  // namespace aegis::access
