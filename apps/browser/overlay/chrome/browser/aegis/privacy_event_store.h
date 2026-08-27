// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_PRIVACY_EVENT_STORE_H_
#define CHROME_BROWSER_AEGIS_PRIVACY_EVENT_STORE_H_

#include <cstdint>
#include <deque>
#include <string>
#include <vector>

namespace aegis {

struct PrivacyEvent {
  std::string document_id;
  std::string site_key;
  std::string kind;
  std::string reason;
  std::string display_domain;
  std::vector<std::string> details;
  int count = 1;
  int64_t first_unix_seconds = 0;
  int64_t last_unix_seconds = 0;
};

// Keeps a small, session-only record of user-visible privacy actions. Events
// are grouped before UI observers are notified so request bursts cannot cause
// unbounded storage or one repaint per request.
class PrivacyEventStore {
 public:
  static constexpr size_t kMaxEventsPerDocument = 50;
  static constexpr size_t kMaxEventsTotal = 200;
  static constexpr int64_t kAggregationWindowSeconds = 1;
  static constexpr size_t kMaxDetails = 8;

  PrivacyEventStore();
  PrivacyEventStore(const PrivacyEventStore&) = delete;
  PrivacyEventStore& operator=(const PrivacyEventStore&) = delete;
  ~PrivacyEventStore();

  void Record(PrivacyEvent event);
  void Clear();

  std::vector<PrivacyEvent> Recent() const;
  std::vector<PrivacyEvent> ForDocumentAndSite(
      const std::string& document_id,
      const std::string& site_key) const;

 private:
  static bool SameGroup(const PrivacyEvent& left, const PrivacyEvent& right);
  static void MergeDetails(const std::vector<std::string>& incoming,
                           std::vector<std::string>* existing);
  void EnforceLimits(const std::string& document_id);

  std::deque<PrivacyEvent> events_;
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_PRIVACY_EVENT_STORE_H_
