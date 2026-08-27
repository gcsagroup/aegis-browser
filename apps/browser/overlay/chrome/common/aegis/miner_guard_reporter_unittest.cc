// Copyright 2026 GCSA

#include "chrome/common/aegis/miner_guard_reporter.h"

#include <string>

#include "base/functional/bind.h"
#include "base/run_loop.h"
#include "base/test/task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {
namespace {

TEST(MinerGuardReporterTest, DeliversBoundedSignalsOnOwnerSequence) {
  base::test::TaskEnvironment task_environment;
  base::RunLoop run_loop;
  std::string received_document;
  MinerRuntimeSignals received_signals;
  MinerGuardReporter::SetCallback(
      base::SequencedTaskRunner::GetCurrentDefault(),
      base::BindRepeating(
          [](base::RepeatingClosure quit, std::string* received_document,
             MinerRuntimeSignals* received_signals, std::string document_id,
             std::string site_key, std::string display_domain,
             MinerRuntimeSignals signals) {
            *received_document = std::move(document_id);
            *received_signals = signals;
            quit.Run();
          },
          run_loop.QuitClosure(), &received_document, &received_signals));

  MinerRuntimeSignals signals;
  signals.worker = true;
  signals.wasm = true;
  MinerGuardReporter::ReportSignals("document-1", "example.test",
                                    "example.test", signals);
  run_loop.Run();

  EXPECT_EQ(received_document, "document-1");
  EXPECT_TRUE(received_signals.worker);
  EXPECT_TRUE(received_signals.wasm);
  MinerGuardReporter::ClearCallback();
}

TEST(MinerGuardReporterTest, DropsReportsAfterClear) {
  base::test::TaskEnvironment task_environment;
  bool called = false;
  MinerGuardReporter::SetCallback(
      base::SequencedTaskRunner::GetCurrentDefault(),
      base::BindRepeating(
          [](bool* called, std::string, std::string, std::string,
             MinerRuntimeSignals) { *called = true; },
          &called));
  MinerGuardReporter::ClearCallback();
  MinerGuardReporter::ReportSignals("document-1", "example.test",
                                    "example.test", MinerRuntimeSignals());
  task_environment.RunUntilIdle();
  EXPECT_FALSE(called);
}

}  // namespace
}  // namespace aegis
