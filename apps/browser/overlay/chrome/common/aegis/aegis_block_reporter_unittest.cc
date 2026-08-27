// Copyright 2026 GCSA

#include "chrome/common/aegis/aegis_block_reporter.h"

#include <memory>
#include <string>
#include <vector>

#include "base/barrier_closure.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/run_loop.h"
#include "base/synchronization/waitable_event.h"
#include "base/task/sequenced_task_runner.h"
#include "base/test/task_environment.h"
#include "base/threading/thread.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace aegis {
namespace {

struct BlockedEvent {
  GURL url;
  std::string reason;
  std::string cname_alias;
  std::string source_site;
  std::string document_id;
};

class ReportRecorder {
 public:
  ReportRecorder(scoped_refptr<base::SequencedTaskRunner> owner_runner,
                 base::RepeatingClosure on_report)
      : owner_runner_(std::move(owner_runner)),
        on_report_(std::move(on_report)) {}

  void OnBlocked(GURL url,
                 std::string reason,
                 std::string alias,
                 std::string source_site,
                 std::string document_id) {
    EXPECT_TRUE(owner_runner_->RunsTasksInCurrentSequence());
    blocked_events.push_back({std::move(url), std::move(reason),
                              std::move(alias), std::move(source_site),
                              std::move(document_id)});
    on_report_.Run();
  }

  void OnReferrer(std::string host,
                  std::vector<std::string> keys,
                  std::string source_site,
                  std::string document_id) {
    EXPECT_TRUE(owner_runner_->RunsTasksInCurrentSequence());
    referrer_host = std::move(host);
    referrer_keys = std::move(keys);
    last_source_site = std::move(source_site);
    last_document_id = std::move(document_id);
    on_report_.Run();
  }

  void OnParams(std::string host,
                std::vector<std::string> keys,
                std::string source_site,
                std::string document_id) {
    EXPECT_TRUE(owner_runner_->RunsTasksInCurrentSequence());
    params_host = std::move(host);
    params_keys = std::move(keys);
    last_source_site = std::move(source_site);
    last_document_id = std::move(document_id);
    on_report_.Run();
  }

  base::WeakPtr<ReportRecorder> GetWeakPtr() {
    return weak_ptr_factory_.GetWeakPtr();
  }

  std::vector<BlockedEvent> blocked_events;
  std::string referrer_host;
  std::vector<std::string> referrer_keys;
  std::string params_host;
  std::vector<std::string> params_keys;
  std::string last_source_site;
  std::string last_document_id;

 private:
  scoped_refptr<base::SequencedTaskRunner> owner_runner_;
  base::RepeatingClosure on_report_;
  base::WeakPtrFactory<ReportRecorder> weak_ptr_factory_{this};
};

class WeakReportTarget {
 public:
  explicit WeakReportTarget(bool* called) : called_(called) {}

  void OnBlocked(GURL, std::string, std::string, std::string, std::string) {
    *called_ = true;
  }
  void OnReferrer(std::string,
                  std::vector<std::string>,
                  std::string,
                  std::string) {
    *called_ = true;
  }

  base::WeakPtr<WeakReportTarget> GetWeakPtr() {
    return weak_ptr_factory_.GetWeakPtr();
  }

 private:
  raw_ptr<bool> called_;
  base::WeakPtrFactory<WeakReportTarget> weak_ptr_factory_{this};
};

class BlockReporterTest : public testing::Test {
 protected:
  void SetUp() override { ASSERT_TRUE(worker_.Start()); }

  void TearDown() override {
    BlockReporter::ClearCallbacks();
    worker_.Stop();
    task_environment_.RunUntilIdle();
  }

