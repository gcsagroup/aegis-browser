// Copyright 2026 GCSA

#include "chrome/common/aegis/phish_score.h"

#include <string_view>
#include <utility>

#include "chrome/common/aegis/builtin_phish_hosts.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

bool HasReason(const PhishAssessment& assessment, std::string_view code) {
  for (const PhishReason& reason : assessment.reasons) {
    if (reason.code == code) {
      return true;
    }
  }
  return false;
}

TEST(PhishScoreTest, InvalidUrlFailsClosed) {
  const PhishAssessment result = AssessPhishingUrl(GURL("http://["));

  EXPECT_EQ(result.score, 100);
  EXPECT_TRUE(result.should_block);
  ASSERT_EQ(result.reasons.size(), 1u);
  EXPECT_EQ(result.reasons[0].code, "invalid_url");
}

TEST(PhishScoreTest, BlocksBrandSpoofOnSuspiciousTld) {
  const PhishAssessment result =
      AssessPhishingUrl(GURL("http://paypal-secure-login.tk/signin"));

  EXPECT_EQ(result.score, 70);
  EXPECT_TRUE(result.should_block);
  EXPECT_TRUE(HasReason(result, "insecure_http"));
  EXPECT_TRUE(HasReason(result, "suspicious_tld"));
  EXPECT_TRUE(HasReason(result, "brand_spoof_host"));
  EXPECT_TRUE(HasReason(result, "credential_path"));
}

TEST(PhishScoreTest, DetectsDigitSubstitutionBrandLookalike) {
  const PhishAssessment result =
      AssessPhishingUrl(GURL("https://micros0ft.com/"));

  EXPECT_EQ(result.score, 40);
  EXPECT_FALSE(result.should_block);
  EXPECT_TRUE(HasReason(result, "brand_lookalike_host"));
}

TEST(PhishScoreTest, ShortenerIsContextNotStandaloneBlock) {
  const PhishAssessment result =
      AssessPhishingUrl(GURL("https://bit.ly/example"));

  EXPECT_EQ(result.score, 15);
  EXPECT_FALSE(result.should_block);
  EXPECT_TRUE(HasReason(result, "shortened_url"));
}

TEST(PhishScoreTest, DetectsBrandAndCredentialWordsInPath) {
  const PhishAssessment result =
      AssessPhishingUrl(GURL("https://example.com/paypal/login"));

  EXPECT_EQ(result.score, 25);
  EXPECT_TRUE(HasReason(result, "brand_in_path"));
  EXPECT_TRUE(HasReason(result, "credential_path"));
}

TEST(PhishScoreTest, AllowsOrdinaryHttpsUrl) {
  const PhishAssessment result =
      AssessPhishingUrl(GURL("https://example.com/docs"));

  EXPECT_EQ(result.score, 0);
  EXPECT_FALSE(result.should_block);
  EXPECT_TRUE(result.reasons.empty());
}

TEST(PhishScoreTest, PasswordOnRiskyOriginCrossesBlockThreshold) {
  PhishAssessment result = AssessPhishingUrl(GURL("http://evil.tk/login"));
  ASSERT_FALSE(result.should_block);

  result =
      ApplyPageSignals(std::move(result),
                       PageSignals{.title = "Login",
                                   .text_sample = "Enter password immediately",
                                   .password_fields = 1,
                                   .forms = 1});

  EXPECT_GE(result.score, kPhishBlockThreshold);
  EXPECT_TRUE(result.should_block);
  EXPECT_TRUE(HasReason(result, "password_on_risky_origin"));
}

TEST(PhishScoreTest, InvalidAssessmentCannotBeWeakenedByPageSignals) {
  PhishAssessment invalid = AssessPhishingUrl(GURL());
  const PhishAssessment result = ApplyPageSignals(
      invalid, PageSignals{.title = "Safe", .text_sample = "ordinary page"});

  EXPECT_EQ(result.score, 100);
  EXPECT_TRUE(result.should_block);
  EXPECT_EQ(result.reasons.size(), invalid.reasons.size());
  EXPECT_TRUE(HasReason(result, "invalid_url"));
}

TEST(PhishScoreTest, BlocksCrossSitePasswordSubmission) {
  PhishAssessment result = AssessPhishingUrl(GURL("https://example.com/login"));
  result = ApplyPageSignals(std::move(result),
                            PageSignals{.title = "Account login",
                                        .text_sample = "Enter your password",
                                        .password_fields = 1,
                                        .forms = 1,
                                        .cross_site_form_actions = 1});

  EXPECT_TRUE(result.should_block);
  EXPECT_TRUE(HasReason(result, "cross_site_credential_submit"));
}

TEST(PhishScoreTest, DomainFeedMatchNeedsCredentialEvidenceToBlock) {
  PhishAssessment domain_match;
  domain_match.score = 35;
  domain_match.reasons.push_back({"threat_feed_domain_match", 35, "CERT.PL"});

  PhishAssessment result = ApplyPageSignals(
      std::move(domain_match),
      PageSignals{.title = "Sign in", .password_fields = 1, .forms = 1});

  EXPECT_TRUE(result.should_block);
  EXPECT_TRUE(HasReason(result, "password_on_risky_origin"));
}

TEST(PhishScoreTest, BlocksPunycodePasswordPageWithoutUrgencyCopy) {
  PhishAssessment result = AssessPhishingUrl(GURL("https://xn--pple-43d.com/"));
  result = ApplyPageSignals(
      std::move(result),
      PageSignals{.title = "Sign in", .password_fields = 1, .forms = 1});

  EXPECT_GE(result.score, kPhishBlockThreshold);
  EXPECT_TRUE(result.should_block);
  EXPECT_TRUE(HasReason(result, "password_on_risky_origin"));
}

TEST(BuiltinPhishHostsTest, MatchesSeedHostAndPathWithoutSiblingFalsePositive) {
  EXPECT_TRUE(
      MatchesBuiltinPhishRule(GURL("https://paypal-secure-login.com/signin")));
  EXPECT_TRUE(MatchesBuiltinPhishRule(
      GURL("https://testsafebrowsing.appspot.com/s/phishing.html")));
  EXPECT_FALSE(MatchesBuiltinPhishRule(
      GURL("https://testsafebrowsing.appspot.com/s/malware.html")));
  EXPECT_FALSE(MatchesBuiltinPhishRule(
      GURL("https://paypal-secure-login.com.evil.example/signin")));
}

}  // namespace
}  // namespace aegis
