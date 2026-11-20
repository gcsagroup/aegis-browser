// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_core_log_disk.h"

#include <windows.h>

#include <utility>

#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_util.h"
#include "chrome/browser/aegis/access/access_private_files_win.h"

namespace aegis::access {
namespace {

constexpr size_t kMaxHistoryBytes = 64 * 1024;
const char* Name(CoreLogProfile scope) {
  return scope == CoreLogProfile::kPrivate ? "private.log" : "regular.log";
}
const char* Pending(CoreLogProfile scope) {
  return scope == CoreLogProfile::kPrivate ? ".private.pending" : ".regular.pending";
}

bool Missing(DWORD error) {
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

enum class OpenResult { kOk, kMissing, kError };
OpenResult OpenDirectory(const base::FilePath& profile, bool create,
                         base::FilePath& directory) {
  if (!IsOwnedAccessDirectory(profile)) return OpenResult::kError;
  directory = profile.AppendASCII(kCoreLogDirectory);
  if (create && !CreatePrivateAccessDirectory(directory) &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) return OpenResult::kError;
  const DWORD attrs = ::GetFileAttributesW(directory.value().c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES) {
    return Missing(::GetLastError()) ? OpenResult::kMissing : OpenResult::kError;
  }
  return IsPrivateAccessDirectory(directory) ? OpenResult::kOk : OpenResult::kError;
}

bool Remove(const base::FilePath& file) {
  if (::DeleteFileW(file.value().c_str())) return true;
  return Missing(::GetLastError());
}

base::File OpenPrivateFile(const base::FilePath& path) {
  return base::File(::CreateFileW(
      path.value().c_str(), GENERIC_READ | READ_CONTROL, FILE_SHARE_READ,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
}
}  // namespace

bool ReadCoreLogHistory(const base::FilePath& profile, CoreLogProfile scope,
                        std::string* history) {
  history->clear();
  base::FilePath dir;
  const auto opened = OpenDirectory(profile, false, dir);
  if (opened != OpenResult::kOk) return opened == OpenResult::kMissing;
  if (!Remove(dir.AppendASCII(Pending(scope)))) return false;
  auto file = OpenPrivateFile(dir.AppendASCII(Name(scope)));
  if (!file.IsValid()) return Missing(::GetLastError());
  if (!IsPrivateAccessFile(file.GetPlatformFile())) return false;
  const auto length = file.GetLength();
  if (length < 0 || length > static_cast<int64_t>(kMaxHistoryBytes)) return false;
  std::string text(static_cast<size_t>(length), '\0');
  if (!text.empty() && !file.ReadAtCurrentPosAndCheck(base::as_writable_byte_span(text)))
    return false;
  *history = std::move(text);
  return true;
}

bool SaveCoreLogHistory(const base::FilePath& profile, CoreLogProfile scope,
                        const std::string& history) {
  if (history.size() > kMaxHistoryBytes) return false;
  base::FilePath dir;
  const auto opened = OpenDirectory(profile, !history.empty(), dir);
  if (opened != OpenResult::kOk)
    return opened == OpenResult::kMissing && history.empty();
  const auto pending = dir.AppendASCII(Pending(scope));
  if (!Remove(pending)) return false;
  const auto saved = dir.AppendASCII(Name(scope));
  if (history.empty()) return Remove(saved);
  auto existing = OpenPrivateFile(saved);
  if (existing.IsValid() ? !IsPrivateAccessFile(existing.GetPlatformFile())
                         : !Missing(::GetLastError())) return false;
  existing.Close();
  base::File file(pending, base::File::FLAG_CREATE | base::File::FLAG_WRITE);
  const bool written = file.IsValid() &&
      file.WriteAtCurrentPosAndCheck(base::as_byte_span(history)) && file.Flush();
  file.Close();
  const bool replaced = written && ::MoveFileExW(pending.value().c_str(),
      saved.value().c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
  if (!replaced) Remove(pending);
  return replaced;
}

}  // namespace aegis::access
