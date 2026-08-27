// Copyright 2026 GCSA

#include "chrome/common/aegis/threat_feed_index.h"

#include <string>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

TEST(ThreatFeedIndexTest, RoundTripsAndMatchesHostSuffixAndExactUrl) {
  std::vector<ThreatEntry> entries;
  entries.push_back(*MakeThreatHostEntry("evil.example", kThreatSourceCertPl));
  entries.push_back(*MakeThreatUrlEntry(
      GURL("https://compromised.example/phish?id=1#fragment"),
      kThreatSourcePhishTank));
  ThreatIndex original{
      .generated_at = 100, .expires_at = 200, .entries = std::move(entries)};

  const std::string bytes = SerializeThreatIndex(original);
  const auto parsed = ParseThreatIndex(base::as_byte_span(bytes));

  ASSERT_TRUE(parsed);
  const auto host_match =
      parsed->Match(GURL("https://sub.evil.example/login"), 150);
  ASSERT_TRUE(host_match);
  EXPECT_EQ(host_match->sources, kThreatSourceCertPl);
  EXPECT_FALSE(host_match->stale);
  const auto url_match =
      parsed->Match(GURL("https://compromised.example/phish?id=1#other"), 201);
  ASSERT_TRUE(url_match);
  EXPECT_EQ(url_match->kind, ThreatEntryKind::kUrl);
  EXPECT_TRUE(url_match->stale);
  EXPECT_FALSE(
      parsed->Match(GURL("https://compromised.example/phish?id=2"), 150));
}

TEST(ThreatFeedIndexTest, MergesSourcesForSameDigest) {
  ThreatEntry first = *MakeThreatHostEntry("evil.example", kThreatSourceCertPl);
  ThreatEntry second =
      *MakeThreatHostEntry("evil.example", kThreatSourcePhishTank);
  const std::vector<ThreatEntry> merged =
      MergeThreatEntries({std::move(first), std::move(second)});

  ASSERT_EQ(merged.size(), 1u);
  EXPECT_EQ(merged[0].sources, kThreatSourceCertPl | kThreatSourcePhishTank);
}

TEST(ThreatFeedIndexTest, RejectsSingleLabelHostRules) {
  EXPECT_FALSE(MakeThreatHostEntry("com", kThreatSourceCertPl));
  EXPECT_FALSE(MakeThreatHostEntry("localhost", kThreatSourceCertPl));
}

TEST(ThreatFeedIndexTest, RejectsTruncatedOrUnsortedIndex) {
  ThreatIndex original{
      .generated_at = 100,
      .expires_at = 200,
      .entries = {*MakeThreatHostEntry("a.example", kThreatSourceCertPl),
                  *MakeThreatHostEntry("b.example", kThreatSourceCertPl)}};
  std::string bytes = SerializeThreatIndex(original);
  ASSERT_FALSE(bytes.empty());

  EXPECT_FALSE(
      ParseThreatIndex(base::as_byte_span(bytes).first(bytes.size() - 1)));
  std::swap_ranges(bytes.begin() + 36, bytes.begin() + 72, bytes.begin() + 72);
  EXPECT_FALSE(ParseThreatIndex(base::as_byte_span(bytes)));
}

}  // namespace
}  // namespace aegis
