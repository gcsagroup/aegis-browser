// Copyright 2026 GCSA

#include "chrome/browser/aegis/privacy_event_store.h"

#include <string>

#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

PrivacyEvent Event(std::string document,
                   std::string site,
                   std::string kind,
                   std::string domain,
                   int64_t time) {
  PrivacyEvent event;
  event.document_id = std::move(document);
  event.site_key = std::move(site);
  event.kind = std::move(kind);
  event.reason = "easylist";
  event.display_domain = std::move(domain);
  event.first_unix_seconds = time;
  event.last_unix_seconds = time;
  return event;
}

TEST(PrivacyEventStoreTest, AggregatesOnlyWithinSameDocumentAndWindow) {
  PrivacyEventStore store;
  store.Record(Event("doc-a", "example.test", "block", "tracker.test", 10));
  store.Record(Event("doc-a", "example.test", "block", "tracker.test", 11));
  store.Record(Event("doc-b", "example.test", "block", "tracker.test", 11));
  store.Record(Event("doc-a", "example.test", "block", "tracker.test", 13));

  const auto recent = store.Recent();
  ASSERT_EQ(3u, recent.size());
  EXPECT_EQ(1, recent[0].count);
  EXPECT_EQ("doc-a", recent[0].document_id);
  EXPECT_EQ(1, recent[1].count);
  EXPECT_EQ("doc-b", recent[1].document_id);
  EXPECT_EQ(2, recent[2].count);
}

TEST(PrivacyEventStoreTest, FiltersDocumentAndSiteScopedEvents) {
  PrivacyEventStore store;
  store.Record(Event("doc-a", "a.test", "block", "tracker.test", 10));
  store.Record(Event("doc-b", "a.test", "param", "a.test", 10));
  store.Record(Event("", "a.test", "cookie", "a.test", 10));
  store.Record(Event("", "b.test", "cookie", "b.test", 10));

  const auto page = store.ForDocumentAndSite("doc-a", "a.test");
  ASSERT_EQ(2u, page.size());
  EXPECT_EQ("cookie", page[0].kind);
  EXPECT_EQ("block", page[1].kind);
}

TEST(PrivacyEventStoreTest, BoundsDetailsAndEvents) {
  PrivacyEventStore store;
  for (size_t i = 0; i < PrivacyEventStore::kMaxEventsPerDocument + 5; ++i) {
    PrivacyEvent event =
        Event("doc-a", "a.test", "block", "tracker" + std::to_string(i),
              static_cast<int64_t>(i));
    for (size_t detail = 0; detail < PrivacyEventStore::kMaxDetails + 5;
         ++detail) {
      event.details.push_back("key" + std::to_string(detail));
    }
    store.Record(std::move(event));
  }

  const auto recent = store.Recent();
  ASSERT_EQ(PrivacyEventStore::kMaxEventsPerDocument, recent.size());
  EXPECT_EQ(PrivacyEventStore::kMaxDetails, recent.front().details.size());
}

}  // namespace
}  // namespace aegis
