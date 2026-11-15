// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_account_refresh.h"

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

TEST(AccessAccountRefreshTest, DisplaysTheSameExactBinaryUnitsAsSettings) {
  EXPECT_EQ(FormatAccessUsageBytes("0"), u"0 B");
  EXPECT_EQ(FormatAccessUsageBytes("1023"), u"1023 B");
  EXPECT_EQ(FormatAccessUsageBytes("1024"), u"1.00 KiB (1024 B)");
  EXPECT_EQ(FormatAccessUsageBytes("8800000000"),
            u"8.19 GiB (8800000000 B)");
  EXPECT_EQ(FormatAccessUsageBytes("18446744073709551615"),
            u"15.99 EiB (18446744073709551615 B)");
  for (std::string_view invalid : {"", "-1", "00", "+1",
                                  "18446744073709551616"}) {
    EXPECT_EQ(FormatAccessUsageBytes(invalid), u"—");
  }
}

TEST(AccessAccountRefreshTest, SharesOneRequestAndUsesVisibleCadence) {
  AccessAccountRefresh refresh;
  const auto now = base::TimeTicks() + base::Seconds(100);
  refresh.SetActivity(true, true, now);
  ASSERT_TRUE(refresh.Begin(now));
  EXPECT_FALSE(refresh.Begin(now, true));
  refresh.Complete(true, now);
  EXPECT_EQ(refresh.DueIn(now), base::Seconds(30));

  const auto first = base::UnguessableToken::Create();
  const auto second = base::UnguessableToken::Create();
  refresh.SetVisible(first, true, now);
  ASSERT_TRUE(refresh.Begin(now));
  refresh.SetVisible(second, true, now);
  refresh.SetVisible(first, false, now);
  EXPECT_FALSE(refresh.DueIn(now));
  const auto done = now + base::Seconds(7);
  refresh.Complete(true, done);
  EXPECT_EQ(refresh.DueIn(done), base::Seconds(5));
  refresh.SetVisible(second, false, done);
  EXPECT_EQ(refresh.DueIn(done), base::Seconds(30));
}

TEST(AccessAccountRefreshTest, BackgroundCompletionCannotPollAndResumeRefreshes) {
  AccessAccountRefresh refresh;
  const auto now = base::TimeTicks() + base::Seconds(100);
  refresh.SetActivity(true, true, now);
  ASSERT_TRUE(refresh.Begin(now));
  refresh.SetActivity(false, false, now);
  EXPECT_FALSE(refresh.Begin(now, true));
  refresh.Complete(true, now);
  EXPECT_FALSE(refresh.DueIn(now + base::Minutes(1)));
  refresh.SetActivity(true, true, now + base::Minutes(1));
  EXPECT_TRUE(refresh.Begin(now + base::Minutes(1)));
}

TEST(AccessAccountRefreshTest, VisibleProfileContinuesWhileAnotherHasFocus) {
  AccessAccountRefresh first;
  AccessAccountRefresh second;
  const auto usage = base::UnguessableToken::Create();
  const auto now = base::TimeTicks() + base::Seconds(100);
  first.SetActivity(true, true, now);
  first.SetVisible(usage, true, now);
  ASSERT_TRUE(first.Begin(now));
  first.Complete(true, now);

  const auto changed = now + base::Seconds(1);
  first.SetActivity(true, false, changed);
  second.SetActivity(true, true, changed);
  EXPECT_EQ(first.DueIn(changed), base::Seconds(4));
  EXPECT_TRUE(second.Begin(changed));
  second.Complete(true, changed);
  EXPECT_EQ(second.DueIn(changed), base::Seconds(30));

  first.SetActivity(false, false, changed);
  EXPECT_FALSE(first.DueIn(changed));
  first.SetActivity(true, false, changed);
  EXPECT_EQ(first.DueIn(changed), base::TimeDelta());
  first.SetVisible(usage, false, changed);
  EXPECT_FALSE(first.DueIn(changed));
}

TEST(AccessAccountRefreshTest, ResumeWhilePendingQueuesOnlyOneRefresh) {
  AccessAccountRefresh refresh;
  const auto now = base::TimeTicks() + base::Seconds(100);
  refresh.SetActivity(true, true, now);
  ASSERT_TRUE(refresh.Begin(now));
  refresh.SetActivity(false, false, now);
  refresh.SetActivity(true, true, now);
  EXPECT_FALSE(refresh.Begin(now));
  refresh.Complete(true, now);
  ASSERT_TRUE(refresh.Begin(now));
  refresh.Complete(true, now);
  EXPECT_EQ(refresh.DueIn(now), base::Seconds(30));
}

TEST(AccessAccountRefreshTest, DebouncesManualRequestsAndBacksOffUntilSuccess) {
  AccessAccountRefresh refresh;
  const auto now = base::TimeTicks() + base::Seconds(100);
  refresh.SetActivity(true, true, now);
  refresh.SetVisible(base::UnguessableToken::Create(), true, now);
  ASSERT_TRUE(refresh.Begin(now, true));
  refresh.Complete(false, now);
  EXPECT_EQ(refresh.DueIn(now), base::Seconds(15));
  EXPECT_FALSE(refresh.Begin(now + base::Milliseconds(999), true));
  EXPECT_FALSE(refresh.Begin(now + base::Seconds(14)));
  const auto retry = now + base::Seconds(15);
  ASSERT_TRUE(refresh.Begin(retry));
  refresh.Complete(false, retry);
  EXPECT_EQ(refresh.DueIn(retry), base::Seconds(30));
  const auto manual = retry + base::Seconds(1);
  ASSERT_TRUE(refresh.Begin(manual, true));
  refresh.Complete(true, manual);
  EXPECT_EQ(refresh.DueIn(manual), base::Seconds(5));
}

TEST(AccessAccountRefreshTest, AccountChangeClearsPreviousBackoffAndDebounce) {
  AccessAccountRefresh refresh;
  const auto now = base::TimeTicks() + base::Seconds(100);
  refresh.SetActivity(true, true, now);
  ASSERT_TRUE(refresh.Begin(now, true));
  refresh.Complete(false, now);
  EXPECT_FALSE(refresh.Begin(now, true));
  refresh.IdentityChanged(now);
  EXPECT_TRUE(refresh.Begin(now, true));
}

}  // namespace
}  // namespace aegis::access
