// Copyright 2026 GCSA
// 验证 Windows 核心启动的摘要、环境隔离和进程树清理契约，不连接外部代理节点。
#include "chrome/browser/aegis/access/access_local_core_manager.h"

#include <windows.h>

#include <memory>
#include <string>

#include "base/base_paths.h"
#include "base/base_paths_win.h"
#include "base/command_line.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_writer.h"
#include "base/path_service.h"
#include "base/process/process.h"
#include "base/scoped_environment_variable_override.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/synchronization/waitable_event.h"
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/scoped_command_line.h"
#include "base/test/scoped_path_override.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/test/task_environment.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "base/timer/timer.h"
#include "base/values.h"
#include "base/win/security_descriptor.h"
#include "chrome/browser/aegis/access/access_build_channel.h"
#include "chrome/browser/aegis/access/access_buildflags.h"
#include "chrome/browser/aegis/access/access_private_files_win.h"
#include "chrome/browser/aegis/access/access_local_core_win.h"
#include "crypto/hash.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {

TEST(AccessLocalCoreWinInputTest, BuildControlsLocalBinding) {
  base::test::ScopedCommandLine command;
  auto* line = command.GetProcessCommandLine();
  line->RemoveSwitch("aegis-access-dev-core-manifest");
  line->RemoveSwitch("aegis-access-dev-node-config");
#if !BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
  EXPECT_FALSE(ResolveAccessLocalCoreInput());
#endif
  line->AppendSwitchPath("aegis-access-dev-core-manifest",
                         base::FilePath(L"C:\\测试\\manifest.json"));
#if !BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
  EXPECT_FALSE(ResolveAccessLocalCoreInput());
#endif
  line->AppendSwitchPath("aegis-access-dev-node-config",
                         base::FilePath(L"C:\\测试\\node.json"));
  const auto input = ResolveAccessLocalCoreInput();
#if BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
  ASSERT_TRUE(input);
  EXPECT_EQ(input->source, AccessLocalCoreSource::kPrivateTestBundle);
  EXPECT_EQ(input->manifest.BaseName().MaybeAsASCII(), "core-manifest.json");
  EXPECT_EQ(input->node_config.BaseName().MaybeAsASCII(), "node.json");
#else
  const bool dev = BUILDFLAG(AEGIS_DEV_LOCAL_NODE_ALLOWED) &&
                   AccessChannelForCurrentBuild() ==
                       aegis_access::ChannelNamespace::kDev;
  ASSERT_EQ(input.has_value(), dev);
  if (input) {
    EXPECT_EQ(input->source, AccessLocalCoreSource::kDevFiles);
    EXPECT_EQ(input->manifest, base::FilePath(L"C:\\测试\\manifest.json"));
    EXPECT_EQ(input->node_config, base::FilePath(L"C:\\测试\\node.json"));
  }
#endif
}

class AccessLocalCoreWinTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(root_.CreateUniqueTempDir());
    profile_ = root_.GetPath().AppendASCII("Local AppData");
    ASSERT_TRUE(CreatePrivateAccessDirectory(profile_));
    profile_override_ =
        std::make_unique<base::ScopedPathOverride>(base::DIR_LOCAL_APP_DATA,
                                                   profile_);
    base::FilePath bin;
    ASSERT_TRUE(base::PathService::Get(base::DIR_EXE, &bin));
    binary_ = root_.GetPath().Append(L"核心 fixture.exe");
    ASSERT_TRUE(base::CopyFile(
        bin.AppendASCII("access_local_core_win_test_child.exe"), binary_));
    auto bytes = base::ReadFileToBytes(binary_);
    ASSERT_TRUE(bytes);
    pin_ = base::HexEncodeLower(crypto::hash::Sha256(*bytes));
    input_.manifest = root_.GetPath().AppendASCII("manifest.json");
    input_.node_config = root_.GetPath().AppendASCII("node.json");
    ASSERT_TRUE(base::WriteFile(input_.node_config, R"({
      "outbounds": [{"protocol": "vless",
        "streamSettings": {"network": "tcp", "security": "reality"}}]
    })"));
  }

  void WriteManifest(const std::string& pin) {
    auto manifest = base::WriteJson(base::DictValue()
        .Set("binaryPath", binary_.AsUTF8Unsafe())
        .Set("binarySha256", pin));
    ASSERT_TRUE(manifest);
    ASSERT_TRUE(base::WriteFile(input_.manifest, *manifest));
  }

  base::FilePath FindCoreDirectory() {
    base::FileEnumerator entries(profile_, false,
                                 base::FileEnumerator::DIRECTORIES,
                                 L"AegisAccess-*");
    return entries.Next();
  }

  void VerifyShutdown(bool session_ending) {
    ASSERT_NO_FATAL_FAILURE(WriteManifest(pin_));
    AccessLocalCoreManager manager(input_);
    base::test::TestFuture<AccessLocalCoreReady> ready;
    manager.Prepare(ready.GetCallback());
    base::FilePath directory;
    std::string pids;
    base::test::ScopedRunLoopTimeout timeout(FROM_HERE, base::Seconds(10));
    base::RepeatingTimer poll;
    poll.Start(FROM_HERE, base::Milliseconds(20), base::DoNothing());
    ASSERT_TRUE(base::test::RunUntil([&] {
      directory = FindCoreDirectory();
      if (directory.empty()) return false;
      if (!base::PathExists(directory.AppendASCII("grandchild-ready"))) {
        return false;
      }
      return base::ReadFileToString(directory.AppendASCII("fixture-pids"),
                                    &pids) &&
             pids.ends_with('\n');
    }));
    poll.Stop();
    EXPECT_FALSE(ready.IsReady());
    auto acl = base::win::SecurityDescriptor::FromFile(
        directory, DACL_SECURITY_INFORMATION);
    ASSERT_TRUE(acl && acl->dacl());
    EXPECT_TRUE(acl->dacl_protected());
    EXPECT_EQ(acl->dacl()->get()->AceCount, 1);
    auto config_acl = base::win::SecurityDescriptor::FromFile(
        directory.AppendASCII("config.json"), DACL_SECURITY_INFORMATION);
    ASSERT_TRUE(config_acl && config_acl->dacl());
    EXPECT_EQ(config_acl->dacl()->get()->AceCount, 1);

    auto ids = base::SplitStringPiece(pids, " ", base::TRIM_WHITESPACE,
                                      base::SPLIT_WANT_NONEMPTY);
    ASSERT_EQ(ids.size(), 2u);
    unsigned child_pid = 0;
    unsigned grandchild_pid = 0;
    ASSERT_TRUE(base::StringToUint(ids[0], &child_pid));
    ASSERT_TRUE(base::StringToUint(ids[1], &grandchild_pid));
    auto child = base::Process::Open(child_pid);
    auto grandchild = base::Process::Open(grandchild_pid);
    ASSERT_TRUE(child.IsValid() && grandchild.IsValid());
    if (session_ending) {
      auto stopped = std::make_shared<base::WaitableEvent>();
      AccessLocalCoreManager::StopAllForSessionEnding(
          base::BindLambdaForTesting([stopped] { stopped->Signal(); }));
      base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
      ASSERT_TRUE(stopped->TimedWait(base::Seconds(5)));
    } else {
      base::test::TestFuture<void> stopped;
      manager.Stop(stopped.GetCallback());
      ASSERT_TRUE(stopped.Wait());
    }
    {
      base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
      EXPECT_TRUE(child.WaitForExitWithTimeout(base::Seconds(1), nullptr));
      EXPECT_TRUE(grandchild.WaitForExitWithTimeout(base::Seconds(1), nullptr));
    }
    EXPECT_FALSE(base::PathExists(directory));
    ASSERT_TRUE(ready.Wait());
    EXPECT_FALSE(ready.Get().ready);
    EXPECT_FALSE(ready.Get().local_credentials);
  }

  base::test::TaskEnvironment environment_;
  base::ScopedTempDir root_;
  std::unique_ptr<base::ScopedPathOverride> profile_override_;
  base::FilePath profile_;
  base::FilePath binary_;
  std::string pin_;
  AccessLocalCoreInput input_;
};

TEST_F(AccessLocalCoreWinTest, WrongPinCannotLaunchOrPublish) {
  ASSERT_NO_FATAL_FAILURE(WriteManifest(std::string(64, '0')));
  AccessLocalCoreManager manager(input_);
  base::test::TestFuture<AccessLocalCoreReady> ready;
  manager.Prepare(ready.GetCallback());
  EXPECT_FALSE(ready.Get().ready);
  EXPECT_FALSE(ready.Get().local_credentials);
  EXPECT_EQ(ready.Get().port, 0);
  EXPECT_TRUE(FindCoreDirectory().empty());
}

TEST_F(AccessLocalCoreWinTest, NetworkEnvironmentRejectsParentSecretsAndOverrides) {
  // 即使父进程污染 SystemRoot 或携带凭据/代理，也只允许可信系统目录进入核心。
  base::ScopedEnvironmentVariableOverride root("SystemRoot", "Z:\\untrusted");
  base::ScopedEnvironmentVariableOverride secret("AEGIS_CORE_TEST_SECRET", "fixture-only");
  base::ScopedEnvironmentVariableOverride proxy("HTTP_PROXY", "http://127.0.0.1:9");
  base::ScopedEnvironmentVariableOverride path("PATH", "Z:\\untrusted");
  base::CommandLine command(binary_);
  command.AppendArg("--access-fixture-environment");
  base::win::ScopedHandle job;
  auto child = LaunchOwnedCore(command, root_.GetPath(), job);
  ASSERT_TRUE(child.IsValid());
  int exit_code = -1;
  base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
  ASSERT_TRUE(child.WaitForExitWithTimeout(base::Seconds(5), &exit_code));
  EXPECT_EQ(exit_code, 0);
}

TEST_F(AccessLocalCoreWinTest, StopCleansProcessTreeAndPrivateConfig) {
  VerifyShutdown(false);
}

TEST_F(AccessLocalCoreWinTest, SessionEndingCleansWithoutUiReplies) {
  VerifyShutdown(true);
}

}  // namespace
}  // namespace aegis::access
