// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_core_log_share.h"

#include <sys/stat.h>

#include <atomic>
#include <cerrno>
#include <map>
#include <vector>

#include "base/barrier_closure.h"
#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "base/task/lazy_thread_pool_task_runner.h"
#include "third_party/zlib/google/compression_utils.h"

namespace aegis::access {
namespace {
base::LazyThreadPoolSequencedTaskRunner g_archive_runner =
    LAZY_THREAD_POOL_SEQUENCED_TASK_RUNNER_INITIALIZER(
        base::TaskTraits(base::MayBlock(),
                         base::TaskShutdownBehavior::BLOCK_SHUTDOWN));

bool IsOwnedDirectory(const base::FilePath& path) {
  struct stat info;
  return lstat(path.value().c_str(), &info) == 0 && S_ISDIR(info.st_mode) &&
         info.st_uid == geteuid();
}

bool RemoveOwnedArchive(const base::FilePath& path) {
  struct stat info;
  if (lstat(path.value().c_str(), &info) != 0)
    return errno == ENOENT;
  return S_ISDIR(info.st_mode) && info.st_uid == geteuid() &&
         (info.st_mode & 0777) == 0700 && base::DeletePathRecursively(path);
}

// Accessed only on g_archive_runner. There is one active archive per
// original profile, including its private browsing windows.
struct ArchiveState {
  bool recovered = false;
  bool active = false;

  bool Recover(const base::FilePath& profile) {
    if (!active && !recovered) {
      recovered = RecoverCoreLogArchives(profile);
      if (!recovered)
        LOG(WARNING) << "Could not recover abandoned Access log archives.";
    }
    return recovered;
  }
};

ArchiveState& StateForProfile(const base::FilePath& profile) {
  static base::NoDestructor<std::map<base::FilePath, ArchiveState>> states;
  return (*states)[profile];
}
}  // namespace

bool RecoverCoreLogArchives(const base::FilePath& profile) {
  if (!IsOwnedDirectory(profile))
    return false;
  base::FileEnumerator files(
      profile, false, base::FileEnumerator::FILES |
                          base::FileEnumerator::DIRECTORIES |
                          base::FileEnumerator::SHOW_SYM_LINKS,
      std::string(kCoreLogSharePrefix) + "??????",
      base::FileEnumerator::FolderSearchPolicy::MATCH_ONLY,
      base::FileEnumerator::ErrorPolicy::STOP_ENUMERATION);
  bool recovered = true;
  for (auto path = files.Next(); !path.empty(); path = files.Next()) {
    const auto name = path.BaseName().value();
    const std::string_view prefix(kCoreLogSharePrefix);
    if (!std::string_view(name).starts_with(prefix) || name.size() != prefix.size() + 6)
      continue;
    const auto suffix = std::string_view(name).substr(prefix.size());
    if (suffix.find_first_not_of(
            "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") != suffix.npos)
      continue;
    if (!RemoveOwnedArchive(path))
      recovered = false;
  }
  return recovered && files.GetError() == base::File::FILE_OK;
}

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
  base::FilePath Write(base::FilePath parent, std::string text, bool recover) {
    if (shutdown_->stop_requested())
      return {};
    if (recover) {
      auto& state = StateForProfile(parent);
      if (state.active)
        return {};
      cleanup_failed_ = !state.Recover(parent);
      if (cleanup_failed_)
        return {};
      state.active = true;
      profile_ = parent;
    }
    const bool created = directory_.CreateUniqueTempDirUnderPath(
        parent, kCoreLogSharePrefix);
    // mkdtemp creates a 0700 directory.
    if (!created || !WriteCoreLogArchive(directory_.GetPath(), text))
      return {};
    return directory_.GetPath().AppendASCII(kCoreLogArchive);
  }
  bool CleanUp() {
    const auto directory = directory_.Take();
    if (!directory.empty() && !RemoveOwnedArchive(directory)) {
      // Startup-style recovery on the same sequence retries this directory
      // before another copy can be made. Leave the path for that retry.
      cleanup_failed_ = true;
      LOG(WARNING) << "Could not delete the temporary Access log archive.";
    }
    if (!profile_.empty()) {
      auto& state = StateForProfile(profile_);
      state.recovered = !cleanup_failed_;
      state.active = false;
      profile_.clear();
    }
    return !cleanup_failed_;
  }

 private:
  std::shared_ptr<ShutdownHandle> shutdown_;
  base::FilePath profile_;
  base::ScopedTempDir directory_;
  bool cleanup_failed_ = false;
};

void CoreLogShareSession::ShutdownHandle::StopOnWriter() {
  if (writer_) writer_->CleanUp();
  CompleteStop();
}

CoreLogShareSession::CoreLogShareSession() = default;
CoreLogShareSession::~CoreLogShareSession() = default;

void CoreLogShareSession::RecoverAtStartup(const base::FilePath& profile) {
  g_archive_runner.Get()->PostTask(FROM_HERE, base::BindOnce(
      [](base::FilePath path) { StateForProfile(path).Recover(path); }, profile));
}

void CoreLogShareSession::Start(const base::FilePath& profile,
                               std::string preview,
                               Ready ready,
                               Cleanup cleanup) {
  StartOn(std::move(preview), std::move(ready), std::move(cleanup),
          g_archive_runner.Get(), profile, /*recover=*/true);
}

void CoreLogShareSession::StartForTesting(
    std::string preview,
    Ready ready,
    scoped_refptr<base::SequencedTaskRunner> runner,
    base::FilePath parent) {
  StartOn(std::move(preview), std::move(ready), Cleanup(), std::move(runner),
          std::move(parent), /*recover=*/false);
}

void CoreLogShareSession::StartOn(
    std::string preview,
    Ready ready,
    Cleanup cleanup,
    scoped_refptr<base::SequencedTaskRunner> runner,
    base::FilePath parent,
    bool recover) {
  if (shutting_down_ || writer_) {
    std::move(ready).Run({}, {});
    if (cleanup)
      std::move(cleanup).Run(true);
    return;
  }
  shutdown_ = std::make_shared<ShutdownHandle>(runner);
  auto& handles = ShutdownHandle::Registry();
  std::erase_if(handles, [](const auto& handle) { return handle.expired(); });
  handles.emplace_back(shutdown_);
  writer_.emplace(std::move(runner), shutdown_);
  writer_.AsyncCall(&Writer::Write)
      .WithArgs(std::move(parent), std::move(preview), recover)
      .Then(base::BindOnce(&CoreLogShareSession::OnWritten, weak_.GetWeakPtr(),
                           std::move(ready), std::move(cleanup)));
}

void CoreLogShareSession::OnWritten(Ready ready,
                                   Cleanup cleanup,
                                   base::FilePath path) {
  if (shutdown_->stop_requested()) {
    Finish();
    std::move(ready).Run({}, {});
    if (cleanup)
      std::move(cleanup).Run(true);
    return;
  }
  base::ScopedClosureRunner release(
      base::BindOnce(&CoreLogShareSession::Release, weak_.GetWeakPtr(),
                     std::move(cleanup)));
  std::move(ready).Run(std::move(path), std::move(release));
}

void CoreLogShareSession::Release(Cleanup cleanup) {
  writer_.AsyncCall(&Writer::CleanUp)
      .Then(base::BindOnce(
          [](base::WeakPtr<CoreLogShareSession> session, Cleanup done,
             bool cleaned) {
            if (!session)
              return;
            session->Finish();
            if (done)
              std::move(done).Run(cleaned);
          }, weak_.GetWeakPtr(), std::move(cleanup)));
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
