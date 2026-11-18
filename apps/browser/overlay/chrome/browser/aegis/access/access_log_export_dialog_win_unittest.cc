// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_log_export_dialog_win.h"

#include <shlobj.h>

#include <string>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/test/bind.h"
#include "base/win/scoped_com_initializer.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

class AccessLogExportDialogWindowsTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(com_.Succeeded());
    ASSERT_TRUE(temp_.CreateUniqueTempDir());
    ASSERT_TRUE(SUCCEEDED(::CoCreateInstance(
        __uuidof(FileSaveDialog), nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&picker_))));
  }

  base::win::ScopedCOMInitializer com_;
  base::ScopedTempDir temp_;
  Microsoft::WRL::ComPtr<IFileSaveDialog> picker_;
};

TEST_F(AccessLogExportDialogWindowsTest, KeepsDefaultsAndRegistersOverwriteEvents) {
  FILEOPENDIALOGOPTIONS defaults = 0;
  ASSERT_TRUE(SUCCEEDED(picker_->GetOptions(&defaults)));
  defaults |= FOS_STRICTFILETYPES;
  ASSERT_TRUE(SUCCEEDED(picker_->SetOptions(defaults)));
  ASSERT_TRUE(SUCCEEDED(ConfigureAccessLogExportDialog(picker_.Get())));
  FILEOPENDIALOGOPTIONS actual = 0;
  ASSERT_TRUE(SUCCEEDED(picker_->GetOptions(&actual)));
  EXPECT_EQ(actual & defaults, defaults);
  constexpr FILEOPENDIALOGOPTIONS required =
      FOS_OVERWRITEPROMPT | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST |
      FOS_DONTADDTORECENT | FOS_NOCHANGEDIR | FOS_NODEREFERENCELINKS;
  EXPECT_EQ(actual & required, required);
  auto events = CreateAccessLogExportDialogEvents(
      base::BindRepeating([](IFileDialog*) {}));
  DWORD cookie = 0;
  ASSERT_TRUE(SUCCEEDED(picker_->Advise(events.Get(), &cookie)));
  EXPECT_TRUE(SUCCEEDED(picker_->Unadvise(cookie)));
}

TEST_F(AccessLogExportDialogWindowsTest, RefusesExistingDestinationAndPreservesFile) {
  const auto path = temp_.GetPath().AppendASCII("Aegis-Access.log.gz");
  ASSERT_TRUE(base::WriteFile(path, "previous archive"));
  Microsoft::WRL::ComPtr<IShellItem> item;
  ASSERT_TRUE(SUCCEEDED(::SHCreateItemFromParsingName(
      path.value().c_str(), nullptr, IID_PPV_ARGS(&item))));
  int prompts = 0;
  auto events = CreateAccessLogExportDialogEvents(base::BindLambdaForTesting(
      [&](IFileDialog* dialog) {
        EXPECT_EQ(dialog, picker_.Get());
        ++prompts;
      }));
  FDE_OVERWRITE_RESPONSE response = FDEOR_DEFAULT;
  EXPECT_EQ(events->OnOverwrite(picker_.Get(), item.Get(), &response), S_OK);
  EXPECT_EQ(response, FDEOR_REFUSE);
  EXPECT_EQ(prompts, 1);
  std::string bytes;
  ASSERT_TRUE(base::ReadFileToString(path, &bytes));
  EXPECT_EQ(bytes, "previous archive");
}

TEST_F(AccessLogExportDialogWindowsTest, FreshSelectionCanFinishAfterRefusedOverwrite) {
  int prompts = 0;
  auto events = CreateAccessLogExportDialogEvents(
      base::BindLambdaForTesting([&](IFileDialog*) { ++prompts; }));
  FDE_OVERWRITE_RESPONSE response = FDEOR_DEFAULT;
  ASSERT_EQ(events->OnOverwrite(picker_.Get(), nullptr, &response), S_OK);
  ASSERT_EQ(response, FDEOR_REFUSE);
  ASSERT_TRUE(SUCCEEDED(picker_->SetFileName(L"Aegis-Access-2.log.gz")));
  EXPECT_EQ(events->OnFileOk(picker_.Get()), S_OK);
  EXPECT_EQ(prompts, 1);
  EXPECT_FALSE(base::PathExists(temp_.GetPath().AppendASCII("Aegis-Access-2.log.gz")));
}

}  // namespace
}  // namespace aegis::access
