// Copyright 2026 GCSA

#include "chrome/common/aegis/filter_list.h"

#include <string>
#include <vector>

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

TEST(FilterListTest, ParsesSupportedRulesAndRejectsScopedOrCosmeticRules) {
  bool is_exception = false;
  bool is_path = false;
  std::string rule;

  EXPECT_TRUE(ParseEasyListRule("||Ads.Example.com^$third-party", &is_exception,
                                &rule, &is_path));
  EXPECT_FALSE(is_exception);
  EXPECT_FALSE(is_path);
  EXPECT_EQ(rule, "ads.example.com");

  EXPECT_TRUE(ParseEasyListRule("@@||cdn.example.com/pixel", &is_exception,
                                &rule, &is_path));
  EXPECT_TRUE(is_exception);
  EXPECT_TRUE(is_path);
  EXPECT_EQ(rule, "cdn.example.com/pixel");

  EXPECT_FALSE(
      ParseEasyListRule("example.com##.ad", &is_exception, &rule, &is_path));
  EXPECT_FALSE(ParseEasyListRule("||x.example^$domain=shop.example",
                                 &is_exception, &rule, &is_path));
  EXPECT_FALSE(
      ParseEasyListRule("||*.example^", &is_exception, &rule, &is_path));
  EXPECT_FALSE(
      ParseEasyListRule("||not-a-host^", &is_exception, &rule, &is_path));
}

TEST(FilterListTest, CompilesUniqueSortedTablesWithAccounting) {
  const CompiledFilterList compiled = CompileEasyList(
      "||b.example^\n"
      "||a.example^\n"
      "||a.example^\n"
      "||a.example/pixel\n"
      "@@||cdn.example^\n"
      "example.com##.ad\n",
      "fixture");

  EXPECT_EQ(compiled.hosts,
            (std::vector<std::string>{"a.example", "b.example"}));
  EXPECT_EQ(compiled.path_rules, (std::vector<std::string>{"a.example/pixel"}));
  EXPECT_EQ(compiled.exceptions, (std::vector<std::string>{"cdn.example"}));
  EXPECT_EQ(compiled.parsed, 5);
  EXPECT_EQ(compiled.skipped, 1);
}

TEST(FilterListTest, JsonRoundTripPreservesCompiledPolicy) {
  CompiledFilterList original = CompileEasyList(
      "||ads.example^\n@@||safe.ads.example^\n||assets.example/pixel",
      "fixture");
  original.generated_at = "2026-08-24T00:00:00Z";

  CompiledFilterList decoded;
  ASSERT_TRUE(
      CompiledFilterListFromJson(CompiledFilterListToJson(original), &decoded));

  EXPECT_EQ(decoded.version, original.version);
  EXPECT_EQ(decoded.source, original.source);
  EXPECT_EQ(decoded.generated_at, original.generated_at);
  EXPECT_EQ(decoded.hosts, original.hosts);
  EXPECT_EQ(decoded.path_rules, original.path_rules);
  EXPECT_EQ(decoded.exceptions, original.exceptions);
  EXPECT_EQ(decoded.parsed, original.parsed);
  EXPECT_EQ(decoded.skipped, original.skipped);
}

TEST(FilterListTest, RejectsInvalidJsonAndUnknownCacheFormat) {
  CompiledFilterList decoded;
  EXPECT_FALSE(CompiledFilterListFromJson("not-json", &decoded));
  EXPECT_FALSE(CompiledFilterListFromJson(R"({"cacheFormat":2})", &decoded));
}

}  // namespace
}  // namespace aegis
