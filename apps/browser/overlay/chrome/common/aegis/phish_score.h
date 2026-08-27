// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/phish_score.h
// Mirrors packages/core/src/phish/detector.ts scorePhishingUrl().

#ifndef CHROME_COMMON_AEGIS_PHISH_SCORE_H_
#define CHROME_COMMON_AEGIS_PHISH_SCORE_H_

#include <string>
#include <vector>

class GURL;

namespace aegis {

inline constexpr int kPhishBlockThreshold = 55;

struct PhishReason {
  std::string code;
  int weight = 0;
  std::string detail;
};

struct PhishAssessment {
  int score = 0;
  bool should_block = false;
  std::vector<PhishReason> reasons;
};

struct PageSignals {
  std::string title;
  std::string text_sample;
  int password_fields = 0;
  int forms = 0;
  int cross_site_form_actions = 0;
};

// URL-only heuristic score (no page body). Seed-host matching is applied by
// the caller. |should_block| is true when score >= kPhishBlockThreshold.
PhishAssessment AssessPhishingUrl(const GURL& url);

// Adds page-body features (urgency copy, password forms) and a lightweight
// model nudge. Mirrors packages/core assessPhishing() + assessWithModel().
PhishAssessment ApplyPageSignals(PhishAssessment assessment,
                                 const PageSignals& page);

}  // namespace aegis

#endif  // CHROME_COMMON_AEGIS_PHISH_SCORE_H_
