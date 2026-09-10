// Copyright 2026 GCSA

#include "chrome/common/aegis/phish_score.h"

#include <string_view>
#include <utility>

#include "base/strings/utf_string_conversion_utils.h"
#include "chrome/common/aegis/builtin_phish_hosts.h"
#include "chrome/common/aegis/security_text.h"
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

TEST(PhishScoreTest, RemovesEveryUnicodeTagWithoutDecodingInstructions) {
  for (int codepoint = 0xe0000; codepoint <= 0xe007f; ++codepoint) {
    std::string salted = "ver";
    base::WriteUnicodeCharacter(codepoint, &salted);
    salted += "ify your account";
    const SecurityText normalized = NormalizeSecurityText(salted);
    EXPECT_TRUE(normalized.valid_utf8);
    EXPECT_EQ(normalized.text, "verify your account");
    EXPECT_EQ(normalized.removed_hidden_codepoints, 1u);
  }
  EXPECT_EQ(NormalizeSecurityText("\U000e0072\U000e0075\U000e006e").text, "");
  EXPECT_FALSE(NormalizeSecurityText(std::string("\xff", 1)).valid_utf8);
}

TEST(PhishScoreTest, PreservesLegitimateUnicodeAndOnlyExactSubdivisionFlags) {
  for (const std::string& flag :
       {std::string("\U0001f3f4\U000e0067\U000e0062\U000e0065\U000e006e"
                    "\U000e0067\U000e007f"),
        std::string("\U0001f3f4\U000e0067\U000e0062\U000e0073\U000e0063"
                    "\U000e0074\U000e007f"),
        std::string("\U0001f3f4\U000e0067\U000e0062\U000e0077\U000e006c"
                    "\U000e0073\U000e007f")}) {
    EXPECT_EQ(NormalizeSecurityText(flag).text, flag);
    EXPECT_EQ(NormalizeSecurityText(flag).removed_hidden_codepoints, 0u);
    EXPECT_EQ(NormalizeSecurityText(flag + "\U000e0078").text, flag);
  }
  const std::string legitimate =
      "中文 café العربية می\u200cروم \U0001f469\u200d\U0001f4bb \u2764\ufe0f";
  EXPECT_EQ(NormalizeSecurityText(legitimate).text, legitimate);
  EXPECT_EQ(NormalizeSecurityText(
                "\U0001f3f4\U000e0072\U000e0075\U000e006e\U000e007f")
                .text,
            "\U0001f3f4");
  EXPECT_EQ(NormalizeSecurityText("pass\u200bword\u2060\u00ad\ufeff").text,
            "password");
  EXPECT_EQ(NormalizeSecurityText("verify\u00a0your\u202faccount").text,
            "verify your account");
}

TEST(PhishScoreTest, InvisibleSaltingCannotWeakenPageDetection) {
  const PhishAssessment url = AssessPhishingUrl(GURL("http://example.test/"));
  PageSignals plain{.title = "PayPal",
                    .text_sample = "verify your account",
                    .password_fields = 1,
                    .forms = 1};
  const PhishAssessment baseline = ApplyPageSignals(url, plain);
  ASSERT_TRUE(baseline.should_block);
  plain.title = "Pay\U000e0020Pal";
  plain.text_sample = "ver\U000e0020ify your acc\u200bount";
  const PhishAssessment salted = ApplyPageSignals(url, plain);
  EXPECT_EQ(salted.score, baseline.score);
  EXPECT_TRUE(salted.should_block);
  EXPECT_TRUE(HasReason(salted, "unicode_text_obfuscation"));
  EXPECT_TRUE(HasReason(salted, "urgency_language"));
  EXPECT_TRUE(HasReason(salted, "brand_credential_page"));
  const PhishAssessment benign = ApplyPageSignals(
      AssessPhishingUrl(GURL("https://example.test/")),
      PageSignals{.title = "研究", .text_sample = "普通\U000e0020文本"});
  EXPECT_FALSE(benign.should_block);
  EXPECT_EQ(benign.score, 0);
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
