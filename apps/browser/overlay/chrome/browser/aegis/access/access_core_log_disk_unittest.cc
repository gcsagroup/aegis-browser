// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_core_log_store.h"

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/callback_helpers.h"
#include "base/synchronization/waitable_event.h"
#include "base/test/bind.h"
#include "base/test/task_environment.h"
#include "base/threading/thread_restrictions.h"
#include "chrome/browser/aegis/access/access_local_core_manager.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {
using Scope = CoreLogProfile;
using Status = AccessCoreLogStore::DiskStatus;
constexpr char kTime[] = "2026/11/11 01:02:03 ";
std::string Entry(std::string_view target) {
  return std::string(kTime) + "from 127.0.0.1:3000 accepted https://" +
         std::string(target) +
         "/path?token=synthetic-secret [private-tag] email: private-user";
}

class AccessCoreLogDiskTest : public testing::Test {
 protected:
  void SetUp() override { ASSERT_TRUE(profile_.CreateUniqueTempDir()); }
  auto Open(Scope scope = Scope::kRegular, std::string_view level = "info") {
    return AccessCoreLogStore::Open(profile_.GetPath(), scope, level);
  }
  base::FilePath Directory() {
    return profile_.GetPath().AppendASCII(kCoreLogDirectory);
  }
  base::FilePath Regular() { return Directory().AppendASCII("regular.log"); }
  base::FilePath Private() { return Directory().AppendASCII("private.log"); }
  base::test::TaskEnvironment environment_{
      base::test::TaskEnvironment::ThreadPoolExecutionMode::QUEUED};
  base::ScopedTempDir profile_;
};

TEST_F(AccessCoreLogDiskTest,
       RestoreBoundedSanitizedScopesWithPrivatePermissions) {
  auto regular = Open();
  auto priv = Open(Scope::kPrivate);
  for (int i = 0; i < 160; ++i)
    regular->Add(0, Entry(std::to_string(i) + ".example"), {});
  priv->Add(0, Entry("private.example"), {});
  environment_.RunUntilIdle();
  EXPECT_EQ(regular->disk_status(), Status::kReady);
  EXPECT_EQ(priv->disk_status(), Status::kReady);
  std::string history;
  ASSERT_TRUE(base::ReadFileToString(Regular(), &history));
  EXPECT_EQ(history, regular->Snapshot());
  EXPECT_EQ(std::count(history.begin(), history.end(), '\n'), 127);
  EXPECT_EQ(history.find("private.example"), history.npos);
  EXPECT_EQ(history.find("synthetic-secret"), history.npos);
  EXPECT_EQ(history.find("private-tag"), history.npos);
  EXPECT_LT(history.size(), 65536u);
  int mode = 0;
  ASSERT_TRUE(base::GetPosixFilePermissions(Directory(), &mode));
  EXPECT_EQ(mode, 0700);
  for (auto path : {Regular(), Private()}) {
    ASSERT_TRUE(base::GetPosixFilePermissions(path, &mode));
    EXPECT_EQ(mode, 0600);
  }
  const auto private_text = priv->Snapshot();
  regular.reset();
  priv.reset();
  auto restored = Open();
  auto restored_private = Open(Scope::kPrivate);
  restored_private->Add(0, Entry("new.example"), {});
  environment_.RunUntilIdle();
  EXPECT_EQ(restored->Snapshot(), history);
  EXPECT_TRUE(restored_private->Snapshot().starts_with(private_text + "\n"));
  EXPECT_NE(restored_private->Snapshot().find("new.example"), history.npos);
}
TEST_F(AccessCoreLogDiskTest, ClearAndNoneDefeatOlderRestoreAndQueuedWrites) {
  auto regular = Open();
  auto priv = Open(Scope::kPrivate);
  regular->Add(0, Entry("old.example"), {});
  priv->Add(0, Entry("private.example"), {});
  environment_.RunUntilIdle();
  regular.reset();
  regular = Open();
  regular->Add(0, Entry("queued.example"), {});
  regular->Clear();
  regular->Add(0, Entry("after.example"), {});
  environment_.RunUntilIdle();
  std::string contents;
  ASSERT_TRUE(base::ReadFileToString(Regular(), &contents));
  EXPECT_NE(contents.find("after.example"), contents.npos);
  EXPECT_EQ(contents.find("old.example"), contents.npos);
  EXPECT_EQ(contents.find("queued.example"), contents.npos);
  regular->Clear();
  environment_.RunUntilIdle();
  EXPECT_FALSE(base::PathExists(Regular()));
  EXPECT_TRUE(base::PathExists(Private()));
  priv->SetLevel("none");
  priv->Add(0, Entry("stale.example"), {});
  environment_.RunUntilIdle();
  EXPECT_TRUE(priv->Snapshot().empty());
  EXPECT_FALSE(base::PathExists(Private()));
  auto reopened = Open(Scope::kPrivate, "none");
  environment_.RunUntilIdle();
  EXPECT_TRUE(reopened->Snapshot().empty());
}
TEST_F(AccessCoreLogDiskTest, UnsafeFilesShowFailureWithoutFollowingLinks) {
  auto store = Open();
  store->Add(0, Entry("seed.example"), {});
  environment_.RunUntilIdle();
  ASSERT_TRUE(base::DeleteFile(Regular()));
  auto unrelated = profile_.GetPath().AppendASCII("other");
  ASSERT_TRUE(base::WriteFile(unrelated, "do not touch"));
  ASSERT_TRUE(base::CreateSymbolicLink(unrelated, Regular()));
  store->Add(0, Entry("still-in-memory.example"), {});
  environment_.RunUntilIdle();
  EXPECT_EQ(store->disk_status(), Status::kError);
  EXPECT_NE(store->Snapshot().find("still-in-memory.example"),
            std::string::npos);
  std::string contents;
  ASSERT_TRUE(base::ReadFileToString(unrelated, &contents));
  EXPECT_EQ(contents, "do not touch");
  store->Clear();
  environment_.RunUntilIdle();
  EXPECT_EQ(store->disk_status(), Status::kReady);
  EXPECT_FALSE(base::IsLink(Regular()));
  EXPECT_TRUE(base::PathExists(unrelated));
  ASSERT_TRUE(base::SetPosixFilePermissions(Directory(), 0755));
  store->Clear();
  environment_.RunUntilIdle();
  EXPECT_EQ(store->disk_status(), Status::kError);
  ASSERT_TRUE(base::SetPosixFilePermissions(Directory(), 0700));
  store->Clear();
  environment_.RunUntilIdle();
  EXPECT_EQ(store->disk_status(), Status::kReady);
}

