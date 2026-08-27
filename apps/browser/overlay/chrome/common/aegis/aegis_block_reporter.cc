// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/aegis_block_reporter.cc

#include "chrome/common/aegis/aegis_block_reporter.h"

#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "url/gurl.h"

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
void BlockReporter::SetBlockedCallback(BlockedCallback callback) {
  State& state = GetState();
  base::AutoLock lock(state.lock);
  state.blocked = std::move(callback);
}

// static
void BlockReporter::SetReferrerCallback(ReferrerCallback callback) {
  State& state = GetState();
  base::AutoLock lock(state.lock);
  state.referrer = std::move(callback);
}

// static
void BlockReporter::SetParamsCallback(ParamsCallback callback) {
  State& state = GetState();
  base::AutoLock lock(state.lock);
  state.params = std::move(callback);
}

// static
void BlockReporter::ReportBlocked(const GURL& url,
                                  const std::string& reason,
                                  const std::string& cname_alias) {
  BlockedCallback callback;
  {
    State& state = GetState();
    base::AutoLock lock(state.lock);
    callback = state.blocked;
  }
  if (callback) {
    callback.Run(url, reason, cname_alias);
  }
}

// static
void BlockReporter::ReportStrippedReferrer(
    const std::string& host,
    const std::vector<std::string>& keys) {
  ReferrerCallback callback;
  {
    State& state = GetState();
    base::AutoLock lock(state.lock);
    callback = state.referrer;
  }
  if (callback) {
    callback.Run(host, keys);
  }
}

// static
void BlockReporter::ReportStrippedParams(const std::string& host,
                                         const std::vector<std::string>& keys) {
  ParamsCallback callback;
  {
    State& state = GetState();
    base::AutoLock lock(state.lock);
    callback = state.params;
  }
  if (callback) {
    callback.Run(host, keys);
  }
}

}  // namespace aegis
