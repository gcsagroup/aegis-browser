// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/policy_worker.h

#ifndef CHROME_BROWSER_AEGIS_POLICY_WORKER_H_
#define CHROME_BROWSER_AEGIS_POLICY_WORKER_H_

#include <atomic>
#include <memory>
#include <string>

#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/singleton.h"
#include "base/memory/weak_ptr.h"
#include "base/synchronization/lock.h"
#include "base/threading/thread.h"
#include "v8/include/v8-persistent-handle.h"

namespace base {
class SequencedTaskRunner;
}

namespace gin {
class IsolateHolder;
}

namespace v8 {
class Context;
class Isolate;
}  // namespace v8

namespace aegis {

// Runs the bundled packages/core JS (policy_worker.js) in a dedicated gin
// isolate. Fast-path C++ throttles stay in charge; this is the slow path for
// Privacy AI and remaining TypeScript policy.
class PolicyWorker {
 public:
  using EvaluateCallback = base::OnceCallback<void(std::string json)>;

  static PolicyWorker* GetInstance();

  PolicyWorker(const PolicyWorker&) = delete;
  PolicyWorker& operator=(const PolicyWorker&) = delete;

  void Start();
  bool ready() const { return ready_.load(std::memory_order_acquire); }
  std::string last_error() const;

  // |request_json| is a {"op": "...", ...} payload understood by
  // packages/core/src/policy-worker-entry.ts. Reply is posted back to the
  // caller's sequence.
  void Evaluate(std::string request_json, EvaluateCallback done);

 private:
  friend struct base::DefaultSingletonTraits<PolicyWorker>;
  PolicyWorker();
  ~PolicyWorker();

  void InitOnWorker();
  void ShutdownOnWorker();
  void EvaluateOnWorker(std::string request_json,
                        scoped_refptr<base::SequencedTaskRunner> reply,
                        EvaluateCallback done);
  std::string RunEvaluate(const std::string& request_json);
  void SetLastError(std::string error);

  std::unique_ptr<base::Thread> thread_;
  std::unique_ptr<gin::IsolateHolder> isolate_holder_;
  v8::Global<v8::Context> context_;
  std::atomic_bool ready_{false};
  mutable base::Lock status_lock_;
  std::string last_error_ GUARDED_BY(status_lock_);
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_POLICY_WORKER_H_