void CheckPendingDeletionAtSessionEnding(bool disable) {
  base::test::TaskEnvironment environment;
  base::ScopedTempDir profile;
  ASSERT_TRUE(profile.CreateUniqueTempDir());
  auto regular = AccessCoreLogStore::Open(profile.GetPath(), Scope::kRegular, "info");
  auto priv = AccessCoreLogStore::Open(profile.GetPath(), Scope::kPrivate, "info");
  regular->Add(0, Entry("regular.example"), {});
  priv->Add(0, Entry("private.example"), {});
  environment.RunUntilIdle();
  const auto directory = profile.GetPath().AppendASCII(kCoreLogDirectory);
  const auto regular_file = directory.AppendASCII("regular.log");
  const auto private_file = directory.AppendASCII("private.log");
  ASSERT_TRUE(base::PathExists(regular_file));
  ASSERT_TRUE(base::PathExists(private_file));

  auto entered = std::make_shared<base::WaitableEvent>();
  auto release = std::make_shared<base::WaitableEvent>();
  base::ScopedClosureRunner unblock(base::BindLambdaForTesting(
      [release] { release->Signal(); }));
  AccessCoreLogStore::FlushAllForSessionEnding(base::BindLambdaForTesting(
      [entered, release] {
        base::ScopedAllowBaseSyncPrimitivesForTesting allow;
        entered->Signal();
        release->Wait();
      }));
  {
    base::ScopedAllowBaseSyncPrimitivesForTesting allow;
    ASSERT_TRUE(entered->TimedWait(base::Seconds(5)));
  }
  for (auto store : {regular, priv}) {
    store->Add(0, Entry("queued.example"), {});
    if (disable) store->SetLevel("none");
    else store->Clear();
  }
  regular.reset();
  priv.reset();
  auto stopped = std::make_shared<base::WaitableEvent>();
  AccessLocalCoreManager::StopAllForSessionEnding(base::BindLambdaForTesting(
      [stopped] { stopped->Signal(); }));
  EXPECT_FALSE(stopped->IsSignaled());
  EXPECT_TRUE(base::PathExists(regular_file));
  EXPECT_TRUE(base::PathExists(private_file));
  unblock.RunAndReset();
  {
    // The session-ending Browser sequence does not process UI replies.
    base::ScopedAllowBaseSyncPrimitivesForTesting allow;
    ASSERT_TRUE(stopped->TimedWait(base::Seconds(5)));
  }
  EXPECT_FALSE(base::PathExists(regular_file));
  EXPECT_FALSE(base::PathExists(private_file));
  regular = AccessCoreLogStore::Open(profile.GetPath(), Scope::kRegular, "info");
  priv = AccessCoreLogStore::Open(profile.GetPath(), Scope::kPrivate, "info");
  environment.RunUntilIdle();
  EXPECT_TRUE(regular->Snapshot().empty());
  EXPECT_TRUE(priv->Snapshot().empty());
}

TEST(AccessCoreLogSessionEndingTest, PendingClearCompletesWithoutUiReplies) {
  CheckPendingDeletionAtSessionEnding(false);
}
TEST(AccessCoreLogSessionEndingTest, PendingNoneCompletesWithoutUiReplies) {
  CheckPendingDeletionAtSessionEnding(true);
}
}  // namespace
}  // namespace aegis::access
