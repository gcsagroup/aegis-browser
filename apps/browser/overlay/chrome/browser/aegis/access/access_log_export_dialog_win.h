// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOG_EXPORT_DIALOG_WIN_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_LOG_EXPORT_DIALOG_WIN_H_

#include <windows.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include "base/functional/callback_forward.h"

namespace aegis::access {

// Preserve the native defaults and request overwrite events, which the handler
// refuses because diagnostic exports only create new destination files.
HRESULT ConfigureAccessLogExportDialog(IFileDialog* dialog);
Microsoft::WRL::ComPtr<IFileDialogEvents> CreateAccessLogExportDialogEvents(
    base::RepeatingCallback<void(IFileDialog*)> on_existing_destination);

}  // namespace aegis::access
#endif
