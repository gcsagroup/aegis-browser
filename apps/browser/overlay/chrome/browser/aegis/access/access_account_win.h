// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_WIN_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_ACCOUNT_WIN_H_

#include <cstdint>
#include <optional>
#include <string>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/functional/callback_helpers.h"
#include "base/values.h"

namespace aegis::access {

using AccountSnapshot = base::RepeatingCallback<base::DictValue()>;
struct PrivateAccountBinding {
  std::string origin;
  std::string account;
  std::string token;
};
struct AccountNodeGrant {
  std::string host;
  uint16_t port;
  std::string authorization;
  int64_t expires_ms;
  base::RepeatingCallback<std::string()> binding_state;
  base::ScopedClosureRunner revoke;
  base::RepeatingCallback<void(base::OnceCallback<void(int64_t)>)> renew;
};

void QueryWindowsAccessAccount(const base::FilePath& profile,
                               base::OnceCallback<void(AccountSnapshot)> done);
void IssueWindowsAccessNode(
    const base::FilePath& profile,
    std::optional<PrivateAccountBinding> private_binding,
    std::string context,
    base::OnceCallback<void(std::optional<AccountNodeGrant>)> done);

}  // namespace aegis::access
#endif
