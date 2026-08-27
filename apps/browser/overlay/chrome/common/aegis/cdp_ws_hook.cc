// Copyright 2026 GCSA
// Intended path: chrome/common/aegis/cdp_ws_hook.cc

#include "chrome/common/aegis/cdp_ws_hook.h"

#include "base/no_destructor.h"
#include "base/synchronization/lock.h"

namespace aegis {
namespace {

struct State {
  base::Lock lock;
  CdpWsHook::ClientCountCallback callback;
};

State& GetState() {
  static base::NoDestructor<State> state;
  return *state;
}

}  // namespace

// static
void CdpWsHook::SetClientCountCallback(ClientCountCallback callback) {
  State& state = GetState();
  base::AutoLock lock(state.lock);
  state.callback = std::move(callback);
}

// static
void CdpWsHook::NotifyClientCount(size_t count) {
  ClientCountCallback callback;
  {
    State& state = GetState();
    base::AutoLock lock(state.lock);
    callback = state.callback;
  }
  if (callback) {
    callback.Run(count);
  }
}

}  // namespace aegis
