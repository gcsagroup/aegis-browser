// Copyright 2026 GCSA

#include "chrome/common/aegis/filter_list_matcher.h"

#include <utility>

#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

class FilterListMatcherTest : public testing::Test {
 protected:
  void SetUp() override {
    CompiledFilterList list;
    list.hosts = {"tracker.example"};
    list.path_rules = {"assets.example/pixel"};
    list.exceptions = {"allowed.tracker.example"};
    FilterListMatcher::GetInstance()->ReplaceCompiledList(std::move(list));
  }

  void TearDown() override {
    FilterListMatcher::GetInstance()->ReplaceCompiledList(CompiledFilterList());
  }
};

TEST_F(FilterListMatcherTest, MatchesHostSubdomainsAndExceptionSubdomains) {
  EXPECT_EQ(FilterListMatcher::GetInstance()->ClassifyBlock(
                GURL("https://sub.tracker.example/collect")),
            BlockReason::kEasyList);
  EXPECT_EQ(FilterListMatcher::GetInstance()->ClassifyBlock(
                GURL("https://child.allowed.tracker.example/collect")),
            BlockReason::kNone);
  EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://nottracker.example/collect")));
  EXPECT_TRUE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://sub.tracker.example./collect")));
  EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://sub.tracker.example../collect")));
  EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://child.allowed.tracker.example./collect")));
}

TEST_F(FilterListMatcherTest, PathRulesRespectHostAndPathBoundaries) {
  EXPECT_TRUE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://cdn.assets.example/pixel/event")));
  EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://cdn.assets.example/safe/pixel")));
  EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://notassets.example/pixel")));
  EXPECT_TRUE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://cdn.assets.example./pixel/event")));
  EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://cdn.assets.example../pixel/event")));
  EXPECT_EQ(FilterListMatcher::GetInstance()->compiled_host_count(), 2u);
}

TEST_F(FilterListMatcherTest, ReplacesPathRuleIndexWithoutStaleEntries) {
  CompiledFilterList list;
  list.path_rules = {"new.example/event"};
  FilterListMatcher::GetInstance()->ReplaceCompiledList(std::move(list));

  EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://assets.example/pixel/event")));
  EXPECT_TRUE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://cdn.new.example/event/1")));
}

TEST_F(FilterListMatcherTest, IgnoresUnrelatedPathRuleHosts) {
  CompiledFilterList list;
  for (int i = 0; i < 6000; ++i) {
    list.path_rules.push_back("host" + std::to_string(i) + ".example/pixel");
  }
  list.path_rules.push_back("target.example/match");
  FilterListMatcher::GetInstance()->ReplaceCompiledList(std::move(list));

  for (int i = 0; i < 1000; ++i) {
    EXPECT_FALSE(FilterListMatcher::GetInstance()->ShouldBlock(
        GURL("https://unrelated.example/safe")));
  }
  EXPECT_TRUE(FilterListMatcher::GetInstance()->ShouldBlock(
      GURL("https://cdn.target.example/match/event")));
}

TEST_F(FilterListMatcherTest, BuiltinRuleWinsOverCompiledException) {
  CompiledFilterList list;
  list.exceptions = {"google-analytics.com"};
  FilterListMatcher::GetInstance()->ReplaceCompiledList(std::move(list));

  EXPECT_EQ(FilterListMatcher::GetInstance()->ClassifyBlock(
                GURL("https://www.google-analytics.com/collect")),
            BlockReason::kEasyList);
}

TEST_F(FilterListMatcherTest, DetectsFirstPartyCollectConservatively) {
  EXPECT_EQ(FilterListMatcher::GetInstance()->ClassifyBlock(
                GURL("https://shop.example/g/collect?v=2")),
            BlockReason::kFirstPartyCollect);
  EXPECT_EQ(FilterListMatcher::GetInstance()->ClassifyBlock(GURL(
                "https://shop.example/metrics?v=2&tid=G-ABC&en=view&cid=1")),
            BlockReason::kFirstPartyCollect);
  EXPECT_EQ(FilterListMatcher::GetInstance()->ClassifyBlock(
                GURL("https://shop.example/api/collect")),
            BlockReason::kNone);
  EXPECT_EQ(FilterListMatcher::GetInstance()->ClassifyBlock(GURL()),
            BlockReason::kNone);
}

}  // namespace
}  // namespace aegis
