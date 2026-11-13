// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_STORE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_STORE_H_

#include "build/build_config.h"
#if BUILDFLAG(IS_MAC)
#include "base/functional/callback.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/aegis/access/access_core_log_disk.h"
#endif
#include "base/memory/ref_counted.h"
#include "base/synchronization/lock.h"
#include "chrome/browser/aegis/access/access_core_log.h"

namespace aegis::access {
// Shared only by one profile scope's UI and local proxy worker.
class AccessCoreLogStore
    : public base::RefCountedThreadSafe<AccessCoreLogStore> {
 public:
  AccessCoreLogStore();
#if BUILDFLAG(IS_MAC)
  enum class DiskStatus { kLoading, kReady, kClearing, kError };
  static scoped_refptr<AccessCoreLogStore> Open(const base::FilePath& profile,
                                                CoreLogProfile scope,
                                                std::string_view level);
  // Call after core writers stop. Completes on the disk sequence after all
  // queued saves/deletions, without a reply to the blocked Browser sequence.
  static void FlushAllForSessionEnding(base::OnceClosure completion);
  DiskStatus disk_status();
#endif
  void SetLevel(std::string_view level);
  std::string Level() {
    base::AutoLock guard(lock_);
    return std::string(log_.level());
  }
  std::pair<std::string, uint64_t> LaunchConfig() {
    base::AutoLock guard(lock_);
    return {std::string(log_.level()), generation_};
  }
  void Add(uint64_t generation,
           std::string_view line,
           const std::vector<std::string>& protected_values);
  std::string Snapshot() {
    base::AutoLock guard(lock_);
    return log_.Snapshot();
  }
  uint64_t view_version() {
    base::AutoLock guard(lock_);
    return view_version_;
  }
  std::pair<std::string, uint64_t> ViewSnapshot() {
    base::AutoLock guard(lock_);
    return {log_.Snapshot(), view_version_};
  }
  bool CanShare(uint64_t version) {
    base::AutoLock guard(lock_);
    return version == view_version_ && log_.level() != "none";
  }
  void Clear();

 private:
  friend class base::RefCountedThreadSafe<AccessCoreLogStore>;
  ~AccessCoreLogStore();
  base::Lock lock_;
#if BUILDFLAG(IS_MAC)
  void Restore(uint64_t epoch);
  void ScheduleSaveLocked();
  void ScheduleClearLocked();
  void Flush(uint64_t epoch, bool clear);
  scoped_refptr<base::SequencedTaskRunner> disk_runner_;
  base::FilePath profile_;
  CoreLogProfile scope_ = CoreLogProfile::kRegular;
  uint64_t disk_epoch_ GUARDED_BY(lock_) = 0;
  bool save_pending_ GUARDED_BY(lock_) = false;
  DiskStatus disk_status_ GUARDED_BY(lock_) = DiskStatus::kReady;
#endif
  uint64_t view_version_ GUARDED_BY(lock_) = 0;
  uint64_t generation_ GUARDED_BY(lock_) = 0;
  AccessCoreLog log_ GUARDED_BY(lock_);
};
}  // namespace aegis::access
#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_CORE_LOG_STORE_H_
