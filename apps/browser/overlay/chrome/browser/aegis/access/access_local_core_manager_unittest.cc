// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_local_core_manager.h"

#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {
class AccessLocalCoreManagerTest : public testing::Test {
 protected:
  base::test::TaskEnvironment environment_;
};
TEST_F(AccessLocalCoreManagerTest, MissingBindingCannotBecomeReady) {
  AccessLocalCoreManager manager({});
  base::test::TestFuture<AccessLocalCoreReady> future;
  manager.Prepare(future.GetCallback());
  const auto& result = future.Get();
  EXPECT_FALSE(result.ready);
  EXPECT_FALSE(result.error.empty());
  EXPECT_FALSE(result.local_credentials);
  EXPECT_EQ(result.port, 0);
}
TEST_F(AccessLocalCoreManagerTest, IncorrectBinaryPinCannotLaunch) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  const auto manifest = directory.GetPath().AppendASCII("manifest.json");
  const auto node = directory.GetPath().AppendASCII("node.json");
  ASSERT_TRUE(base::WriteFile(manifest,
      R"({"binaryPath":"/usr/bin/false","binarySha256":"incorrect"})"));
  ASSERT_TRUE(base::WriteFile(node, "{}"));
  AccessLocalCoreManager manager({manifest, node});
  base::test::TestFuture<AccessLocalCoreReady> future;
  manager.Prepare(future.GetCallback());
  EXPECT_FALSE(future.Get().ready);
  EXPECT_FALSE(future.Get().local_credentials);
}
TEST_F(AccessLocalCoreManagerTest, AuthorizedNodeHttpsRecheckAndStop) {
  const auto* command = base::CommandLine::ForCurrentProcess();
  const auto manifest = command->GetSwitchValuePath("aegis-access-dev-core-manifest");
  const auto node = command->GetSwitchValuePath("aegis-access-dev-node-config");
  if (manifest.empty() || node.empty())
    GTEST_SKIP() << "Authorized DEV core/node binding is required for real HTTPS acceptance.";
  AccessLocalCoreManager manager({manifest, node});
  base::test::TestFuture<AccessLocalCoreReady> first;
  manager.Prepare(first.GetCallback());
  ASSERT_TRUE(first.Get().ready) << first.Get().error;
  ASSERT_TRUE(first.Get().local_credentials);
  EXPECT_NE(first.Get().port, 0);
  EXPECT_FALSE(first.Get().registration_id.empty());
  base::test::TestFuture<AccessLocalCoreReady> recheck;
  manager.Verify(recheck.GetCallback());
  ASSERT_TRUE(recheck.Get().ready) << recheck.Get().error;
  EXPECT_EQ(recheck.Get().registration_id, first.Get().registration_id);
  EXPECT_TRUE(recheck.Get().local_credentials->Equals(*first.Get().local_credentials));
  base::test::TestFuture<void> stopped;
  manager.Stop(stopped.GetCallback());
  ASSERT_TRUE(stopped.Wait());
  base::test::TestFuture<AccessLocalCoreReady> after;
  manager.Verify(after.GetCallback());
  EXPECT_FALSE(after.Get().ready);
  EXPECT_FALSE(after.Get().local_credentials);
}
}  // namespace
}  // namespace aegis::access