  base::test::TaskEnvironment task_environment_;
  base::Thread worker_{"AegisBlockReporterWorker"};
};

TEST_F(BlockReporterTest, DeliversReportsOnRegistrationSequence) {
  const auto owner_runner = base::SequencedTaskRunner::GetCurrentDefault();
  base::RunLoop run_loop;
  base::RepeatingClosure on_report =
      base::BarrierClosure(4, run_loop.QuitClosure());
  ReportRecorder recorder(owner_runner, std::move(on_report));

  BlockReporter::SetCallbacks(
      owner_runner,
      base::BindRepeating(&ReportRecorder::OnBlocked, recorder.GetWeakPtr()),
      base::BindRepeating(&ReportRecorder::OnReferrer, recorder.GetWeakPtr()),
      base::BindRepeating(&ReportRecorder::OnParams, recorder.GetWeakPtr()));

  ASSERT_TRUE(worker_.task_runner()->PostTask(
      FROM_HERE, base::BindOnce([] {
        BlockReporter::ReportBlocked(
            GURL("https://static.cloudflareinsights.com/beacon.min.js"),
            "easylist", "", "shop.example", "doc-1");
        BlockReporter::ReportBlocked(GURL("https://metrics.shop.example/pixel"),
                                     "cname", "stats.doubleclick.net",
                                     "shop.example", "doc-1");
        BlockReporter::ReportStrippedReferrer("referrer.example",
                                              {"utm_source", "gclid"},
                                              "shop.example", "doc-1");
        BlockReporter::ReportStrippedParams("destination.example", {"fbclid"},
                                            "shop.example", "doc-1");
      })));
  run_loop.Run();

  ASSERT_EQ(recorder.blocked_events.size(), 2u);
  EXPECT_EQ(recorder.blocked_events[0].url,
            GURL("https://static.cloudflareinsights.com/beacon.min.js"));
  EXPECT_EQ(recorder.blocked_events[0].reason, "easylist");
  EXPECT_TRUE(recorder.blocked_events[0].cname_alias.empty());
  EXPECT_EQ(recorder.blocked_events[1].url,
            GURL("https://metrics.shop.example/pixel"));
  EXPECT_EQ(recorder.blocked_events[1].reason, "cname");
  EXPECT_EQ(recorder.blocked_events[1].cname_alias, "stats.doubleclick.net");
  EXPECT_EQ(recorder.blocked_events[1].source_site, "shop.example");
  EXPECT_EQ(recorder.blocked_events[1].document_id, "doc-1");
  EXPECT_EQ(recorder.referrer_host, "referrer.example");
  EXPECT_EQ(recorder.referrer_keys,
            (std::vector<std::string>{"utm_source", "gclid"}));
  EXPECT_EQ(recorder.params_host, "destination.example");
  EXPECT_EQ(recorder.params_keys, (std::vector<std::string>{"fbclid"}));
  EXPECT_EQ(recorder.last_source_site, "shop.example");
  EXPECT_EQ(recorder.last_document_id, "doc-1");
}

TEST_F(BlockReporterTest, DropsQueuedReportsAfterTargetDestruction) {
  bool called = false;
  auto target = std::make_unique<WeakReportTarget>(&called);
  BlockReporter::SetCallbacks(
      base::SequencedTaskRunner::GetCurrentDefault(),
      base::BindRepeating(&WeakReportTarget::OnBlocked, target->GetWeakPtr()),
      base::BindRepeating(&WeakReportTarget::OnReferrer, target->GetWeakPtr()),
      base::BindRepeating(&WeakReportTarget::OnReferrer, target->GetWeakPtr()));

  base::WaitableEvent report_queued;
  ASSERT_TRUE(worker_.task_runner()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WaitableEvent* queued) {
                       BlockReporter::ReportBlocked(
                           GURL("https://tracker.example/script.js"),
                           "easylist", "");
                       queued->Signal();
                     },
                     base::Unretained(&report_queued))));
  report_queued.Wait();

  target.reset();
  BlockReporter::ClearCallbacks();
  task_environment_.RunUntilIdle();

  EXPECT_FALSE(called);
}

}  // namespace
}  // namespace aegis
