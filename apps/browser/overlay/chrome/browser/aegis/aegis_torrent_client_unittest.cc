// Copyright 2026 GCSA

#include "chrome/browser/aegis/aegis_torrent_client.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {

TEST(TorrentTaskRegistryTest, KeepsTasksWithinTheirProfileOwner) {
  TorrentTaskRegistry registry;

  ASSERT_TRUE(registry.BeginStart("regular"));
  EXPECT_EQ(registry.CompleteStart("regular", true, "task-1"),
            TorrentTaskRegistry::StartDisposition::kDeliver);
  EXPECT_EQ(registry.CurrentTaskId("regular"), "task-1");
  EXPECT_TRUE(registry.OwnsTask("regular", "task-1"));
  EXPECT_FALSE(registry.OwnsTask("incognito", "task-1"));
  registry.ForgetTask("regular", "task-1");
  EXPECT_TRUE(registry.CurrentTaskId("regular").empty());
  EXPECT_FALSE(registry.OwnsTask("regular", "task-1"));
}

TEST(TorrentTaskRegistryTest, RevocationReturnsTaskAndClearsControls) {
  TorrentTaskRegistry registry;

  ASSERT_TRUE(registry.BeginStart("incognito"));
  ASSERT_EQ(registry.CompleteStart("incognito", true, "task-1"),
            TorrentTaskRegistry::StartDisposition::kDeliver);
  EXPECT_EQ(registry.RevokeOwner("incognito"),
            std::vector<std::string>({"task-1"}));
  EXPECT_TRUE(registry.CurrentTaskId("incognito").empty());
  EXPECT_FALSE(registry.OwnsTask("incognito", "task-1"));
}

TEST(TorrentTaskRegistryTest, RevocationWinsPendingStartRace) {
  TorrentTaskRegistry registry;

  ASSERT_TRUE(registry.BeginStart("incognito"));
  EXPECT_TRUE(registry.RevokeOwner("incognito").empty());
  EXPECT_EQ(registry.CompleteStart("incognito", true, "late-task"),
            TorrentTaskRegistry::StartDisposition::kCancel);
  EXPECT_FALSE(registry.OwnsTask("incognito", "late-task"));
  // The shutdown tombstone is removed after the last pending callback. The
  // random capability cannot be reused by a destroyed Profile, and the global
  // registry does not retain it forever.
  EXPECT_TRUE(registry.BeginStart("incognito"));
}

TEST(TorrentTaskRegistryTest, AllowsOnlyOneTransferOrPendingStartPerOwner) {
  TorrentTaskRegistry registry;

  ASSERT_TRUE(registry.BeginStart("regular"));
  EXPECT_FALSE(registry.BeginStart("regular"));
  ASSERT_EQ(registry.CompleteStart("regular", true, "task-1"),
            TorrentTaskRegistry::StartDisposition::kDeliver);
  EXPECT_FALSE(registry.BeginStart("regular"));
  registry.ForgetTask("regular", "task-1");
  ASSERT_TRUE(registry.BeginStart("regular"));
  EXPECT_EQ(registry.CompleteStart("regular", true, "task-2"),
            TorrentTaskRegistry::StartDisposition::kDeliver);
  EXPECT_EQ(registry.CurrentTaskId("regular"), "task-2");
}

TEST(TorrentTaskRegistryTest, FailedStartDoesNotCreateOwnership) {
  TorrentTaskRegistry registry;

  ASSERT_TRUE(registry.BeginStart("regular"));
  EXPECT_EQ(registry.CompleteStart("regular", false, std::string()),
            TorrentTaskRegistry::StartDisposition::kDeliver);
  EXPECT_FALSE(registry.OwnsTask("regular", "task-1"));
}

}  // namespace aegis
