// Copyright 2026 The GCSA Aegis Authors
// 交互式安装后的启动策略；只允许成功安装状态，不把失败或维护任务当作安装成功。
#ifndef CHROME_INSTALLER_SETUP_AEGIS_LAUNCH_POLICY_H_
#define CHROME_INSTALLER_SETUP_AEGIS_LAUNCH_POLICY_H_

#include "chrome/installer/util/util_constants.h"

namespace installer {
// 显式静默或禁止启动始终优先；覆盖首次安装、修复和升级，不重复启动已有实例分支。
constexpr bool ShouldLaunchAegisAfterInstall(InstallStatus status,
                                             bool interactive,
                                             bool silent,
                                             bool do_not_launch) {
  return interactive && !silent && !do_not_launch &&
         (status == FIRST_INSTALL_SUCCESS || status == INSTALL_REPAIRED ||
          status == NEW_VERSION_UPDATED || status == IN_USE_UPDATED ||
          status == OLD_VERSION_DOWNGRADE || status == IN_USE_DOWNGRADE);
}
// Use only the desktop broker. A missing, elevated or unverifiable shell must
// never fall back to launching with the installer's token. Callbacks keep this
// decision testable without starting a browser or changing the desktop.
template <typename GetShell, typename IsSafeShell, typename LaunchViaShell>
bool LaunchAegisThroughDesktop(GetShell get_shell,
                              IsSafeShell is_safe_shell,
                              LaunchViaShell launch_via_shell) {
  const auto shell = get_shell();
  if (!shell || !is_safe_shell(shell))
    return false;
  return launch_via_shell();
}
}  // namespace installer
#endif  // CHROME_INSTALLER_SETUP_AEGIS_LAUNCH_POLICY_H_
