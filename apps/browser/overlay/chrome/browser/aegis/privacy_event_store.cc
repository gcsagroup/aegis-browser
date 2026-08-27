// Copyright 2026 GCSA

#include "chrome/browser/aegis/privacy_event_store.h"

#include <algorithm>
#include <utility>

namespace aegis {

PrivacyEventStore::PrivacyEventStore() = default;
PrivacyEventStore::~PrivacyEventStore() = default;

void PrivacyEventStore::Record(PrivacyEvent event) {
  event.count = std::max(1, event.count);
  if (event.last_unix_seconds == 0) {
    event.last_unix_seconds = event.first_unix_seconds;
  }
  if (event.first_unix_seconds == 0) {
    event.first_unix_seconds = event.last_unix_seconds;
  }

  auto existing = std::find_if(events_.begin(), events_.end(),
                               [&event](const PrivacyEvent& candidate) {
                                 return SameGroup(candidate, event);
                               });
  if (existing != events_.end() &&
      event.last_unix_seconds >= existing->last_unix_seconds &&
      event.last_unix_seconds - existing->last_unix_seconds <=
          kAggregationWindowSeconds) {
    PrivacyEvent merged = std::move(*existing);
    events_.erase(existing);
    merged.count += event.count;
    merged.last_unix_seconds = event.last_unix_seconds;
    MergeDetails(event.details, &merged.details);
    events_.push_front(std::move(merged));
  } else {
    if (event.details.size() > kMaxDetails) {
      event.details.resize(kMaxDetails);
    }
    events_.push_front(std::move(event));
  }

  EnforceLimits(events_.front().document_id);
}

void PrivacyEventStore::Clear() {
  events_.clear();
}

std::vector<PrivacyEvent> PrivacyEventStore::Recent() const {
  return {events_.begin(), events_.end()};
}

std::vector<PrivacyEvent> PrivacyEventStore::ForDocumentAndSite(
    const std::string& document_id,
    const std::string& site_key) const {
  std::vector<PrivacyEvent> result;
  for (const PrivacyEvent& event : events_) {
    const bool same_document =
        !document_id.empty() && event.document_id == document_id;
    const bool site_scoped = event.document_id.empty() && !site_key.empty() &&
                             event.site_key == site_key;
    if (same_document || site_scoped) {
      result.push_back(event);
    }
  }
  return result;
}

// static
bool PrivacyEventStore::SameGroup(const PrivacyEvent& left,
                                  const PrivacyEvent& right) {
  return left.document_id == right.document_id &&
         left.site_key == right.site_key && left.kind == right.kind &&
         left.reason == right.reason &&
         left.display_domain == right.display_domain;
}

// static
void PrivacyEventStore::MergeDetails(const std::vector<std::string>& incoming,
                                     std::vector<std::string>* existing) {
  for (const std::string& detail : incoming) {
    if (existing->size() >= kMaxDetails) {
      return;
    }
    if (std::ranges::find(*existing, detail) == existing->end()) {
      existing->push_back(detail);
    }
  }
}

void PrivacyEventStore::EnforceLimits(const std::string& document_id) {
  if (!document_id.empty()) {
    size_t document_count = 0;
    for (auto it = events_.begin(); it != events_.end();) {
      if (it->document_id != document_id) {
        ++it;
        continue;
      }
      ++document_count;
      if (document_count > kMaxEventsPerDocument) {
        it = events_.erase(it);
      } else {
        ++it;
      }
    }
  }
  while (events_.size() > kMaxEventsTotal) {
    events_.pop_back();
  }
}

}  // namespace aegis
