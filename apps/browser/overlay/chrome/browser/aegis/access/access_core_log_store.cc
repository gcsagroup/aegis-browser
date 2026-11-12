// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_core_log_store.h"

#if BUILDFLAG(IS_MAC)
#include "base/functional/bind.h"
#include "base/strings/string_split.h"
#include "base/task/lazy_thread_pool_task_runner.h"
#endif

namespace aegis::access {
AccessCoreLogStore::AccessCoreLogStore() = default;
AccessCoreLogStore::~AccessCoreLogStore() = default;

void AccessCoreLogStore::SetLevel(std::string_view level) {
  base::AutoLock guard(lock_);
  ++view_version_;
  if (level == "none")
    ++generation_;
  log_.SetLevel(level);
#if BUILDFLAG(IS_MAC)
  if (level == "none")
    ScheduleClearLocked();
  else
    ScheduleSaveLocked();
#endif
}
void AccessCoreLogStore::Add(uint64_t generation,
                             std::string_view line,
                             const std::vector<std::string>& protected_values) {
  base::AutoLock guard(lock_);
  if (generation != generation_ || !log_.Add(line, protected_values))
    return;
#if BUILDFLAG(IS_MAC)
  ScheduleSaveLocked();
#endif
}
void AccessCoreLogStore::Clear() {
  base::AutoLock guard(lock_);
  ++view_version_;
  log_.Clear();
#if BUILDFLAG(IS_MAC)
  ScheduleClearLocked();
#endif
}

#if BUILDFLAG(IS_MAC)
namespace {
// A shared sequence also orders disk access across closing and reopened
// profile windows at the same path.
base::LazyThreadPoolSequencedTaskRunner g_log_disk =
    LAZY_THREAD_POOL_SEQUENCED_TASK_RUNNER_INITIALIZER(
        base::TaskTraits(base::MayBlock(),
                         base::TaskShutdownBehavior::BLOCK_SHUTDOWN));
void ReadSanitizedLines(AccessCoreLog& log, std::string_view text) {
  for (auto line : base::SplitStringPiece(text, "\n", base::KEEP_WHITESPACE,
                                          base::SPLIT_WANT_NONEMPTY)) {
    if (line.size() <= 4096)
      log.Add(line);
  }
}
}  // namespace

void AccessCoreLogStore::FlushAllForSessionEnding(base::OnceClosure completion) {
  // SessionEnding terminates directly, without ThreadPool shutdown. Its
  // bounded rundown must also wait for an already-requested history deletion.
  g_log_disk.Get()->PostTask(FROM_HERE, std::move(completion));
}

scoped_refptr<AccessCoreLogStore> AccessCoreLogStore::Open(
    const base::FilePath& profile,
    CoreLogProfile scope,
    std::string_view level) {
  auto store = base::MakeRefCounted<AccessCoreLogStore>();
  base::AutoLock guard(store->lock_);
  store->profile_ = profile;
  store->scope_ = scope;
  store->disk_runner_ = g_log_disk.Get();
  store->log_.SetLevel(level);
  if (store->log_.level() == "none") {
    store->ScheduleClearLocked();
  } else {
    store->disk_status_ = DiskStatus::kLoading;
    if (!store->disk_runner_->PostTask(
            FROM_HERE, base::BindOnce(&AccessCoreLogStore::Restore, store,
                                      store->disk_epoch_)))
      store->disk_status_ = DiskStatus::kError;
  }
  return store;
}
AccessCoreLogStore::DiskStatus AccessCoreLogStore::disk_status() {
  base::AutoLock guard(lock_);
  return disk_status_;
}
void AccessCoreLogStore::Restore(uint64_t epoch) {
  std::string stored;
  bool ok = ReadCoreLogHistory(profile_, scope_, &stored);
  base::AutoLock guard(lock_);
  if (epoch != disk_epoch_)
    return;
  disk_status_ = ok ? DiskStatus::kReady : DiskStatus::kError;
  if (!ok || stored.empty())
    return;
  // Preserve entries accepted while the read was outstanding. Parse all disk
  // bytes through the same bounded sanitizer used for fresh child records.
  std::string fresh = log_.Snapshot();
  log_.Clear();
  ReadSanitizedLines(log_, stored);
  ReadSanitizedLines(log_, fresh);
}
void AccessCoreLogStore::ScheduleSaveLocked() {
  lock_.AssertAcquired();
  if (!disk_runner_ || save_pending_)
    return;
  save_pending_ = true;
  if (!disk_runner_->PostTask(
          FROM_HERE,
          base::BindOnce(&AccessCoreLogStore::Flush, base::WrapRefCounted(this),
                         disk_epoch_, false))) {
    save_pending_ = false;
    disk_status_ = DiskStatus::kError;
  }
}
void AccessCoreLogStore::ScheduleClearLocked() {
  lock_.AssertAcquired();
  if (!disk_runner_)
    return;
  ++disk_epoch_;
  save_pending_ = false;
  disk_status_ = DiskStatus::kClearing;
  if (!disk_runner_->PostTask(
          FROM_HERE,
          base::BindOnce(&AccessCoreLogStore::Flush, base::WrapRefCounted(this),
                         disk_epoch_, true)))
    disk_status_ = DiskStatus::kError;
}
void AccessCoreLogStore::Flush(uint64_t epoch, bool clear) {
  std::string text;
  {
    base::AutoLock guard(lock_);
    if (epoch != disk_epoch_)
      return;
    if (!clear) {
      save_pending_ = false;
      text = log_.Snapshot();
    }
  }
  const bool ok = SaveCoreLogHistory(profile_, scope_, text);
  base::AutoLock guard(lock_);
  if (epoch == disk_epoch_)
    disk_status_ = ok ? DiskStatus::kReady : DiskStatus::kError;
}
#endif
}  // namespace aegis::access
