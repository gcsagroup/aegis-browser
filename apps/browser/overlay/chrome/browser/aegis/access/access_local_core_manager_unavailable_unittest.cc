// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_local_core_manager.h"

#include "base/command_line.h"
#include "base/test/scoped_command_line.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

TEST(AccessLocalCoreUnavailableTest, CannotResolveEvenExplicitPrivateBinding) {
  base::test::ScopedCommandLine command;
  command.GetProcessCommandLine()->AppendSwitchASCII(
      "aegis-access-dev-core-manifest", "unavailable-manifest");
  command.GetProcessCommandLine()->AppendSwitchASCII(
      "aegis-access-dev-node-config", "unavailable-node");
  EXPECT_FALSE(ResolveAccessLocalCoreInput());
}

TEST(AccessLocalCoreUnavailableTest, AsyncPrepareVerifyAndStopNeverExposeEndpoint) {
  base::test::TaskEnvironment environment;
  AccessLocalCoreManager manager({});
  for (bool verify : {false, true}) {
    base::test::TestFuture<AccessLocalCoreReady> future;
    if (verify) manager.Verify(future.GetCallback());
    else manager.Prepare(future.GetCallback());
    EXPECT_FALSE(future.IsReady());
    const auto& ready = future.Get();
    EXPECT_FALSE(ready.ready);
    EXPECT_EQ(ready.port, 0);
    EXPECT_TRUE(ready.registration_id.empty());
    EXPECT_FALSE(ready.local_credentials);
    EXPECT_FALSE(ready.error.empty());
  }
  base::test::TestFuture<void> stopped;
  manager.Stop(stopped.GetCallback());
  EXPECT_FALSE(stopped.IsReady());
  EXPECT_TRUE(stopped.Wait());
}

}  // namespace
}  // namespace aegis::access
