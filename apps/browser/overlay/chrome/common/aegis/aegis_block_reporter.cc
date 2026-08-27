// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/aegis_block_reporter.cc

#include "chrome/common/aegis/aegis_block_reporter.h"

#include "base/check.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/task/bind_post_task.h"
#include "base/task/sequenced_task_runner.h"

namespace aegis {
namespace {

struct State {
  base::Lock lock;
  BlockReporter::BlockedCallback blocked;
  BlockReporter::ReferrerCallback referrer;
  BlockReporter::ParamsCallback params;
};

State& GetState() {
  static base::NoDestructor<State> state;
  return *state;
}

}  // namespace

// static
void BlockReporter::SetCallbacks(
    scoped_refptr<base::SequencedTaskRunner> task_runner,
    BlockedCallback blocked,
    ReferrerCallback referrer,
    ParamsCallback params) {
  CHECK(task_runner);
  CHECK(blocked);
  CHECK(referrer);
  CHECK(params);

  blocked = base::BindPostTask(task_runner, std::move(blocked));
  referrer = base::BindPostTask(task_runner, std::move(referrer));
  params = base::BindPostTask(task_runner, std::move(params));

  State& state = GetState();
  base::AutoLock lock(state.lock);
  state.blocked = std::move(blocked);
  state.referrer = std::move(referrer);
  state.params = std::move(params);
}

// static
void BlockReporter::ClearCallbacks() {
  State& state = GetState();
  base::AutoLock lock(state.lock);
  state.blocked.Reset();
  state.referrer.Reset();
  state.params.Reset();
}

// static
void BlockReporter::ReportBlocked(const GURL& url,
                                  const std::string& reason,
                                  const std::string& cname_alias,
                                  const std::string& source_site,
                                  const std::string& document_id) {
  BlockedCallback callback;
  {
    State& state = GetState();
    base::AutoLock lock(state.lock);
    callback = state.blocked;
  }
  if (callback) {
    callback.Run(url, reason, cname_alias, source_site, document_id);
  }
}

// static
void BlockReporter::ReportStrippedReferrer(const std::string& host,
                                           const std::vector<std::string>& keys,
                                           const std::string& source_site,
                                           const std::string& document_id) {
  ReferrerCallback callback;
  {
    State& state = GetState();
    base::AutoLock lock(state.lock);
    callback = state.referrer;
  }
  if (callback) {
    callback.Run(host, keys, source_site, document_id);
  }
}

// static
void BlockReporter::ReportStrippedParams(const std::string& host,
                                         const std::vector<std::string>& keys,
                                         const std::string& source_site,
                                         const std::string& document_id) {
  ParamsCallback callback;
  {
    State& state = GetState();
    base::AutoLock lock(state.lock);
    callback = state.params;
  }
  if (callback) {
    callback.Run(host, keys, source_site, document_id);
  }
}

}  // namespace aegis
