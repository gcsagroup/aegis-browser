// Copyright 2026 GCSA

#include "chrome/common/aegis/miner_guard_reporter.h"

#include "base/check.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"

namespace aegis {
namespace {

struct ReporterState {
  base::Lock lock;
  MinerGuardReporter::SignalsCallback callback;
};

ReporterState& GetReporterState() {
  static base::NoDestructor<ReporterState> state;
  return *state;
}

}  // namespace

void MinerGuardReporter::SetCallback(
    scoped_refptr<base::SequencedTaskRunner> task_runner,
    SignalsCallback callback) {
  CHECK(task_runner);
  CHECK(callback);
  callback = base::BindPostTask(task_runner, std::move(callback));
  ReporterState& state = GetReporterState();
  base::AutoLock lock(state.lock);
  state.callback = std::move(callback);
}

void MinerGuardReporter::ClearCallback() {
  ReporterState& state = GetReporterState();
  base::AutoLock lock(state.lock);
  state.callback.Reset();
}

void MinerGuardReporter::ReportSignals(const std::string& document_id,
                                       const std::string& site_key,
                                       const std::string& display_domain,
                                       const MinerRuntimeSignals& signals) {
  SignalsCallback callback;
  {
    ReporterState& state = GetReporterState();
    base::AutoLock lock(state.lock);
    callback = state.callback;
  }
  if (callback) {
    callback.Run(document_id, site_key, display_domain, signals);
  }
}

}  // namespace aegis
