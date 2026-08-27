// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/phish_score.cc
// Keep in lockstep with packages/core/src/phish/detector.ts scorePhishingUrl().

#include "chrome/common/aegis/phish_score.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <string_view>
#include <vector>

#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "url/gurl.h"

namespace aegis {
namespace {

#include "chrome/common/aegis/generated/suspicious_phish_tlds.inc"
#include "chrome/common/aegis/generated/phish_brand_keywords.inc"

bool HasSuspiciousTld(std::string_view tld) {
  for (std::string_view candidate : kSuspiciousPhishTlds) {
    if (base::EqualsCaseInsensitiveASCII(candidate, tld)) {
      return true;
    }
  }
  return false;
}

bool LabelSpoofsBrand(std::string_view label, std::string_view brand) {
  if (label == brand) {
    return true;
  }
  if (base::StartsWith(label, base::StrCat({brand, "-"}))) {
    return true;
  }
  if (base::EndsWith(label, base::StrCat({"-", brand}))) {
    return true;
  }
  return label.find(base::StrCat({"-", brand, "-"})) != std::string_view::npos;
}

std::string BrandSpoofInHost(std::string_view host) {
  const std::vector<std::string_view> labels = base::SplitStringPiece(
      host, ".", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (labels.empty()) {
    return std::string();
  }
  const std::string_view sld =
      labels.size() >= 2 ? *std::next(labels.rbegin()) : labels.back();
  for (std::string_view brand : kPhishBrandKeywords) {
    if (sld == brand) {
      continue;
    }
    for (std::string_view label : labels) {
      if (LabelSpoofsBrand(label, brand)) {
        return std::string(brand);
      }
    }
  }
  return std::string();
}

}  // namespace

PhishAssessment AssessPhishingUrl(const GURL& url) {
  PhishAssessment out;
  if (!url.is_valid()) {
    out.score = 100;
    out.should_block = true;
    out.reasons.push_back({"invalid_url", 100, url.possibly_invalid_spec()});
    return out;
  }

  const std::string host = base::ToLowerASCII(url.host());
  int score = 0;

  if (url.SchemeIs("http")) {
    score += 12;
    out.reasons.push_back({"insecure_http", 12, std::string()});
  }

  if (url.HostIsIPAddress()) {
    score += 35;
    out.reasons.push_back({"ip_hostname", 35, host});
  }

  if (host.find("xn--") != std::string::npos) {
    score += 25;
    out.reasons.push_back({"punycode_host", 25, host});
  }

  const std::vector<std::string_view> labels = base::SplitStringPiece(
      host, ".", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (labels.size() >= 5) {
    score += 15;
    out.reasons.push_back({"deep_subdomain", 15, host});
  }

  if (!labels.empty()) {
    const std::string_view tld = labels.back();
    if (HasSuspiciousTld(tld)) {
      score += 18;
      out.reasons.push_back({"suspicious_tld", 18, std::string(tld)});
    }
  }

  const std::string spoof = BrandSpoofInHost(host);
  if (!spoof.empty()) {
    score += 30;
    out.reasons.push_back({"brand_spoof_host", 30, spoof});
  }

  const std::string spec = url.possibly_invalid_spec();
  if (url.has_username() || spec.find('@') != std::string::npos) {
    score += 20;
    out.reasons.push_back({"at_symbol_trick", 20, std::string()});
  }

  out.score = std::min(100, score);
  out.should_block = out.score >= kPhishBlockThreshold;
  return out;
}

namespace {

constexpr std::string_view kUrgencyPhrases[] = {
    "verify your account", "confirm your identity", "suspend",
    "unusual activity",    "act now",               "password expired",
    "login immediately",   "账户异常",              "立即验证",
    "密码过期",            "異常登入",              "立即驗證",
};

bool HasReason(const PhishAssessment& assessment, std::string_view code) {
  for (const PhishReason& reason : assessment.reasons) {
    if (reason.code == code) {
      return true;
    }
  }
  return false;
}

int LightweightNudge(std::string_view haystack) {
  int nudge = 0;
  if (haystack.find("password") != std::string_view::npos ||
      haystack.find("passwd") != std::string_view::npos ||
      haystack.find("验证码") != std::string_view::npos ||
      haystack.find("驗證") != std::string_view::npos ||
      haystack.find("otp") != std::string_view::npos ||
      haystack.find("wallet") != std::string_view::npos ||
      haystack.find("seed phrase") != std::string_view::npos) {
    nudge += 8;
  }
  if (haystack.find("urgent") != std::string_view::npos ||
      haystack.find("immediately") != std::string_view::npos ||
      haystack.find("suspend") != std::string_view::npos ||
      haystack.find("立即") != std::string_view::npos ||
      haystack.find("異常") != std::string_view::npos ||
      haystack.find("异常") != std::string_view::npos) {
    nudge += 6;
  }
  return nudge;
}

}  // namespace

PhishAssessment ApplyPageSignals(PhishAssessment assessment,
                                 const PageSignals& page) {
  if (HasReason(assessment, "allowlisted") ||
      HasReason(assessment, "invalid_url")) {
    return assessment;
  }

  int score = assessment.score;
  const std::string haystack =
      base::ToLowerASCII(page.title + "\n" + page.text_sample);

  for (std::string_view phrase : kUrgencyPhrases) {
    if (haystack.find(base::ToLowerASCII(phrase)) != std::string::npos) {
      score += 10;
      assessment.reasons.push_back(
          {"urgency_language", 10, std::string(phrase)});
      break;
    }
  }

  const bool risky = HasReason(assessment, "brand_spoof_host") ||
                     HasReason(assessment, "ip_hostname") ||
                     HasReason(assessment, "insecure_http");
  if (page.password_fields > 0 && risky) {
    score += 25;
    assessment.reasons.push_back(
        {"password_on_risky_origin", 25,
         base::StrCat({"passwordFields=",
                       base::NumberToString(page.password_fields)})});
  } else if (page.password_fields > 0 && page.forms > 0 && score >= 20) {
    score += 12;
    assessment.reasons.push_back({"credential_form", 12, std::string()});
  }

  score = std::min(100, score);
  const int nudge = LightweightNudge(haystack);
  if (nudge > 0) {
    const int blended =
        std::min(100, static_cast<int>(std::round(score + nudge * 0.3)));
    assessment.reasons.push_back({"lightweight_model_blend", nudge, std::string()});
    score = blended;
  }

  assessment.score = score;
  assessment.should_block = score >= kPhishBlockThreshold;
  return assessment;
}

}  // namespace aegis
