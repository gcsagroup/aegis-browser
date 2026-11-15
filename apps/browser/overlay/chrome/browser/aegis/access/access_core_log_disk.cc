// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_core_log_disk.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/posix/eintr_wrapper.h"
#include "base/strings/string_view_util.h"

namespace aegis::access {
namespace {
constexpr size_t kMaxHistoryBytes = 64 * 1024;
const char* Name(CoreLogProfile scope) {
  return scope == CoreLogProfile::kPrivate ? "private.log" : "regular.log";
}
const char* Pending(CoreLogProfile scope) {
  return scope == CoreLogProfile::kPrivate ? ".private.pending"
                                           : ".regular.pending";
}
enum class OpenResult { kOk, kMissing, kError };
OpenResult OpenDirectory(const base::FilePath& profile,
                         bool create,
                         base::ScopedFD* directory) {
  constexpr int flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
  base::ScopedFD parent(HANDLE_EINTR(open(profile.value().c_str(), flags)));
  if (!parent.is_valid())
    return OpenResult::kError;
  if (create && mkdirat(parent.get(), kCoreLogDirectory, 0700) < 0 &&
      errno != EEXIST)
    return OpenResult::kError;
  directory->reset(
      HANDLE_EINTR(openat(parent.get(), kCoreLogDirectory, flags)));
  if (!directory->is_valid())
    return errno == ENOENT ? OpenResult::kMissing : OpenResult::kError;
  struct stat info;
  if (fstat(directory->get(), &info) != 0 || info.st_uid != geteuid() ||
      (info.st_mode & 0777) != 0700)
    return OpenResult::kError;
  return OpenResult::kOk;
}
bool Remove(int dir, const char* file) {
  return unlinkat(dir, file, 0) == 0 || errno == ENOENT;
}
bool IsPrivateFile(const struct stat& info) {
  return S_ISREG(info.st_mode) && info.st_uid == geteuid() &&
         (info.st_mode & 0777) == 0600 && info.st_nlink == 1;
}
}  // namespace

bool ReadCoreLogHistory(const base::FilePath& profile,
                        CoreLogProfile scope,
                        std::string* history) {
  history->clear();
  base::ScopedFD dir;
  const auto opened = OpenDirectory(profile, false, &dir);
  if (opened != OpenResult::kOk)
    return opened == OpenResult::kMissing;
  // An interrupted replacement can leave one private staging file. It is not
  // treated as committed history and never grows into a collection of files.
  if (!Remove(dir.get(), Pending(scope)))
    return false;
  base::ScopedFD fd(HANDLE_EINTR(openat(
      dir.get(), Name(scope), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)));
  if (!fd.is_valid())
    return errno == ENOENT;
  struct stat info;
  if (fstat(fd.get(), &info) != 0 || !IsPrivateFile(info) || info.st_size < 0 ||
      static_cast<uint64_t>(info.st_size) > kMaxHistoryBytes)
    return false;
  base::File file(fd.release());
  std::array<uint8_t, 4096> bytes;
  while (true) {
    auto n = file.ReadAtCurrentPosNoBestEffort(bytes);
    if (!n || history->size() + *n > kMaxHistoryBytes)
      return false;
    if (!*n)
      return true;
    history->append(base::as_string_view(base::span(bytes).first(*n)));
  }
}

bool SaveCoreLogHistory(const base::FilePath& profile,
                        CoreLogProfile scope,
                        const std::string& history) {
  if (history.size() > kMaxHistoryBytes)
    return false;
  base::ScopedFD dir;
  const auto opened = OpenDirectory(profile, !history.empty(), &dir);
  if (opened != OpenResult::kOk)
    return opened == OpenResult::kMissing && history.empty();
  if (!Remove(dir.get(), Pending(scope)))
    return false;
  if (history.empty())
    return Remove(dir.get(), Name(scope));
  struct stat info;
  if (fstatat(dir.get(), Name(scope), &info, AT_SYMLINK_NOFOLLOW) == 0) {
    if (!IsPrivateFile(info))
      return false;
  } else if (errno != ENOENT) {
    return false;
  }
  base::ScopedFD fd(HANDLE_EINTR(
      openat(dir.get(), Pending(scope),
             O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)));
  if (!fd.is_valid())
    return false;
  const bool saved =
      base::WriteFileDescriptor(fd.get(), history) &&
      HANDLE_EINTR(fsync(fd.get())) == 0 &&
      renameat(dir.get(), Pending(scope), dir.get(), Name(scope)) == 0;
  if (!saved)
    Remove(dir.get(), Pending(scope));
  return saved;
}
}  // namespace aegis::access
