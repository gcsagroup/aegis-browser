// Copyright 2016 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// Aegis 使用独立且固定的 Windows 安装身份；内部 Chromium 类型名保留兼容。

#ifndef CHROME_INSTALL_STATIC_CHROMIUM_INSTALL_MODES_H_
#define CHROME_INSTALL_STATIC_CHROMIUM_INSTALL_MODES_H_

#include <array>

#include "chrome/app/chrome_dll_resource.h"
#include "chrome/common/chrome_icon_resources_win.h"
#include "chrome/install_static/install_constants.h"

namespace install_static {

// The brand-specific company name to be included as a component of the install
// and user data directory paths. May be empty if no such dir is to be used.
inline constexpr wchar_t kCompanyPathName[] = L"";

// The brand-specific product name to be included as a component of the install
// and user data directory paths.
inline constexpr wchar_t kProductPathName[] = L"GCSA Aegis";

// The brand-specific safe browsing client name.
inline constexpr char kSafeBrowsingName[] = "chromium";

// Note: This list of indices must be kept in sync with the brand-specific
// resource strings in chrome/installer/util/prebuild/create_string_rc.
enum InstallConstantIndex {
  CHROMIUM_INDEX,
  NUM_INSTALL_MODES,
};

inline constexpr auto kInstallModes = std::to_array<InstallConstants>({
    // The primary (and only) install mode for Chromium.
    {
        .size = sizeof(InstallConstants),
        .index = CHROMIUM_INDEX,  // The one and only mode for Chromium.
        .install_switch =
            "",  // No install switch for the primary install mode.
        .install_suffix =
            L"",  // Empty install_suffix for the primary install mode.
        .logo_suffix = L"",  // No logo suffix for the primary install mode.
        .app_guid =
            L"",  // Empty app_guid since no integration with Google Update.
        .base_app_name = L"GCSA Aegis",         // A distinct base_app_name.
        .base_app_id = L"app.gcsa.aegis",       // A distinct base_app_id.
        .browser_prog_id_prefix = L"AegisHTM",  // Browser ProgID prefix.
        .browser_prog_id_description =
            L"GCSA Aegis HTML Document",  // Browser ProgID description.
        .direct_launch_url_scheme = "aegis",
        .pdf_prog_id_prefix = L"AegisPDF",  // PDF ProgID prefix.
        .pdf_prog_id_description =
            L"GCSA Aegis PDF Document",  // PDF ProgID description.
        .active_setup_guid =
            L"{43A39D18-33E1-5306-B967-2CE20EC76C03}",  // Active Setup
                                                        // GUID.
        .toast_activator_clsid = {0xff8ef761,
                                  0xf35a,
                                  0x5216,
                                  {0xab, 0x8d, 0x6a, 0xc4, 0xdd, 0x06, 0x0f,
                                   0xa6}},  // Toast Activator CLSID.
        .elevator_clsid = {0x1a5bb399,
                           0x46a8,
                           0x5b7c,
                           {0xa3, 0x2f, 0x89, 0x53, 0x30, 0x13, 0xfb,
                            0x7c}},  // Elevator CLSID.
        .elevator_iid = {0xbb19a0e5,
                         0x3c2f,
                         0x5d8d,
                         {0xa3, 0x76, 0xb9, 0xef, 0xfd, 0xd7, 0x7f,
                          0xfe}},  // IElevator IID and TypeLib
        // 与 GN 中的固定 Aegis IID 映射一致。
        .old_elevator_iids = {},
        .tracing_service_clsid = {0x7ef1162a,
                                  0xe1e3,
                                  0x53b9,
                                  {0xad, 0xfd, 0xc3, 0xf6, 0x1a, 0x33, 0xcf,
                                   0xc4}},  // SystemTraceSession CLSID.
        .tracing_service_iid = {0xe0b03e2d,
                                0xa44c,
                                0x5c6a,
                                {0xa6, 0x6a, 0x13, 0xb3, 0x9a, 0xf8, 0x83,
                                 0xe5}},  // ISystemTraceSessionChromium IID and
                                          // TypeLib
        // 不清理原版 Chromium 的历史 COM 注册。
        .old_tracing_service_iids = {},
        .default_channel_name =
            L"",  // Empty default channel name since no update integration.
        .channel_strategy = ChannelStrategy::UNSUPPORTED,
        .supports_system_level = true,  // Supports system-level installs.
        .supports_set_as_default_browser =
            true,  // Supports in-product set as default browser UX.
        .app_icon_resource_index =
            icon_resources::kApplicationIndex,  // App icon resource index.
        .app_icon_resource_id = IDR_MAINFRAME,  // App icon resource id.
        .html_doc_icon_resource_index =
            icon_resources::kHtmlDocIndex,  // HTML doc icon resource index.
        .pdf_doc_icon_resource_index =
            icon_resources::kPDFDocIndex,  // PDF doc icon resource index.
        .sandbox_sid_prefix =
            L"S-1-15-2-2952258977-4202009782-3179178386-2292280855-2728581886-"
            L"284722248-",  // App container sid prefix for sandbox.
    },
});

}  // namespace install_static

#endif  // CHROME_INSTALL_STATIC_CHROMIUM_INSTALL_MODES_H_
