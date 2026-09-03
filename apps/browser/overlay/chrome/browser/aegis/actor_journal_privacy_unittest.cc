// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <cstddef>
#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/test/mock_log.h"
#include "base/test/scoped_logging_settings.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "base/time/time.h"
#include "chrome/browser/actor/tools/wait_tool_request.h"
#include "chrome/browser/actor/ui/event_dispatcher.h"
#include "chrome/browser/actor/ui/test_support/mock_actor_ui_state_manager.h"
#include "chrome/common/actor/action_result.h"
#include "components/actor/core/aggregated_journal.h"
#include "components/actor/core/aggregated_journal_in_memory_serializer.h"
#include "components/actor/core/journal_details_builder.h"
#include "components/optimization_guide/proto/features/actions_data.pb.h"
#include "components/tabs/public/tab_interface.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace actor {
namespace {

constexpr char kPrivateEventName[] = "ActorEvent";
constexpr char kSensitiveToolRequestEvent[] = "SensitiveToolRequestEvent";

class SensitiveWaitToolRequest : public WaitToolRequest {
 public:
  SensitiveWaitToolRequest() : WaitToolRequest(base::Milliseconds(1)) {}

  std::string JournalEvent() const override {
    return kSensitiveToolRequestEvent;
  }
};

size_t EntryCount(const AggregatedJournal& journal) {
  size_t count = 0;
  for (auto it = journal.Items(); it; ++it) {
    ++count;
  }
  return count;
}

class ActorJournalPrivacyTest : public testing::Test {
 private:
  base::test::TaskEnvironment task_environment_;
};

TEST_F(ActorJournalPrivacyTest,
       PrivateModeSanitizesBeforeRetentionAndObservers) {
  constexpr char kUrl[] = "https://private.example/secret-url";
  constexpr char kEvent[] = "SensitiveDynamicEvent";
  constexpr char kDetailKey[] = "sensitive-detail-key";
  constexpr char kDetailValue[] = "sensitive-detail-value";
  constexpr char kRendererEvent[] = "SensitiveRendererEvent";
  constexpr char kProtoType[] = "SensitiveProtoType";
  constexpr char kProtoValue[] = "sensitive-proto-value";
  constexpr char kScreenshot[] = "sensitive-screenshot-bytes";
  constexpr char kIframeScreenshot[] = "sensitive-iframe-bytes";
  constexpr char kPageContent[] = "sensitive-apc-bytes";

  AggregatedJournal journal(AggregatedJournal::Mode::kPrivate);
  AggregatedJournalInMemorySerializer serializer(journal,
                                                 /*max_bytes=*/1024 * 1024);
  serializer.Init();

  const uint64_t async_track = journal.AllocateDynamicTrackUUID();
  auto pending_entry = journal.CreatePendingAsyncEntry(
      GURL(kUrl), TaskId(7), async_track, kEvent,
      JournalDetailsBuilder().Add(kDetailKey, kDetailValue).Build());
  EXPECT_EQ(kPrivateEventName, pending_entry->event_name());

  journal.Log(GURL(kUrl), TaskId(7), journal.AllocateDynamicTrackUUID(), kEvent,
              JournalDetailsBuilder().Add(kDetailKey, kDetailValue).Build());

  optimization_guide::proto::Actions actions;
  actions.mutable_task_metadata()
      ->mutable_security()
      ->add_added_writable_mainframe_origins(kProtoValue);
  std::string serialized_proto;
  ASSERT_TRUE(actions.SerializeToString(&serialized_proto));
  const std::string encoded_proto = base::Base64Encode(serialized_proto);
  journal.LogProto(
      GURL(kUrl), TaskId(7), journal.AllocateDynamicTrackUUID(), kEvent,
      JournalDetailsBuilder().Add(kDetailKey, kDetailValue).Build(), actions,
      kProtoType);

  std::vector<mojom::JournalEntryPtr> renderer_entries;
  renderer_entries.push_back(mojom::JournalEntry::New(
      mojom::JournalEntryType::kInstant, TaskId(7), base::Time::Now(),
      kRendererEvent, journal.AllocateDynamicTrackUUID(),
      JournalDetailsBuilder().Add(kDetailKey, kDetailValue).Build()));
  journal.AppendJournalEntries(GURL(kUrl), std::move(renderer_entries));

  journal.LogScreenshot(GURL(kUrl), TaskId(7), "image/png",
                        base::byte_span_from_cstring(kScreenshot),
                        base::byte_span_from_cstring(kIframeScreenshot));
  journal.LogAnnotatedPageContent(GURL(kUrl), TaskId(7),
                                  base::byte_span_from_cstring(kPageContent));
  pending_entry->EndEntry(
      JournalDetailsBuilder().Add(kDetailKey, kDetailValue).Build());

  EXPECT_EQ(5u, EntryCount(journal));
  for (auto it = journal.Items(); it; ++it) {
    const AggregatedJournal::Entry& entry = ***it;
    EXPECT_TRUE(entry.url.empty());
    EXPECT_FALSE(entry.screenshot.has_value());
    EXPECT_FALSE(entry.iframe_screenshot.has_value());
    EXPECT_FALSE(entry.annotated_page_content.has_value());
    ASSERT_TRUE(entry.data);
    EXPECT_EQ(kPrivateEventName, entry.data->event);
    EXPECT_TRUE(entry.data->details.empty());
  }

  const std::vector<uint8_t> snapshot = serializer.Snapshot();
  ASSERT_FALSE(snapshot.empty());
  const std::string trace(snapshot.begin(), snapshot.end());
  for (std::string_view secret :
       {kUrl, kEvent, kDetailKey, kDetailValue, kRendererEvent, kProtoType,
        kProtoValue, kScreenshot, kIframeScreenshot, kPageContent}) {
    EXPECT_EQ(std::string::npos, trace.find(secret)) << secret;
  }
  EXPECT_EQ(std::string::npos, trace.find(encoded_proto));
}

TEST_F(ActorJournalPrivacyTest, PrivateModeOmitsSensitiveVlogFields) {
  if (!VLOG_IS_ON(0)) {
    GTEST_SKIP() << "Runtime VLOG filtering is not available in this build.";
  }

  constexpr char kUrl[] = "https://private.example/vlog-secret";
  constexpr char kEvent[] = "SensitiveVlogEvent";
  constexpr char kDetailKey[] = "sensitive-vlog-key";
  constexpr char kDetail[] = "sensitive-vlog-detail";

  logging::ScopedVmoduleSwitches vmodule_switches;
  vmodule_switches.InitWithSwitches("*aggregated_journal*=1");

  std::vector<std::string> actor_messages;
  base::test::MockLog mock_log;
  EXPECT_CALL(mock_log,
              Log(testing::_, testing::_, testing::_, testing::_, testing::_))
      .Times(testing::AnyNumber())
      .WillRepeatedly([&actor_messages](int, const char* file, int, size_t,
                                        const std::string& message) {
        if (std::string_view(file).find("aggregated_journal.cc") !=
            std::string_view::npos) {
          actor_messages.push_back(message);
        }
        return true;
      });
  mock_log.StartCapturingLogs();

  AggregatedJournal journal(AggregatedJournal::Mode::kPrivate);
  auto pending_entry = journal.CreatePendingAsyncEntry(
      GURL(kUrl), TaskId(8), journal.AllocateDynamicTrackUUID(), kEvent,
      JournalDetailsBuilder().Add(kDetailKey, kDetail).Build());
  journal.Log(GURL(kUrl), TaskId(8), kEvent,
              JournalDetailsBuilder().Add(kDetailKey, kDetail).Build());
  pending_entry->EndEntry(
      JournalDetailsBuilder().Add(kDetailKey, kDetail).Build());

  mock_log.StopCapturingLogs();
  ASSERT_FALSE(actor_messages.empty());
  for (const std::string& message : actor_messages) {
    EXPECT_EQ(std::string::npos, message.find(kUrl));
    EXPECT_EQ(std::string::npos, message.find(kEvent));
    EXPECT_EQ(std::string::npos, message.find(kDetailKey));
    EXPECT_EQ(std::string::npos, message.find(kDetail));
    EXPECT_NE(std::string::npos, message.find(kPrivateEventName));
  }
}

TEST_F(ActorJournalPrivacyTest, PrivateUiDispatcherOmitsSensitiveVlogFields) {
  if (!VLOG_IS_ON(0)) {
    GTEST_SKIP() << "Runtime VLOG filtering is not available in this build.";
  }

  constexpr char kSensitiveTaskTitle[] = "Sensitive Incognito task title";

  logging::ScopedVmoduleSwitches vmodule_switches;
  vmodule_switches.InitWithSwitches("*event_dispatcher*=4");

  std::vector<std::string> actor_messages;
  base::test::MockLog mock_log;
  EXPECT_CALL(mock_log,
              Log(testing::_, testing::_, testing::_, testing::_, testing::_))
      .Times(testing::AnyNumber())
      .WillRepeatedly([&actor_messages](int, const char* file, int, size_t,
                                        const std::string& message) {
        if (std::string_view(file).find("event_dispatcher.cc") !=
            std::string_view::npos) {
          actor_messages.push_back(message);
        }
        return true;
      });
  mock_log.StartCapturingLogs();

  ui::MockActorUiStateManager state_manager;
  EXPECT_CALL(state_manager, OnUiEvent(testing::A<ui::SyncUiEvent>())).Times(1);
  std::unique_ptr<ui::UiEventDispatcher> private_dispatcher =
      ui::NewUiEventDispatcher(&state_manager,
                               /*suppress_sensitive_logging=*/true);

  SensitiveWaitToolRequest sensitive_request;
  base::test::TestFuture<mojom::ActionResultPtr> private_result;
  private_dispatcher->OnPostTool(sensitive_request,
                                 private_result.GetCallback());
  EXPECT_TRUE(IsOk(*private_result.Get()));
  private_dispatcher->OnActorTaskSyncChange(ui::UiEventDispatcher::StopTask{
      .task_id = TaskId(10),
      .final_state = ActorTask::State::kFinished,
      .title = kSensitiveTaskTitle,
      .last_acted_on_tab_handle = tabs::TabHandle(10)});

  std::unique_ptr<ui::UiEventDispatcher> standard_dispatcher =
      ui::NewUiEventDispatcher(&state_manager,
                               /*suppress_sensitive_logging=*/false);
  WaitToolRequest standard_request(base::Milliseconds(1));
  base::test::TestFuture<mojom::ActionResultPtr> standard_result;
  standard_dispatcher->OnPostTool(standard_request,
                                  standard_result.GetCallback());
  EXPECT_TRUE(IsOk(*standard_result.Get()));

  mock_log.StopCapturingLogs();
  ASSERT_FALSE(actor_messages.empty());
  for (const std::string& message : actor_messages) {
    EXPECT_EQ(std::string::npos, message.find(kSensitiveToolRequestEvent));
    EXPECT_EQ(std::string::npos, message.find(kSensitiveTaskTitle));
  }
}

TEST_F(ActorJournalPrivacyTest, DefaultModePreservesStandardFields) {
  constexpr char kUrl[] = "https://example.test/standard";
  constexpr char kEvent[] = "StandardEvent";
  constexpr char kDetailKey[] = "standard-key";
  constexpr char kDetailValue[] = "standard-value";
  constexpr char kProtoValue[] = "standard-proto-value";
  constexpr char kScreenshot[] = "standard-screenshot-bytes";
  constexpr char kIframeScreenshot[] = "standard-iframe-bytes";
  constexpr char kPageContent[] = "standard-apc-bytes";

  AggregatedJournal journal;
  EXPECT_FALSE(journal.is_private());
  journal.Log(GURL(kUrl), TaskId(9), kEvent,
              JournalDetailsBuilder().Add(kDetailKey, kDetailValue).Build());

  optimization_guide::proto::Actions actions;
  actions.mutable_task_metadata()
      ->mutable_security()
      ->add_added_writable_mainframe_origins(kProtoValue);
  std::string serialized_proto;
  ASSERT_TRUE(actions.SerializeToString(&serialized_proto));
  journal.LogProto(GURL(kUrl), TaskId(9), "StandardProtoEvent", {}, actions,
                   "StandardProtoType");
  journal.LogScreenshot(GURL(kUrl), TaskId(9), "image/png",
                        base::byte_span_from_cstring(kScreenshot),
                        base::byte_span_from_cstring(kIframeScreenshot));
  journal.LogAnnotatedPageContent(GURL(kUrl), TaskId(9),
                                  base::byte_span_from_cstring(kPageContent));

  EXPECT_EQ(4u, EntryCount(journal));

  auto it = journal.Items();
  ASSERT_TRUE(it);
  const AggregatedJournal::Entry& log_entry = ***it;
  EXPECT_EQ(kUrl, log_entry.url);
  ASSERT_TRUE(log_entry.data);
  EXPECT_EQ(kEvent, log_entry.data->event);
  ASSERT_EQ(1u, log_entry.data->details.size());
  EXPECT_EQ(kDetailKey, log_entry.data->details[0]->key);
  EXPECT_EQ(kDetailValue, log_entry.data->details[0]->value);

  ++it;
  ASSERT_TRUE(it);
  const AggregatedJournal::Entry& proto_entry = ***it;
  EXPECT_EQ(kUrl, proto_entry.url);
  ASSERT_TRUE(proto_entry.data);
  EXPECT_EQ("StandardProtoEvent", proto_entry.data->event);
  ASSERT_EQ(2u, proto_entry.data->details.size());
  EXPECT_EQ("proto_type", proto_entry.data->details[0]->key);
  EXPECT_EQ("StandardProtoType", proto_entry.data->details[0]->value);
  EXPECT_EQ("proto", proto_entry.data->details[1]->key);
  EXPECT_EQ(base::Base64Encode(serialized_proto),
            proto_entry.data->details[1]->value);

  ++it;
  ASSERT_TRUE(it);
  const AggregatedJournal::Entry& screenshot_entry = ***it;
  EXPECT_EQ(kUrl, screenshot_entry.url);
  ASSERT_TRUE(screenshot_entry.screenshot.has_value());
  ASSERT_TRUE(screenshot_entry.iframe_screenshot.has_value());
  EXPECT_EQ(kScreenshot, std::string(screenshot_entry.screenshot->begin(),
                                     screenshot_entry.screenshot->end()));
  EXPECT_EQ(kIframeScreenshot,
            std::string(screenshot_entry.iframe_screenshot->begin(),
                        screenshot_entry.iframe_screenshot->end()));

  ++it;
  ASSERT_TRUE(it);
  const AggregatedJournal::Entry& page_content_entry = ***it;
  EXPECT_EQ(kUrl, page_content_entry.url);
  ASSERT_TRUE(page_content_entry.annotated_page_content.has_value());
  EXPECT_EQ(kPageContent,
            std::string(page_content_entry.annotated_page_content->begin(),
                        page_content_entry.annotated_page_content->end()));
}

}  // namespace
}  // namespace actor
