// Copyright 2026 The GCSA Aegis Authors
// 安装结果和用户启动意图的契约测试，不写注册表或启动真实浏览器。
#include "chrome/installer/setup/aegis_launch_policy.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace installer {
TEST(AegisLaunchPolicyTest, LaunchesAfterFreshRepairAndUpdate) {
  for (auto status :
       {FIRST_INSTALL_SUCCESS, INSTALL_REPAIRED, NEW_VERSION_UPDATED,
        IN_USE_UPDATED, OLD_VERSION_DOWNGRADE, IN_USE_DOWNGRADE}) {
    EXPECT_TRUE(ShouldLaunchAegisAfterInstall(status, true, false, false));
    EXPECT_FALSE(ShouldLaunchAegisAfterInstall(status, false, false, false));
    EXPECT_FALSE(ShouldLaunchAegisAfterInstall(status, true, true, false));
    EXPECT_FALSE(ShouldLaunchAegisAfterInstall(status, true, false, true));
  }
}

TEST(AegisLaunchPolicyTest, FailureMaintenanceAndExistingLaunchNeverLaunch) {
  for (auto status : {INSTALL_FAILED, SAME_VERSION_REPAIR_FAILED, OS_ERROR,
                      UNINSTALL_SUCCESSFUL, EXISTING_VERSION_LAUNCHED,
                      RENAME_SUCCESSFUL, INVALID_ARCHIVE}) {
    EXPECT_FALSE(ShouldLaunchAegisAfterInstall(status, true, false, false));
  }
}
TEST(AegisLaunchPolicyTest, MissingShellDoesNotInspectOrLaunch) {
  bool inspected = false;
  bool launched = false;
  EXPECT_FALSE(LaunchAegisThroughDesktop(
      [] { return 0; },
      [&](int) { inspected = true; return true; },
      [&] { launched = true; return true; }));
  EXPECT_FALSE(inspected);
  EXPECT_FALSE(launched);
}

TEST(AegisLaunchPolicyTest, ElevatedOrUnknownShellDoesNotLaunch) {
  bool launched = false;
  EXPECT_FALSE(LaunchAegisThroughDesktop(
      [] { return 42; },
      [](int pid) { EXPECT_EQ(42, pid); return false; },
      [&] { launched = true; return true; }));
  EXPECT_FALSE(launched);
}

TEST(AegisLaunchPolicyTest, SafeShellUsesBrokerExactlyOnceIncludingFailure) {
  // Standard-user shells need no split token. Broker failure is terminal.
  for (bool broker_succeeds : {false, true}) {
    int launches = 0;
    EXPECT_EQ(broker_succeeds, LaunchAegisThroughDesktop(
        [] { return 42; },
        [](int pid) { EXPECT_EQ(42, pid); return true; },
        [&] { ++launches; return broker_succeeds; }));
    EXPECT_EQ(1, launches);
  }
}
}  // namespace installer
