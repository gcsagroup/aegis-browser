// Copyright 2026 The GCSA Aegis Authors
// 验证进度通道、实际解包计量和事务边界；仅使用临时文件及隔离注册表。
#include "chrome/installer/aegis_install_progress.h"

#include <algorithm>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/path_service.h"
#include "base/strings/utf_string_conversions.h"
#include "base/test/bind.h"
#include "base/test/multiprocess_test.h"
#include "base/test/test_reg_util_win.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "chrome/common/chrome_paths.h"
#include "chrome/installer/setup/installer_state.h"
#include "chrome/installer/util/initial_preferences.h"
#include "chrome/installer/util/installation_state.h"
#include "chrome/installer/util/lzma_util.h"
#include "chrome/installer/util/work_item_list.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "testing/multiprocess_func_list.h"

namespace aegis_installer {
namespace {
std::wstring NewName() {
  std::string nonce = base::Uuid::GenerateRandomV4().AsLowercaseString();
  std::erase(nonce, '-');
  return kProgressNamePrefix + base::ASCIIToWide(nonce);
}

TEST(AegisInstallProgressTest, IsolatedChannelRejectsCollisionAndInvalidData) {
  std::wstring name = NewName();
  ProgressChannel parent, child, collision;
  ASSERT_TRUE(parent.Create(name.c_str()));
  EXPECT_FALSE(collision.Create(name.c_str()));
  ASSERT_TRUE(child.Open(name.c_str()));
  child.Write(Phase::kDecompressing, 42);
  Progress progress;
  ASSERT_TRUE(parent.Read(&progress));
  EXPECT_EQ(Phase::kDecompressing, progress.phase);
  EXPECT_EQ(42, progress.percent);
  // 未知协议、越界阶段或伪造完成值都不能改变有效的展示状态。
  child.Write(Phase::kInstalling, 100);
  child.Write(static_cast<Phase>(255), 30);
  child.Write(Phase::kInstalling, -2);
  ASSERT_TRUE(parent.Read(&progress));
  EXPECT_EQ(42, progress.percent);
  HANDLE mapping = ::OpenFileMappingW(FILE_MAP_WRITE, FALSE, name.c_str());
  ASSERT_NE(nullptr, mapping);
  auto* packet = static_cast<LONG*>(
      ::MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, sizeof(LONG)));
  ASSERT_NE(nullptr, packet);
  for (DWORD value : {0u, 0xa602002au, 0xa601ff2au, 0xa6010064u}) {
    ::InterlockedExchange(packet, static_cast<LONG>(value));
    EXPECT_FALSE(parent.Read(&progress));
  }
  ::UnmapViewOfFile(packet);
  ::CloseHandle(mapping);
  child.Close();
  parent.Close();
  EXPECT_FALSE(child.Open(name.c_str()));
  EXPECT_FALSE(child.Open(
      L"Global\\GCSA.Aegis.Progress.0123456789abcdef0123456789abcdef"));
  EXPECT_FALSE(parent.Create(L"Local\\GCSA.Aegis.Progress.invalid"));
  EXPECT_FALSE(parent.Create(nullptr));
}

MULTIPROCESS_TEST_MAIN(AegisProgressWriter) {
  ProgressChannel channel;
  if (!channel.Open(base::CommandLine::ForCurrentProcess()
                        ->GetSwitchValueNative(kProgressSwitch)
                        .c_str()))
    return 1;
  channel.Write(Phase::kInstalling, 73);
  return 0;
}

TEST(AegisInstallProgressTest, ChildPublishesWithoutInheritedHandles) {
  // 通过名称建立进程间通道，子进程不继承父句柄；生命周期由各自句柄独立维持。
  std::wstring name = NewName();
  ProgressChannel channel;
  ASSERT_TRUE(channel.Create(name.c_str()));
  auto command = base::GetMultiProcessTestChildBaseCommandLine();
  command.AppendSwitchNative(kProgressSwitch, name);
  base::LaunchOptions options;
  options.start_hidden = true;
  auto child =
      base::SpawnMultiProcessTestChild("AegisProgressWriter", command, options);
  ASSERT_TRUE(child.IsValid());
  int code = -1;
  bool exited =
      base::WaitForMultiprocessTestChildExit(child, base::Seconds(20), &code);
  if (!exited)
    base::TerminateMultiProcessTestChild(child, 1, true);
  ASSERT_TRUE(exited);
  ASSERT_EQ(0, code);
  Progress progress;
  ASSERT_TRUE(channel.Read(&progress));
  EXPECT_EQ(Phase::kInstalling, progress.phase);
  EXPECT_EQ(73, progress.percent);
}

TEST(AegisInstallProgressTest, MeasuredStagesNeverDeclareOverallSuccess) {
  registry_util::RegistryOverrideManager registry;
  ASSERT_NO_FATAL_FAILURE(registry.OverrideRegistry(HKEY_CURRENT_USER));
  ASSERT_NO_FATAL_FAILURE(registry.OverrideRegistry(HKEY_LOCAL_MACHINE));
  std::wstring name = NewName();
  ProgressChannel channel;
  ASSERT_TRUE(channel.Create(name.c_str()));
  base::CommandLine command(base::FilePath(L"setup.exe"));
  command.AppendSwitch("aegis-interactive-install");
  command.AppendSwitchNative(kProgressSwitch, name);
  installer::InitialPreferences preferences(command);
  installer::InstallationState machine;
  installer::InstallerState state;
  state.Initialize(command, preferences, machine);
  state.SetStage(installer::UNCOMPRESSING);
  state.ReportUnpackProgress(42, 100);
  Progress progress;
  ASSERT_TRUE(channel.Read(&progress));
  EXPECT_EQ(Phase::kDecompressing, progress.phase);
  EXPECT_EQ(42, progress.percent);
  state.ReportUnpackProgress(100, 100);
  ASSERT_TRUE(channel.Read(&progress));
  EXPECT_EQ(99, progress.percent);
  state.SetStage(installer::EXECUTING);
  state.ReportInstallProgress(1, 4);
  ASSERT_TRUE(channel.Read(&progress));
  EXPECT_EQ(25, progress.percent);
  state.ReportInstallProgress(4, 0);
  state.ReportInstallProgress(5, 4);
  state.ReportUnpackProgress(3, 4);
  ASSERT_TRUE(channel.Read(&progress));
  EXPECT_EQ(25, progress.percent);
  state.SetStage(installer::ROLLINGBACK);
  ASSERT_TRUE(channel.Read(&progress));
  EXPECT_EQ(Phase::kRollingBack, progress.phase);
  EXPECT_EQ(-1, progress.percent);
  // 静默调用即便携带通道参数也不应写入交互 UI。
  command.RemoveSwitch("aegis-interactive-install");
  state.Initialize(command, preferences, machine);
  state.SetStage(installer::EXECUTING);
  state.ReportInstallProgress(4, 4);
  ASSERT_TRUE(channel.Read(&progress));
  EXPECT_EQ(Phase::kRollingBack, progress.phase);
}

TEST(AegisInstallProgressTest, FileAndMemoryUnpackReportActualPayload) {
  base::FilePath data;
  ASSERT_TRUE(base::PathService::Get(chrome::DIR_TEST_DATA, &data));
  auto archive = data.AppendASCII("installer/archive1.7z");
  auto bytes = base::ReadFileToBytes(archive);
  ASSERT_TRUE(bytes);
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  std::string reference;
  for (bool memory : {false, true}) {
    auto output = temp.GetPath().AppendASCII(memory ? "memory" : "file");
    ASSERT_TRUE(base::CreateDirectory(output));
    std::vector<std::pair<uint64_t, uint64_t>> observed;
    auto callback =
        base::BindLambdaForTesting([&](uint64_t completed, uint64_t total) {
          observed.emplace_back(completed, total);
        });
    auto status = memory
                      ? UnPackArchiveBuffer(*bytes, output, nullptr, callback)
                      : UnPackArchive(archive, output, nullptr, callback);
    ASSERT_EQ(UNPACK_NO_ERROR, status);
    ASSERT_GE(observed.size(), 2u);
    EXPECT_EQ(0u, observed.front().first);
    EXPECT_GT(observed.front().second, 0u);
    EXPECT_LT(observed.front().second, bytes->size());
    EXPECT_EQ(observed.back().first, observed.back().second);
    for (size_t i = 1; i < observed.size(); ++i) {
      EXPECT_GE(observed[i].first, observed[i - 1].first);
      EXPECT_EQ(observed[i].second, observed.front().second);
      EXPECT_LE(observed[i].first, observed[i].second);
    }
    std::string extracted;
    ASSERT_TRUE(
        base::ReadFileToString(output.AppendASCII("a.exe"), &extracted));
    EXPECT_FALSE(extracted.empty());
    if (memory)
      EXPECT_EQ(reference, extracted);
    else
      reference = extracted;
  }
}

TEST(AegisInstallProgressTest, CorruptArchiveCannotReportCompletedExtraction) {
  base::FilePath data;
  ASSERT_TRUE(base::PathService::Get(chrome::DIR_TEST_DATA, &data));
  auto bytes = base::ReadFileToBytes(data.AppendASCII("installer/archive1.7z"));
  ASSERT_TRUE(bytes);
  ASSERT_GT(bytes->size(), 100u);
  // 保留有效容器头，破坏压缩数据，验证观察者不把消费完字节当作解包成功。
  (*bytes)[50] ^= 0xff;
  base::ScopedTempDir temp;
  ASSERT_TRUE(temp.CreateUniqueTempDir());
  int reports = 0;
  auto callback =
      base::BindLambdaForTesting([&](uint64_t completed, uint64_t total) {
        ++reports;
        EXPECT_LE(completed, total);
      });
  EXPECT_NE(UNPACK_NO_ERROR,
            UnPackArchiveBuffer(*bytes, temp.GetPath(), nullptr, callback));
  EXPECT_GT(reports, 0);
}

TEST(AegisInstallProgressTest, FailedWorkIsNotCountedAndRollbackIsUnchanged) {
  // 只计已提交的顶层事务；失败项参与回滚，但不会把完成计数向前推进。
  std::unique_ptr<WorkItemList> owner(WorkItem::CreateWorkItemList());
  WorkItemList& list = *owner;
  std::vector<std::pair<size_t, size_t>> observed;
  list.set_progress_callback(base::BindLambdaForTesting(
      [&](size_t done, size_t total) { observed.emplace_back(done, total); }));
  std::vector<int> actions;
  for (int id : {1, 2, 3}) {
    list.AddCallbackWorkItem(
        base::BindLambdaForTesting([&, id](const CallbackWorkItem&) {
          actions.push_back(id);
          return id != 2;
        }),
        base::BindLambdaForTesting(
            [&, id](const CallbackWorkItem&) { actions.push_back(-id); }));
  }
  EXPECT_FALSE(list.Do());
  list.Rollback();
  EXPECT_EQ((std::vector<int>{1, 2, -2, -1}), actions);
  EXPECT_EQ((std::vector<std::pair<size_t, size_t>>{{0, 3}, {1, 3}}), observed);
}

TEST(AegisInstallProgressTest, SuccessfulWorkPublishesFinalMeasuredCount) {
  std::unique_ptr<WorkItemList> owner(WorkItem::CreateWorkItemList());
  WorkItemList& list = *owner;
  std::vector<size_t> observed;
  list.set_progress_callback(
      base::BindLambdaForTesting([&](size_t done, size_t total) {
        EXPECT_EQ(2u, total);
        observed.push_back(done);
      }));
  for (int i = 0; i != 2; ++i) {
    list.AddCallbackWorkItem(base::BindLambdaForTesting(
                                 [](const CallbackWorkItem&) { return true; }),
                             {});
  }
  EXPECT_TRUE(list.Do());
  EXPECT_EQ((std::vector<size_t>{0, 1, 2}), observed);
}
}  // namespace
}  // namespace aegis_installer
