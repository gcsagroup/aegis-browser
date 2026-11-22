// Copyright 2026 GCSA
// 管理 Windows Access 核心的私有目录和进程。只有子进程成功加入作业后，调用方才接管句柄。
#include "chrome/browser/aegis/access/access_local_core_win.h"

#include <windows.h>

#include <algorithm>
#include <array>
#include <string>
#include <utility>

#include "base/base_paths_win.h"
#include "base/command_line.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/process/launch.h"
#include "base/threading/platform_thread.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/win/scoped_process_information.h"
#include "base/win/startup_information.h"
#include "chrome/browser/aegis/access/access_private_files_win.h"

namespace aegis::access {

bool CreatePrivateCoreDirectory(base::ScopedTempDir& directory) {
  base::FilePath root;
  if (!base::PathService::Get(base::DIR_LOCAL_APP_DATA, &root) ||
      !IsOwnedAccessDirectory(root)) return false;
  const auto path = root.AppendASCII(
      "AegisAccess-" + base::Uuid::GenerateRandomV4().AsLowercaseString());
  if (!CreatePrivateAccessDirectory(path)) return false;
  if (directory.Set(path)) return true;
  base::DeletePathRecursively(path);
  return false;
}

base::Process LaunchOwnedCore(const base::CommandLine& command,
                              const base::FilePath& directory,
                              base::win::ScopedHandle& job, base::File* log_read) {
  base::win::ScopedHandle owned_job(::CreateJobObjectW(nullptr, nullptr));
  if (!owned_job.is_valid() ||
      !base::SetJobObjectLimitFlags(owned_job.get(),
                                  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)) {
    return base::Process();
  }
  SECURITY_ATTRIBUTES inherited{sizeof(inherited), nullptr, TRUE};
  base::win::ScopedHandle input(::CreateFileW(L"NUL", GENERIC_READ,
      FILE_SHARE_READ | FILE_SHARE_WRITE, &inherited, OPEN_EXISTING, 0, nullptr));
  base::win::ScopedHandle output;
  base::win::ScopedHandle pipe_read;
  if (log_read) {
    HANDLE reader = nullptr;
    HANDLE writer = nullptr;
    if (::CreatePipe(&reader, &writer, &inherited, 0)) {
      pipe_read.Set(reader);
      output.Set(writer);
      if (!::SetHandleInformation(reader, HANDLE_FLAG_INHERIT, 0)) {
        pipe_read.Close();
        output.Close();
      }
    }
  }
  if (!output.is_valid()) {
    output.Set(::CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ |
        FILE_SHARE_WRITE, &inherited, OPEN_EXISTING, 0, nullptr));
  }
  if (!input.is_valid() || !output.is_valid()) {
    return base::Process();
  }
  HANDLE stdio[] = {input.get(), output.get()};
  HANDLE job_handle = owned_job.get();
  base::win::StartupInformation startup;
  if (!startup.InitializeProcThreadAttributeList(2) ||
      !startup.UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_JOB_LIST,
                                         &job_handle, sizeof(job_handle)) ||
      !startup.UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                         stdio, sizeof(stdio))) {
    return base::Process();
  }

  startup.startup_info()->dwFlags |= STARTF_USESTDHANDLES;
  startup.startup_info()->hStdInput = input.get();
  startup.startup_info()->hStdOutput = output.get();
  startup.startup_info()->hStdError = output.get();
  PROCESS_INFORMATION child = {};
  std::wstring command_line = command.GetCommandLineString();
  // Winsock 提供程序依赖 SystemRoot；完全空环境会使 Xray 创建套接字失败。
  // 从 Windows API 获取可信目录，不继承父进程的 PATH、代理、密钥或伪造的 SystemRoot。
  std::array<wchar_t, MAX_PATH> windows_directory{};
  const UINT length = ::GetWindowsDirectoryW(windows_directory.data(),
                                             windows_directory.size());
  if (length == 0 || length >= windows_directory.size()) {
    return base::Process();
  }
  std::wstring environment = L"SystemRoot=";
  environment.append(windows_directory.data(), length);
  // CreateProcessW 的 Unicode 环境块由两个 NUL 结束，不能传入普通单字符串。
  environment.append(2, L'\0');
  if (!::CreateProcessW(command.GetProgram().value().c_str(), command_line.data(),
                        nullptr, nullptr, TRUE,
                        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT |
                            CREATE_NO_WINDOW,
                        environment.data(), directory.value().c_str(),
                        startup.startup_info(), &child)) {
    return base::Process();
  }
  base::win::ScopedProcessInformation child_handles(child);
  job = std::move(owned_job);
  if (pipe_read.is_valid()) *log_read = base::File(pipe_read.Take());
  return base::Process(child_handles.TakeProcessHandle());
}

void StopOwnedCore(base::win::ScopedHandle& job,
                   base::ScopedTempDir& directory) {
  constexpr auto kPollInterval = base::Milliseconds(20);
  const auto deadline = base::TimeTicks::Now() + base::Seconds(2);
  if (job.is_valid()) {
    bool job_empty = false;
    if (::TerminateJobObject(job.get(), 1)) {
      JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = {};
      do {
        if (!::QueryInformationJobObject(job.get(),
                                         JobObjectBasicAccountingInformation,
                                         &accounting, sizeof(accounting),
                                         nullptr)) {
          break;
        }
        if (accounting.ActiveProcesses == 0) {
          job_empty = true;
          break;
        }
        const auto remaining = deadline - base::TimeTicks::Now();
        if (!remaining.is_positive()) break;
        base::PlatformThread::Sleep(std::min(remaining, kPollInterval));
      } while (base::TimeTicks::Now() < deadline);
    }
    // Kill-on-close still applies if termination or observation failed.
    job.Close();
    if (!job_empty) {
      LOG(WARNING) << "Access core process tree rundown could not be confirmed.";
    }
  }
  if (!directory.IsValid()) {
    return;
  }
  do {
    if (directory.Delete()) {
      return;
    }
    const auto remaining = deadline - base::TimeTicks::Now();
    if (!remaining.is_positive()) break;
    base::PlatformThread::Sleep(std::min(remaining, kPollInterval));
  } while (base::TimeTicks::Now() < deadline);
  // Keep the private directory owned so the next Stop or destruction retries.
  LOG(WARNING) << "Access core private directory could not be removed.";
}

}  // namespace aegis::access
