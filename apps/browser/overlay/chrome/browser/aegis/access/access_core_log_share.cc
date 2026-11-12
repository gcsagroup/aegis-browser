// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_core_log_share.h"

#include <sys/stat.h>

#include <atomic>
#include <vector>

#include "base/barrier_closure.h"
#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/task/thread_pool.h"
#include "third_party/zlib/google/compression_utils.h"

namespace aegis::access {
bool WriteCoreLogArchive(const base::FilePath& directory,
                         const std::string& text) {
  if (text.empty() || text.size() > 65536)
    return false;
  std::string gzip;
  if (!compression::GzipCompress(base::as_byte_span(text), &gzip))
    return false;
  base::File file(directory.AppendASCII(kCoreLogArchive),
                  base::File::FLAG_CREATE | base::File::FLAG_WRITE);
  return file.IsValid() && fchmod(file.GetPlatformFile(), 0600) == 0 &&
         file.WriteAtCurrentPosAndCheck(base::as_byte_span(gzip));
}

class CoreLogShareSession::ShutdownHandle
    : public std::enable_shared_from_this<ShutdownHandle> {
 public:
  explicit ShutdownHandle(scoped_refptr<base::SequencedTaskRunner> runner)
      : runner_(std::move(runner)) {}

  // Registry access stays on the owning Browser sequence. The writer keeps
  // this handle alive through queued construction and destruction.
  static std::vector<std::weak_ptr<ShutdownHandle>>& Registry() {
    static base::NoDestructor<std::vector<std::weak_ptr<ShutdownHandle>>> handles;
    return *handles;
  }
  bool stop_requested() const { return stop_requested_.load(); }
  void SetWriter(Writer* writer) { writer_ = writer; }  // Writer sequence only.

  void RequestStop(base::OnceClosure completion) {
    stop_requested_.store(true);
    bool stopped;
    {
      base::AutoLock guard(lock_);
      stopped = stopped_;
      if (!stopped) completions_.push_back(std::move(completion));
    }
    if (stopped) {
      std::move(completion).Run();
      return;
    }
    // If shutdown rejects the task, the BLOCK_SHUTDOWN writer's queued
    // destruction completes this same barrier.
    runner_->PostTask(FROM_HERE, base::BindOnce(
        [](std::shared_ptr<ShutdownHandle> handle) {
          handle->StopOnWriter();
        }, shared_from_this()));
  }

  void CompleteStop() {
    std::vector<base::OnceClosure> completions;
    {
      base::AutoLock guard(lock_);
      stopped_ = true;
      completions.swap(completions_);
    }
    for (auto& completion : completions) std::move(completion).Run();
  }

 private:
  void StopOnWriter();
  scoped_refptr<base::SequencedTaskRunner> runner_;
  raw_ptr<Writer> writer_ = nullptr;
  std::atomic_bool stop_requested_{false};
  base::Lock lock_;
  bool stopped_ GUARDED_BY(lock_) = false;
  std::vector<base::OnceClosure> completions_ GUARDED_BY(lock_);
};

class CoreLogShareSession::Writer {
 public:
  explicit Writer(std::shared_ptr<ShutdownHandle> shutdown)
      : shutdown_(std::move(shutdown)) {
    shutdown_->SetWriter(this);
  }
  ~Writer() {
    CleanUp();
    shutdown_->SetWriter(nullptr);
    shutdown_->CompleteStop();
  }
  base::FilePath Write(base::FilePath parent, std::string text) {
    if (shutdown_->stop_requested()) return {};
    const bool created = parent.empty()
                             ? directory_.CreateUniqueTempDir()
                             : directory_.CreateUniqueTempDirUnderPath(parent);
    // Both calls use mkdtemp on macOS, creating a 0700 directory.
    if (!created || !WriteCoreLogArchive(directory_.GetPath(), text))
      return {};
    return directory_.GetPath().AppendASCII(kCoreLogArchive);
  }
  void CleanUp() {
    if (directory_.IsValid()) {
      const bool deleted = directory_.Delete();
      (void)deleted;
    }
  }

 private:
  std::shared_ptr<ShutdownHandle> shutdown_;
  base::ScopedTempDir directory_;
};

void CoreLogShareSession::ShutdownHandle::StopOnWriter() {
  if (writer_) writer_->CleanUp();
  CompleteStop();
}

CoreLogShareSession::CoreLogShareSession() = default;
CoreLogShareSession::~CoreLogShareSession() = default;

void CoreLogShareSession::Start(std::string preview, Ready ready) {
  StartOn(std::move(preview), std::move(ready),
          base::ThreadPool::CreateSequencedTaskRunner(
              {base::MayBlock(), base::TaskShutdownBehavior::BLOCK_SHUTDOWN}),
          {});
}

void CoreLogShareSession::StartForTesting(
    std::string preview,
    Ready ready,
    scoped_refptr<base::SequencedTaskRunner> runner,
    base::FilePath parent) {
  StartOn(std::move(preview), std::move(ready), std::move(runner),
          std::move(parent));
}

void CoreLogShareSession::StartOn(
    std::string preview,
    Ready ready,
    scoped_refptr<base::SequencedTaskRunner> runner,
    base::FilePath parent) {
  if (shutting_down_ || writer_) {
    std::move(ready).Run({}, {});
    return;
  }
  shutdown_ = std::make_shared<ShutdownHandle>(runner);
  auto& handles = ShutdownHandle::Registry();
  std::erase_if(handles, [](const auto& handle) { return handle.expired(); });
  handles.emplace_back(shutdown_);
  writer_.emplace(std::move(runner), shutdown_);
  writer_.AsyncCall(&Writer::Write)
      .WithArgs(std::move(parent), std::move(preview))
      .Then(base::BindOnce(&CoreLogShareSession::OnWritten, weak_.GetWeakPtr(),
                           std::move(ready)));
}

void CoreLogShareSession::OnWritten(Ready ready, base::FilePath path) {
  if (shutdown_->stop_requested()) {
    Finish();
    std::move(ready).Run({}, {});
    return;
  }
  base::ScopedClosureRunner release(
      base::BindOnce(&CoreLogShareSession::Finish, weak_.GetWeakPtr()));
  std::move(ready).Run(std::move(path), std::move(release));
}

void CoreLogShareSession::Finish() {
  weak_.InvalidateWeakPtrs();
  writer_.Reset();
  shutdown_.reset();
}

void CoreLogShareSession::ShutDown() {
  shutting_down_ = true;
  // Called by Chrome's app-terminating notification while ThreadPool still
  // accepts work. Destruction is ordered behind any queued or running write
  // and blocks shutdown even if its UI reply or picker never completes.
  Finish();
}

void CoreLogShareSession::StopAllForSessionEnding(base::OnceClosure completion) {
  std::vector<std::shared_ptr<ShutdownHandle>> handles;
  for (auto& weak : ShutdownHandle::Registry()) {
    if (auto handle = weak.lock()) handles.push_back(std::move(handle));
  }
  if (handles.empty()) {
    std::move(completion).Run();
    return;
  }
  auto stopped = base::BarrierClosure(handles.size(), std::move(completion));
  for (auto& handle : handles) handle->RequestStop(base::OnceClosure(stopped));
}
}  // namespace aegis::access
