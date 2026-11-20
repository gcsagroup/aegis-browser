// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_private_files_win.h"

#include <windows.h>

#include "base/files/file_path.h"
#include "base/win/access_token.h"
#include "base/win/scoped_handle.h"
#include "base/win/security_descriptor.h"

namespace aegis::access {
namespace {

bool FileKind(HANDLE file, bool directory) {
  BY_HANDLE_FILE_INFORMATION info{};
  return ::GetFileType(file) == FILE_TYPE_DISK &&
      ::GetFileInformationByHandle(file, &info) &&
      !(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
      !!(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == directory &&
      (directory || info.nNumberOfLinks == 1);
}

bool CheckDirectory(const base::FilePath& path, bool require_private) {
  base::win::ScopedHandle directory(::CreateFileW(path.value().c_str(),
      FILE_READ_ATTRIBUTES | READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_WRITE |
      FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!directory.is_valid() || !FileKind(directory.get(), true)) return false;
  return HasPrivateAccessAcl(directory.get(), require_private);
}
}  // namespace

bool HasPrivateAccessAcl(HANDLE file, bool private_directory) {
  const auto token = base::win::AccessToken::FromCurrentProcess();
  const auto security = base::win::SecurityDescriptor::FromHandle(file,
      base::win::SecurityObjectType::kFile,
      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION);
  if (!token || !security || !security->owner() ||
      !security->dacl() || security->dacl()->is_null() ||
      (private_directory && !security->dacl_protected())) return false;
  const auto user = token->User();
  if (*security->owner() != user) return false;
  const base::win::Sid system(base::win::WellKnownSid::kLocalSystem);
  const base::win::Sid admins(base::win::WellKnownSid::kBuiltinAdministrators);
  auto* acl = security->dacl()->get();
  constexpr BYTE kInheritance = OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE;
  if (private_directory && acl->AceCount != 1) return false;
  for (DWORD i = 0; i < acl->AceCount; ++i) {
    void* entry = nullptr;
    if (!::GetAce(const_cast<ACL*>(acl), i, &entry)) return false;
    const auto* header = static_cast<const ACE_HEADER*>(entry);
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) return false;
    PSID sid = &static_cast<ACCESS_ALLOWED_ACE*>(entry)->SidStart;
    const bool current_user = ::EqualSid(sid, user.GetPSID());
    if (private_directory) {
      if (!current_user || (header->AceFlags & kInheritance) != kInheritance ||
          (header->AceFlags & INHERIT_ONLY_ACE)) return false;
    } else if (!current_user && !::EqualSid(sid, system.GetPSID()) &&
               !::EqualSid(sid, admins.GetPSID())) {
      return false;
    }
  }
  return true;
}

bool IsPrivateAccessFile(HANDLE file) {
  return FileKind(file, false) && HasPrivateAccessAcl(file, false);
}

bool IsOwnedAccessDirectory(const base::FilePath& path) {
  return CheckDirectory(path, false);
}

bool IsPrivateAccessDirectory(const base::FilePath& path) {
  return CheckDirectory(path, true);
}

bool CreatePrivateAccessDirectory(const base::FilePath& path) {
  auto token = base::win::AccessToken::FromCurrentProcess();
  if (!token) return false;
  auto descriptor = base::win::SecurityDescriptor::CreateWithEmptyDacl();
  descriptor.set_dacl_protected(true);
  descriptor.set_owner(token->User());
  if (!descriptor.SetDaclEntry(*token, base::win::SecurityAccessMode::kGrant,
                               FILE_ALL_ACCESS,
                               OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE)) {
    return false;
  }
  auto absolute = descriptor.ToAbsolute();
  SECURITY_ATTRIBUTES attributes{sizeof(attributes), &absolute, FALSE};
  if (!::CreateDirectoryW(path.value().c_str(), &attributes)) return false;
  if (IsPrivateAccessDirectory(path)) return true;
  ::RemoveDirectoryW(path.value().c_str());
  ::SetLastError(ERROR_ACCESS_DENIED);
  return false;
}

}  // namespace aegis::access
