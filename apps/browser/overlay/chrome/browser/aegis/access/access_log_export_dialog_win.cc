// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_log_export_dialog_win.h"

#include <wrl/implements.h>

#include <utility>

#include "base/check.h"
#include "base/functional/callback.h"

namespace aegis::access {
namespace {

class NewDestinationEvents final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          IFileDialogEvents> {
 public:
  explicit NewDestinationEvents(
      base::RepeatingCallback<void(IFileDialog*)> on_existing_destination)
      : on_existing_destination_(std::move(on_existing_destination)) {
    CHECK(on_existing_destination_);
  }

 private:
  ~NewDestinationEvents() override = default;

  IFACEMETHODIMP OnFileOk(IFileDialog*) override { return S_OK; }
  IFACEMETHODIMP OnFolderChanging(IFileDialog*, IShellItem*) override {
    return E_NOTIMPL;
  }
  IFACEMETHODIMP OnFolderChange(IFileDialog*) override { return E_NOTIMPL; }
  IFACEMETHODIMP OnSelectionChange(IFileDialog*) override { return E_NOTIMPL; }
  IFACEMETHODIMP OnTypeChange(IFileDialog*) override { return E_NOTIMPL; }
  IFACEMETHODIMP OnShareViolation(IFileDialog*, IShellItem*,
                                  FDE_SHAREVIOLATION_RESPONSE*) override {
    return E_NOTIMPL;
  }
  IFACEMETHODIMP OnOverwrite(IFileDialog* dialog, IShellItem*,
                             FDE_OVERWRITE_RESPONSE* response) override {
    if (!response) return E_POINTER;
    // FDEOR_REFUSE keeps the picker open rather than accepting a path that the
    // exclusive-create writer cannot use. Do not truncate the existing file.
    *response = FDEOR_REFUSE;
    on_existing_destination_.Run(dialog);
    return S_OK;
  }

  base::RepeatingCallback<void(IFileDialog*)> on_existing_destination_;
};

}  // namespace

HRESULT ConfigureAccessLogExportDialog(IFileDialog* dialog) {
  FILEOPENDIALOGOPTIONS options = 0;
  const HRESULT result = dialog->GetOptions(&options);
  if (FAILED(result)) return result;
  return dialog->SetOptions(options | FOS_OVERWRITEPROMPT | FOS_FORCEFILESYSTEM |
                            FOS_PATHMUSTEXIST | FOS_DONTADDTORECENT |
                            FOS_NOCHANGEDIR | FOS_NODEREFERENCELINKS);
}

Microsoft::WRL::ComPtr<IFileDialogEvents> CreateAccessLogExportDialogEvents(
    base::RepeatingCallback<void(IFileDialog*)> on_existing_destination) {
  return Microsoft::WRL::Make<NewDestinationEvents>(
      std::move(on_existing_destination));
}

}  // namespace aegis::access
