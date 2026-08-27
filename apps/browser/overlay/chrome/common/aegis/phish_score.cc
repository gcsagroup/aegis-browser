// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/phish_score.cc
// Keep in lockstep with packages/core/src/phish/detector.ts scorePhishingUrl().

#include "chrome/common/aegis/phish_score.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <string_view>
#include <vector>

#include "base/containers/span.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/gurl.h"

namespace aegis {
namespace {

#include "chrome/common/aegis/generated/phish_brand_keywords.inc"
#include "chrome/common/aegis/generated/suspicious_phish_tlds.inc"

bool HasSuspiciousTld(std::string_view tld) {
  for (std::string_view candidate : kSuspiciousPhishTlds) {
    if (base::EqualsCaseInsensitiveASCII(candidate, tld)) {
      return true;
    }
  }
  return false;
}

constexpr std::string_view kShortenerHosts[] = {
    "bit.ly", "buff.ly",    "cutt.ly",     "is.gd", "ow.ly",
    "rb.gy",  "rebrand.ly", "shorturl.at", "t.co",  "tinyurl.com",
};

constexpr std::string_view kCredentialPathWords[] = {
    "account", "auth",   "confirm", "login",  "password",
    "secure",  "signin", "verify",  "wallet",
};

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

std::string NormalizeLookalike(std::string_view label) {
  std::string normalized(label);
  for (char& c : normalized) {
    switch (c) {
      case '0':
        c = 'o';
        break;
      case '1':
        c = 'i';
        break;
      case '3':
        c = 'e';
        break;
      case '4':
        c = 'a';
        break;
      case '5':
        c = 's';
        break;
      case '7':
        c = 't';
        break;
      default:
        break;
    }
  }
  return normalized;
}

bool IsEditDistanceAtMostOne(std::string_view left, std::string_view right) {
  if (left.size() > right.size() + 1 || right.size() > left.size() + 1) {
    return false;
  }
  size_t left_index = 0;
  size_t right_index = 0;
  int edits = 0;
  while (left_index < left.size() && right_index < right.size()) {
    if (left[left_index] == right[right_index]) {
      ++left_index;
      ++right_index;
      continue;
    }
    if (++edits > 1) {
      return false;
    }
    if (left.size() > right.size()) {
      ++left_index;
    } else if (right.size() > left.size()) {
      ++right_index;
    } else {
      ++left_index;
      ++right_index;
    }
  }
  if (left_index < left.size() || right_index < right.size()) {
    ++edits;
  }
  return edits <= 1;
}

std::string RegistrableLabel(std::string_view host) {
  std::string registrable =
      net::registry_controlled_domains::GetDomainAndRegistry(
          std::string(host),
          net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  if (!registrable.empty()) {
    return registrable.substr(0, registrable.find('.'));
  }
  const std::vector<std::string_view> labels = base::SplitStringPiece(
      host, ".", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  return labels.empty()
             ? std::string()
             : std::string(labels.size() >= 2 ? *std::next(labels.rbegin())
                                              : labels.back());
}

struct BrandHostMatch {
  std::string brand;
  std::string reason;
};

BrandHostMatch BrandSpoofInHost(std::string_view host) {
  const std::vector<std::string_view> labels = base::SplitStringPiece(
      host, ".", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (labels.empty()) {
    return BrandHostMatch();
  }
  const std::string sld = RegistrableLabel(host);
  for (std::string_view brand : kPhishBrandKeywords) {
    if (sld == brand) {
      continue;
    }
    for (std::string_view label : labels) {
      if (LabelSpoofsBrand(label, brand)) {
        return {std::string(brand), "brand_spoof_host"};
      }
    }
    if (brand.size() < 5) {
      continue;
    }
    for (std::string_view label : labels) {
      if (label.size() < 5 || label == brand) {
        continue;
      }
      const std::string normalized = NormalizeLookalike(label);
      if (normalized == brand || IsEditDistanceAtMostOne(normalized, brand)) {
        return {std::string(brand), "brand_lookalike_host"};
      }
    }
  }
  return BrandHostMatch();
}

std::string FindToken(std::string_view value,
                      base::span<const std::string_view> candidates) {
  const std::vector<std::string_view> tokens = base::SplitStringPiece(
      value, "/-_.", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  for (std::string_view candidate : candidates) {
    if (std::ranges::find(tokens, candidate) != tokens.end()) {
      return std::string(candidate);
    }
  }
  return std::string();
}

std::string BrandInPath(std::string_view path, std::string_view host) {
  const std::string sld = RegistrableLabel(host);
  const std::vector<std::string_view> tokens = base::SplitStringPiece(
      path, "/-_.", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  for (std::string_view brand : kPhishBrandKeywords) {
    if (brand != sld && std::ranges::find(tokens, brand) != tokens.end()) {
      return std::string(brand);
    }
  }
  return std::string();
}

bool IsShortenerHost(std::string_view host) {
  return std::ranges::find(kShortenerHosts, host) != std::end(kShortenerHosts);
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

  const BrandHostMatch spoof = BrandSpoofInHost(host);
  if (!spoof.brand.empty()) {
    const int weight = spoof.reason == "brand_lookalike_host" ? 40 : 30;
    score += weight;
    out.reasons.push_back({spoof.reason, weight, spoof.brand});
  }

  const std::string path = base::ToLowerASCII(url.path());
  const std::string path_brand = BrandInPath(path, host);
  if (!path_brand.empty()) {
    score += 15;
    out.reasons.push_back({"brand_in_path", 15, path_brand});
  }
  const std::string credential_word = FindToken(path, kCredentialPathWords);
  if (!credential_word.empty()) {
    score += 10;
    out.reasons.push_back({"credential_path", 10, credential_word});
  }
  if (IsShortenerHost(host)) {
    score += 15;
    out.reasons.push_back({"shortened_url", 15, host});
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
    "verify your account",
    "confirm your identity",
    "suspend",
    "unusual activity",
    "act now",
    "password expired",
    "login immediately",
    "账户异常",
    "立即验证",
    "密码过期",
    "異常登入",
    "立即驗證",
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
                     HasReason(assessment, "brand_lookalike_host") ||
                     HasReason(assessment, "ip_hostname") ||
                     HasReason(assessment, "insecure_http") ||
                     HasReason(assessment, "punycode_host") ||
                     HasReason(assessment, "threat_feed_domain_match");
  if (page.password_fields > 0 && page.cross_site_form_actions > 0) {
    score += 45;
    assessment.reasons.push_back(
        {"cross_site_credential_submit", 45,
         base::StrCat({"crossSiteForms=",
                       base::NumberToString(page.cross_site_form_actions)})});
  } else if (page.password_fields > 0 && risky) {
    const int weight = HasReason(assessment, "punycode_host") ? 30 : 25;
    score += weight;
    assessment.reasons.push_back(
        {"password_on_risky_origin", weight,
         base::StrCat(
             {"passwordFields=", base::NumberToString(page.password_fields)})});
  } else if (page.password_fields > 0 && page.forms > 0 && score >= 20) {
    score += 12;
    assessment.reasons.push_back({"credential_form", 12, std::string()});
  }

  if (page.password_fields > 0 && !HasReason(assessment, "brand_spoof_host") &&
      !HasReason(assessment, "brand_lookalike_host")) {
    for (std::string_view brand : kPhishBrandKeywords) {
      if (haystack.find(brand) != std::string::npos) {
        score += 15;
        assessment.reasons.push_back(
            {"brand_credential_page", 15, std::string(brand)});
        break;
      }
    }
  }

  score = std::min(100, score);
  const int nudge = LightweightNudge(haystack);
  if (nudge > 0) {
    const int blended =
        std::min(100, static_cast<int>(std::round(score + nudge * 0.3)));
    assessment.reasons.push_back(
        {"lightweight_model_blend", nudge, std::string()});
    score = blended;
  }

  assessment.score = score;
  assessment.should_block = score >= kPhishBlockThreshold;
  return assessment;
}

}  // namespace aegis
