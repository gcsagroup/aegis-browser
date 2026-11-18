// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_log_export_win.h"

#include <windows.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <optional>
#include <utility>

#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/win/scoped_co_mem.h"
#include "chrome/browser/aegis/access/access_core_log_share.h"
#include "chrome/browser/aegis/access/access_log_export_dialog_win.h"
#include "ui/views/win/hwnd_util.h"

namespace aegis::access {
namespace {

void ExplainExistingDestination(IFileDialog* dialog) {
  dialog->SetTitle(L"Choose a new filename for Access diagnostics");
  Microsoft::WRL::ComPtr<IOleWindow> window;
  HWND owner = nullptr;
  if (SUCCEEDED(dialog->QueryInterface(IID_PPV_ARGS(&window))) &&
      SUCCEEDED(window->GetWindow(&owner)) && ::IsWindow(owner)) {
    ::MessageBoxW(owner,
                  L"The selected file already exists. Choose a different "
                  L"filename to save the diagnostics. The existing file "
                  L"will be kept.",
                  L"Save Access diagnostics", MB_OK | MB_ICONINFORMATION);
  }
}

std::optional<base::FilePath> PickDestination(HWND owner) {
  if (!::IsWindow(owner)) return std::nullopt;
  Microsoft::WRL::ComPtr<IFileSaveDialog> picker;
  if (FAILED(::CoCreateInstance(__uuidof(FileSaveDialog), nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&picker)))) {
    return std::nullopt;
  }
  if (FAILED(ConfigureAccessLogExportDialog(picker.Get())) ||
      FAILED(picker->SetTitle(L"Save compressed Access diagnostics")) ||
      FAILED(picker->SetFileName(L"Aegis-Access.log.gz"))) return std::nullopt;
  auto events = CreateAccessLogExportDialogEvents(
      base::BindRepeating(&ExplainExistingDestination));
  DWORD cookie = 0;
  if (FAILED(picker->Advise(events.Get(), &cookie))) return std::nullopt;
  base::ScopedClosureRunner unadvise(base::BindOnce(
      [](Microsoft::WRL::ComPtr<IFileSaveDialog> dialog, DWORD cookie) {
        dialog->Unadvise(cookie);
      }, picker, cookie));
  const auto result = picker->Show(owner);
  if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return base::FilePath();
  Microsoft::WRL::ComPtr<IShellItem> selected;
  base::win::ScopedCoMem<wchar_t> destination;
  if (FAILED(result) || FAILED(picker->GetResult(&selected)) ||
      FAILED(selected->GetDisplayName(SIGDN_FILESYSPATH, &destination))) {
    return std::nullopt;
  }
  return base::FilePath(destination.get());
}

bool WriteDestination(const base::FilePath& destination,
                      const std::string& bytes) {
  base::File file(destination, base::File::FLAG_CREATE | base::File::FLAG_WRITE |
                                  base::File::FLAG_WIN_EXCLUSIVE_READ |
                                  base::File::FLAG_WIN_EXCLUSIVE_WRITE |
                                  base::File::FLAG_CAN_DELETE_ON_CLOSE);
  return file.IsValid() && file.DeleteOnClose(true) &&
         file.WriteAtCurrentPosAndCheck(base::as_byte_span(bytes)) &&
         file.Flush() && file.DeleteOnClose(false);
}

void OnArchiveRead(base::FilePath destination,
                   base::RepeatingCallback<bool()> still_valid,
                   base::OnceCallback<void(bool)> done,
                   std::string bytes) {
  if (bytes.empty() || !still_valid.Run()) {
    std::move(done).Run(false);
    return;
  }
  // The destination write uses bounded in-memory data. EndSession can remove
  // the source archive without racing a file handle or waiting on this path.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock()},
      base::BindOnce(&WriteDestination, std::move(destination), std::move(bytes)),
      std::move(done));
}

}  // namespace

void ExportAccessLogOnWindows(gfx::NativeWindow window,
                              base::FilePath archive,
                              base::RepeatingCallback<bool()> still_valid,
                              base::OnceCallback<void(bool)> done) {
  // Keep the OS modal loop off the Browser UI sequence, where account grants
  // and proxy readiness still need their timers and replies.
  auto sequence = base::ThreadPool::CreateCOMSTATaskRunner(
      {base::MayBlock(), base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
      base::SingleThreadTaskRunnerThreadMode::DEDICATED);
  sequence->PostTaskAndReplyWithResult(
      FROM_HERE, base::BindOnce(&PickDestination, views::HWNDForNativeWindow(window)),
      base::BindOnce([](base::FilePath archive,
                        base::RepeatingCallback<bool()> still_valid,
                        base::OnceCallback<void(bool)> done,
                        std::optional<base::FilePath> destination) {
        if (!destination || !still_valid.Run()) {
          std::move(done).Run(false);
          return;
        }
        if (destination->empty()) {
          std::move(done).Run(true);
          return;
        }
        ReadCoreLogArchiveForExport(
            std::move(archive),
            base::BindOnce(&OnArchiveRead, std::move(*destination),
                           std::move(still_valid), std::move(done)));
      }, std::move(archive), std::move(still_valid), std::move(done)));
}

}  // namespace aegis::access
