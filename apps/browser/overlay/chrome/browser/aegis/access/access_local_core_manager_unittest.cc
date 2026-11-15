// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_local_core_manager.h"

#include <signal.h>

#include <cerrno>

#include "base/command_line.h"
#include "base/base_paths.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/path_service.h"
#include "base/strings/string_number_conversions.h"
#include "base/synchronization/waitable_event.h"
#include "base/test/task_environment.h"
#include "base/task/thread_pool.h"
#include <atomic>
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/test/scoped_command_line.h"
#include "base/test/scoped_path_override.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/access/access_build_channel.h"
#include "chrome/browser/aegis/access/access_buildflags.h"
#include "build/build_config.h"
#include "crypto/hash.h"
#include "chrome/browser/aegis/access/access_core_log_share.h"
#include "third_party/zlib/google/compression_utils.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis::access {
namespace {
TEST(AccessLocalCoreInputTest, BuildControlsPrivateInputSource) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  const auto canonical_directory = base::MakeAbsoluteFilePath(directory.GetPath());
  ASSERT_FALSE(canonical_directory.empty());
  base::ScopedPathOverride resources(base::DIR_ASSETS, canonical_directory);
  base::test::ScopedCommandLine command;
  command.GetProcessCommandLine()->AppendSwitchPath(
      "aegis-access-dev-core-manifest", canonical_directory.AppendASCII("dev-manifest"));
  command.GetProcessCommandLine()->AppendSwitchPath(
      "aegis-access-dev-node-config", canonical_directory.AppendASCII("dev-node"));
  const auto input = ResolveAccessLocalCoreInput();
#if BUILDFLAG(AEGIS_PRIVATE_TEST_NODE_ENABLED)
  ASSERT_TRUE(input);
  EXPECT_EQ(input->source, AccessLocalCoreSource::kPrivateTestBundle);
  EXPECT_EQ(AccessChannelForCurrentBuild(), BundledAccessTestChannel());
#if BUILDFLAG(AEGIS_BETA_TEST_NODE_ENABLED)
  EXPECT_EQ(BundledAccessTestChannel(), aegis_access::ChannelNamespace::kBeta);
#else
  EXPECT_EQ(BundledAccessTestChannel(), aegis_access::ChannelNamespace::kAlpha);
#endif
  EXPECT_EQ(input->manifest, canonical_directory.AppendASCII(
      "AegisAlphaAccess/core-manifest.json"));
  EXPECT_EQ(input->node_config, canonical_directory.AppendASCII(
      "AegisAlphaAccess/node.json"));
#elif BUILDFLAG(AEGIS_DEV_LOCAL_NODE_ALLOWED)
  ASSERT_TRUE(input);
  EXPECT_EQ(input->source, AccessLocalCoreSource::kDevFiles);
  EXPECT_EQ(input->manifest, canonical_directory.AppendASCII("dev-manifest"));
  EXPECT_EQ(input->node_config, canonical_directory.AppendASCII("dev-node"));
#else
  EXPECT_FALSE(input);
#endif
}

TEST(AccessLocalCoreInputTest, ConfiguredNodeLabelMatchesEndpointOnly) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  const auto path = directory.GetPath().AppendASCII("node.json");
  constexpr char config[] = R"({"outbounds":[{"protocol":"vless",
    "settings":{"vnext":[{"address":"TEST.invalid","port":443,
    "users":[{"id":"credential-must-not-appear"}]}]},
    "streamSettings":{"network":"tcp","security":"reality"}}]})";
  ASSERT_TRUE(base::WriteFile(path, config));
  const AccessLocalCoreInput input{base::FilePath(), path};
  EXPECT_EQ(ReadConfiguredAccessNodeId(input), "0be6fae64ec1");
  ASSERT_TRUE(base::WriteFile(path, R"({"outbounds":[{"protocol":"direct"}]})"));
  EXPECT_TRUE(ReadConfiguredAccessNodeId(input).empty());
}

class AccessLocalCoreManagerTest : public testing::Test {
 protected:
  base::test::TaskEnvironment environment_;
};
TEST_F(AccessLocalCoreManagerTest, MissingBindingCannotBecomeReady) {
  AccessLocalCoreManager manager({});
  base::test::TestFuture<AccessLocalCoreReady> future;
  manager.Prepare(future.GetCallback());
  const auto& result = future.Get();
  EXPECT_FALSE(result.ready);
  EXPECT_FALSE(result.error.empty());
  EXPECT_FALSE(result.local_credentials);
  EXPECT_EQ(result.port, 0);
}
TEST_F(AccessLocalCoreManagerTest, IncorrectBinaryPinCannotLaunch) {
  base::ScopedTempDir directory;
  ASSERT_TRUE(directory.CreateUniqueTempDir());
  const auto manifest = directory.GetPath().AppendASCII("manifest.json");
  const auto node = directory.GetPath().AppendASCII("node.json");
  ASSERT_TRUE(base::WriteFile(manifest,
      R"({"binaryPath":"/usr/bin/false","binarySha256":"incorrect"})"));
  ASSERT_TRUE(base::WriteFile(node, "{}"));
  AccessLocalCoreManager manager({manifest, node});
  base::test::TestFuture<AccessLocalCoreReady> future;
  manager.Prepare(future.GetCallback());
  EXPECT_FALSE(future.Get().ready);
  EXPECT_FALSE(future.Get().local_credentials);
}
TEST_F(AccessLocalCoreManagerTest, AuthorizedNodeHttpsRecheckAndStop) {
  const auto input = ResolveAccessLocalCoreInput();
  if (!input)
    GTEST_SKIP() << "Authorized DEV core/node binding is required for real HTTPS acceptance.";
  AccessLocalCoreManager manager(*input);
  const auto unexpected_exits = std::make_shared<int>(0);
  manager.SetStoppedCallback(base::BindRepeating(
      [](std::shared_ptr<int> count, std::string) { ++*count; }, unexpected_exits));
  base::test::TestFuture<AccessLocalCoreReady> first;
  manager.Prepare(first.GetCallback());
  ASSERT_TRUE(first.Get().ready) << first.Get().error;
  ASSERT_TRUE(first.Get().local_credentials);
  EXPECT_NE(first.Get().port, 0);
  EXPECT_FALSE(first.Get().registration_id.empty());
  base::test::TestFuture<AccessLocalCoreReady> recheck;
  manager.Verify(recheck.GetCallback());
  ASSERT_TRUE(recheck.Get().ready) << recheck.Get().error;
  EXPECT_EQ(recheck.Get().registration_id, first.Get().registration_id);
  EXPECT_TRUE(recheck.Get().local_credentials->Equals(*first.Get().local_credentials));
  base::test::TestFuture<void> stopped;
  manager.Stop(stopped.GetCallback());
  ASSERT_TRUE(stopped.Wait());
  environment_.RunUntilIdle();
  EXPECT_EQ(*unexpected_exits, 0);
  base::test::TestFuture<AccessLocalCoreReady> after;
  manager.Verify(after.GetCallback());
  EXPECT_FALSE(after.Get().ready);
  EXPECT_FALSE(after.Get().local_credentials);
}

TEST_F(AccessLocalCoreManagerTest, SessionEndingStopsAllReadyCoresWithoutUiReplies) {
  const auto input = ResolveAccessLocalCoreInput();
  if (!input) GTEST_SKIP() << "Authorized private core binding is required.";
  AccessLocalCoreManager ordinary(*input);
  AccessLocalCoreManager private_profile(*input);
  base::test::TestFuture<AccessLocalCoreReady> first, second;
  ordinary.Prepare(first.GetCallback());
  private_profile.Prepare(second.GetCallback());
  ASSERT_TRUE(first.Get().ready) << first.Get().error;
  ASSERT_TRUE(second.Get().ready) << second.Get().error;
  EXPECT_NE(first.Get().port, second.Get().port);
  auto stopped = std::make_shared<base::WaitableEvent>();
  AccessLocalCoreManager::StopAllForSessionEnding(base::BindOnce(
      [](std::shared_ptr<base::WaitableEvent> event) { event->Signal(); },
      stopped));
  {
    // EndSession blocks the UI sequence. A normal Stop reply posted back to
    // that sequence would leave the child alive until its rundown times out.
    base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
    ASSERT_TRUE(stopped->TimedWait(base::Seconds(5)));
  }
  base::test::TestFuture<AccessLocalCoreReady> after_ordinary, after_private;
  ordinary.Verify(after_ordinary.GetCallback());
  private_profile.Prepare(after_private.GetCallback());
  EXPECT_FALSE(after_ordinary.Get().ready);
  EXPECT_FALSE(after_private.Get().ready);
}

#if BUILDFLAG(IS_MAC)
TEST_F(AccessLocalCoreManagerTest, AuthorizedCoreWritesRestoresAndClearsHistory) {
  auto input = ResolveAccessLocalCoreInput();
  if (!input) GTEST_SKIP() << "Authorized core/node binding required.";
  base::ScopedTempDir profile;
  ASSERT_TRUE(profile.CreateUniqueTempDir());
  auto logs = AccessCoreLogStore::Open(profile.GetPath(), CoreLogProfile::kPrivate, "warning");
  input->log_store = logs;
  AccessLocalCoreManager manager(std::move(*input));
  base::test::TestFuture<AccessLocalCoreReady> started;
  manager.Prepare(started.GetCallback());
  ASSERT_TRUE(started.Get().ready) << started.Get().error;
  base::test::TestFuture<void> stopped;
  manager.Stop(stopped.GetCallback());
  ASSERT_TRUE(stopped.Wait());
  environment_.RunUntilIdle();
  const auto text = logs->Snapshot();
  ASSERT_NE(text.find("[Warning] core: Xray "), text.npos);
  const auto directory = profile.GetPath().AppendASCII(kCoreLogDirectory);
  std::string saved;
  ASSERT_TRUE(base::ReadFileToString(directory.AppendASCII("private.log"), &saved));
  EXPECT_EQ(saved, text);
  EXPECT_FALSE(base::PathExists(directory.AppendASCII("regular.log")));
  auto restored = AccessCoreLogStore::Open(profile.GetPath(), CoreLogProfile::kPrivate, "warning");
  environment_.RunUntilIdle();
  EXPECT_EQ(restored->Snapshot(), text);
  restored->Clear();
  environment_.RunUntilIdle();
  EXPECT_FALSE(base::PathExists(directory.AppendASCII("private.log")));
}

class AccessLocalCoreFaultTest : public AccessLocalCoreManagerTest {
 protected:
  void SetUp() override {
    ASSERT_TRUE(directory_.CreateUniqueTempDir());
    base::FilePath binaries;
    ASSERT_TRUE(base::PathService::Get(base::DIR_EXE, &binaries));
    binary_ = binaries.AppendASCII("access_local_core_test_child");
    auto bytes = base::ReadFileToBytes(binary_);
    ASSERT_TRUE(bytes);
    pin_ = base::HexEncodeLower(crypto::hash::Sha256(*bytes));
    state_ = directory_.GetPath().AppendASCII("child-state.json");
  }
  AccessLocalCoreInput Input(const char* mode) {
    const auto manifest = directory_.GetPath().AppendASCII("manifest.json");
    const auto node = directory_.GetPath().AppendASCII("node.json");
    std::string json;
    EXPECT_TRUE(base::JSONWriter::Write(base::DictValue()
        .Set("binaryPath", binary_.value()).Set("binarySha256", pin_), &json));
    EXPECT_TRUE(base::WriteFile(manifest, json));
    EXPECT_TRUE(base::JSONWriter::Write(base::DictValue().Set("outbounds",
        base::ListValue().Append(base::DictValue().Set("protocol", "vless")
            .Set("tag", mode)
            .Set("streamSettings", base::DictValue()
                .Set("network", "tcp").Set("security", "reality"))
            .Set("settings", base::DictValue().Set("fixtureStateFile", state_.value())))),
        &json));
    EXPECT_TRUE(base::WriteFile(node, json));
    return {manifest, node};
  }
  std::optional<base::DictValue> State() {
    std::string json;
    return base::ReadFileToString(state_, &json)
        ? base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC) : std::nullopt;
  }
  void ExpectUnavailable(const AccessLocalCoreReady& result) {
    EXPECT_FALSE(result.ready);
    EXPECT_EQ(result.port, 0);
    EXPECT_FALSE(result.local_credentials);
    EXPECT_TRUE(result.registration_id.empty());
    EXPECT_FALSE(result.error.empty());
  }
  enum class StopInFlight { kNone, kExplicitStop, kDestruction };
  void CheckUnresponsiveSessionEnding(StopInFlight in_flight) {
    auto manager = std::make_unique<AccessLocalCoreManager>(Input("ignore-term"));
    base::test::TestFuture<AccessLocalCoreReady> prepared;
    manager->Prepare(prepared.GetCallback());
    base::test::TestFuture<void> tunnel;
    base::RepeatingTimer observation;
    observation.Start(FROM_HERE, base::Milliseconds(10),
        base::BindLambdaForTesting([&] {
      auto state = State();
      if (state && state->FindString("phase") &&
          *state->FindString("phase") == "authenticated-tunnel-held") {
        observation.Stop();
        tunnel.SetValue();
      }
    }));
    ASSERT_TRUE(tunnel.Wait());
    const auto state = State();
    ASSERT_TRUE(state);
    const auto child_pid = state->FindInt("pid");
    const auto* directory = state->FindString("configDirectory");
    ASSERT_TRUE(child_pid);
    ASSERT_TRUE(directory);
    const base::FilePath private_directory(*directory);
    ASSERT_TRUE(base::PathExists(private_directory));
    base::test::TestFuture<void> ordinary_stop;
    if (in_flight != StopInFlight::kNone) {
      if (in_flight == StopInFlight::kDestruction) manager.reset();
      else manager->Stop(ordinary_stop.GetCallback());
      // Confirm StopChild is already inside its termination wait, including
      // service destruction, before requesting the session-ending rundown.
      base::test::TestFuture<void> signal_received;
      observation.Start(FROM_HERE, base::Milliseconds(10),
          base::BindLambdaForTesting([&] {
        std::string marker;
        if (base::ReadFileToString(state_.AddExtensionASCII("sigterm"), &marker) &&
            !marker.empty()) {
          observation.Stop();
          signal_received.SetValue();
        }
      }));
      ASSERT_TRUE(signal_received.Wait());
      EXPECT_FALSE(ordinary_stop.IsReady());
    }
    auto stopped = std::make_shared<base::WaitableEvent>();
    AccessLocalCoreManager::StopAllForSessionEnding(base::BindOnce(
        [](std::shared_ptr<base::WaitableEvent> event) { event->Signal(); }, stopped));
    bool completed;
    {
      base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
      completed = stopped->TimedWait(base::Seconds(5));
      if (!completed) {
        // Preserve a behavioral RED without leaving the deliberately stubborn
        // fixture alive or waiting for the ordinary 60-second grace period.
        kill(*child_pid, SIGKILL);
        EXPECT_TRUE(stopped->TimedWait(base::Seconds(5)));
      }
    }
    EXPECT_TRUE(completed) << "Owned core exceeded the session-ending deadline";
    EXPECT_EQ(kill(*child_pid, 0), -1);
    EXPECT_EQ(errno, ESRCH);
    EXPECT_FALSE(base::PathExists(private_directory));
  }
  base::ScopedTempDir directory_;
  base::FilePath binary_, state_;
  std::string pin_;
  base::test::ScopedRunLoopTimeout timeout_{FROM_HERE, base::Seconds(45)};
};

TEST(AccessCoreLogArchiveTest, PrivateCompressedCopyWithoutOverwrite) {
  base::ScopedTempDir dir;
  ASSERT_TRUE(dir.CreateUniqueTempDir());
  const std::string text = "2026/11/11 01:02:03 [Warning] core: Xray 26.1.18 started";
  EXPECT_FALSE(WriteCoreLogArchive(dir.GetPath(), ""));
  ASSERT_TRUE(WriteCoreLogArchive(dir.GetPath(), text));
  auto path = dir.GetPath().AppendASCII(kCoreLogArchive);
  int mode = 0;
  ASSERT_TRUE(base::GetPosixFilePermissions(path, &mode));
  EXPECT_EQ(mode, 0600);
  std::string compressed, decoded;
  ASSERT_TRUE(base::ReadFileToString(path, &compressed));
  ASSERT_TRUE(compression::GzipUncompress(compressed, &decoded));
  EXPECT_EQ(decoded, text);
  EXPECT_FALSE(WriteCoreLogArchive(dir.GetPath(), "replacement"));
  ASSERT_TRUE(base::DeleteFile(path));
  auto other = dir.GetPath().AppendASCII("other");
  ASSERT_TRUE(base::WriteFile(other, "unchanged"));
  ASSERT_TRUE(base::CreateSymbolicLink(other, path));
  EXPECT_FALSE(WriteCoreLogArchive(dir.GetPath(), "replacement"));
  ASSERT_TRUE(base::ReadFileToString(other, &decoded));
  EXPECT_EQ(decoded, "unchanged");
}

TEST(AccessCoreLogArchiveTest, StartupRecoversOnlyOwnedPrivateArchives) {
  base::ScopedTempDir profile;
  base::ScopedTempDir unrelated;
  ASSERT_TRUE(profile.CreateUniqueTempDir());
  ASSERT_TRUE(unrelated.CreateUniqueTempDir());
  base::ScopedTempDir abandoned;
  ASSERT_TRUE(abandoned.CreateUniqueTempDirUnderPath(profile.GetPath(),
                                                     kCoreLogSharePrefix));
  ASSERT_TRUE(WriteCoreLogArchive(abandoned.GetPath(), "private destination"));
  const auto abandoned_path = abandoned.Take();
  const auto keep = unrelated.GetPath().AppendASCII("keep");
  ASSERT_TRUE(base::WriteFile(keep, "unrelated"));
  const auto link = profile.GetPath().AppendASCII("aegis-access-share-ABC123");
  ASSERT_TRUE(base::CreateSymbolicLink(unrelated.GetPath(), link));
  const auto other = profile.GetPath().AppendASCII("unrelated-folder");
  ASSERT_TRUE(base::CreateDirectory(other));

  EXPECT_FALSE(RecoverCoreLogArchives(profile.GetPath()));
  EXPECT_FALSE(base::PathExists(abandoned_path));
  EXPECT_TRUE(base::IsLink(link));
  EXPECT_TRUE(base::PathExists(keep));
  EXPECT_TRUE(base::PathExists(other));
  ASSERT_TRUE(base::DeleteFile(link));
  EXPECT_TRUE(RecoverCoreLogArchives(profile.GetPath()));
}

TEST(AccessCoreLogArchiveTest, QuitWhileWriteIsQueuedCleansWithoutUiReply) {
  base::test::TaskEnvironment environment(
      base::test::TaskEnvironment::ThreadPoolExecutionMode::QUEUED);
  base::ScopedTempDir parent;
  ASSERT_TRUE(parent.CreateUniqueTempDir());
  auto runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  CoreLogShareSession session;
  bool picker_opened = false;
  session.StartForTesting("private destination", base::BindLambdaForTesting(
      [&](base::FilePath, base::ScopedClosureRunner) { picker_opened = true; }),
      runner, parent.GetPath());
  std::atomic_bool created{false};
  runner->PostTask(FROM_HERE, base::BindLambdaForTesting(
      [&] { created = !base::IsDirectoryEmpty(parent.GetPath()); }));
  session.ShutDown();
  environment.RunUntilIdle();
  EXPECT_TRUE(created.load());
  EXPECT_FALSE(picker_opened);
  EXPECT_TRUE(base::IsDirectoryEmpty(parent.GetPath()));
}

TEST(AccessCoreLogArchiveTest, ClosingPickerReleasesFileAndAllowsNextShare) {
  base::test::TaskEnvironment environment;
  base::ScopedTempDir parent;
  ASSERT_TRUE(parent.CreateUniqueTempDir());
  auto runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  CoreLogShareSession session;
  base::OnceClosure picker_callback;
  auto show_picker = [&](base::FilePath path, base::ScopedClosureRunner release) {
    ASSERT_TRUE(base::PathExists(path));
    picker_callback = base::BindOnce([](base::ScopedClosureRunner) {}, std::move(release));
  };
  for (int attempt = 0; attempt < 2; ++attempt) {
    session.StartForTesting("text", base::BindLambdaForTesting(show_picker),
                            runner, parent.GetPath());
    environment.RunUntilIdle();
    ASSERT_TRUE(picker_callback);
    picker_callback.Reset();
    environment.RunUntilIdle();
    EXPECT_TRUE(base::IsDirectoryEmpty(parent.GetPath()));
  }
}

bool WaitWithoutUiReplies(const std::shared_ptr<base::WaitableEvent>& event) {
  base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
  return event->TimedWait(base::Seconds(5));
}

TEST(AccessCoreLogArchiveTest, FailedCleanupBlocksNewArchiveUntilRecovery) {
  base::test::TaskEnvironment environment;
  base::ScopedTempDir parent;
  ASSERT_TRUE(parent.CreateUniqueTempDir());
  CoreLogShareSession session;
  base::FilePath folder;
  base::ScopedClosureRunner release;
  std::optional<bool> cleaned;
  session.Start(parent.GetPath(), "private destination",
                base::BindLambdaForTesting(
                    [&](base::FilePath file, base::ScopedClosureRunner cleanup) {
                      folder = file.DirName();
                      release = std::move(cleanup);
                    }),
                base::BindLambdaForTesting([&](bool ok) { cleaned = ok; }));
  environment.RunUntilIdle();
  ASSERT_FALSE(folder.empty());
  // Make the parent non-writable. This prevents removing the archive
  // directory while keeping its identity intact for the retry.
  ASSERT_TRUE(base::SetPosixFilePermissions(parent.GetPath(), 0500));
  release.RunAndReset();
  environment.RunUntilIdle();
  EXPECT_EQ(cleaned, false);
  EXPECT_TRUE(base::PathExists(folder));
  bool blocked = false;
  session.Start(parent.GetPath(), "another destination",
                base::BindLambdaForTesting(
                    [&](base::FilePath file, base::ScopedClosureRunner) {
                      blocked = file.empty();
                    }),
                base::BindLambdaForTesting([&](bool ok) { cleaned = ok; }));
  environment.RunUntilIdle();
  EXPECT_TRUE(blocked);
  EXPECT_EQ(cleaned, false);
  EXPECT_TRUE(base::PathExists(folder));
  ASSERT_TRUE(base::SetPosixFilePermissions(parent.GetPath(), 0700));

  bool written = false;
  session.Start(parent.GetPath(), "new destination",
                base::BindLambdaForTesting(
                    [&](base::FilePath file, base::ScopedClosureRunner) {
                      written = !file.empty() && base::PathExists(file);
                    }),
                base::BindLambdaForTesting([&](bool ok) { cleaned = ok; }));
  environment.RunUntilIdle();
  EXPECT_TRUE(written);
  EXPECT_EQ(cleaned, true);
  EXPECT_TRUE(base::IsDirectoryEmpty(parent.GetPath()));
}

TEST(AccessCoreLogArchiveTest, SessionEndingCleansAnOpenPickerWithoutUiReplies) {
  base::test::TaskEnvironment environment;
  base::ScopedTempDir parent;
  ASSERT_TRUE(parent.CreateUniqueTempDir());
  auto runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  base::FilePath archive;
  base::ScopedClosureRunner picker_release;
  CoreLogShareSession session;
  session.StartForTesting("private destination", base::BindLambdaForTesting(
      [&](base::FilePath path, base::ScopedClosureRunner release) {
        archive = path;
        picker_release = std::move(release);
      }), runner, parent.GetPath());
  environment.RunUntilIdle();
  ASSERT_FALSE(archive.empty());
  ASSERT_TRUE(base::PathExists(archive));
  auto completed = std::make_shared<base::WaitableEvent>();
  AccessLocalCoreManager::StopAllForSessionEnding(base::BindLambdaForTesting(
      [completed] { completed->Signal(); }));
  EXPECT_TRUE(WaitWithoutUiReplies(completed));
  EXPECT_FALSE(base::PathExists(archive));
  EXPECT_TRUE(base::IsDirectoryEmpty(parent.GetPath()));
}

TEST(AccessCoreLogArchiveTest, SessionEndingIncludesADestroyedShareOwner) {
  base::test::TaskEnvironment environment;
  base::ScopedTempDir parent;
  ASSERT_TRUE(parent.CreateUniqueTempDir());
  auto runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::WithBaseSyncPrimitives(),
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  bool picker_opened = false;
  auto session = std::make_unique<CoreLogShareSession>();
  session->StartForTesting("private destination", base::BindLambdaForTesting(
      [&](base::FilePath, base::ScopedClosureRunner) { picker_opened = true; }),
      runner, parent.GetPath());
  auto written = std::make_shared<base::WaitableEvent>();
  runner->PostTask(FROM_HERE, base::BindLambdaForTesting(
      [written] { written->Signal(); }));
  ASSERT_TRUE(WaitWithoutUiReplies(written));
  ASSERT_FALSE(base::IsDirectoryEmpty(parent.GetPath()));
  auto blocked = std::make_shared<base::WaitableEvent>();
  auto resume = std::make_shared<base::WaitableEvent>();
  base::ScopedClosureRunner unblock(base::BindLambdaForTesting(
      [resume] { resume->Signal(); }));
  runner->PostTask(FROM_HERE, base::BindLambdaForTesting([blocked, resume] {
    blocked->Signal();
    resume->Wait();
  }));
  ASSERT_TRUE(WaitWithoutUiReplies(blocked));
  session.reset();
  auto completed = std::make_shared<base::WaitableEvent>();
  AccessLocalCoreManager::StopAllForSessionEnding(base::BindLambdaForTesting(
      [completed] { completed->Signal(); }));
  unblock.RunAndReset();
  EXPECT_TRUE(WaitWithoutUiReplies(completed));
  EXPECT_FALSE(picker_opened);
  EXPECT_TRUE(base::IsDirectoryEmpty(parent.GetPath()));
}

TEST(AccessCoreLogArchiveTest, SessionEndingSuppressesAQueuedArchiveWrite) {
  base::test::TaskEnvironment environment;
  base::ScopedTempDir parent;
  ASSERT_TRUE(parent.CreateUniqueTempDir());
  auto runner = base::ThreadPool::CreateSequencedTaskRunner(
      {base::MayBlock(), base::WithBaseSyncPrimitives(),
       base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  auto blocked = std::make_shared<base::WaitableEvent>();
  auto resume = std::make_shared<base::WaitableEvent>();
  base::ScopedClosureRunner unblock(base::BindLambdaForTesting(
      [resume] { resume->Signal(); }));
  runner->PostTask(FROM_HERE, base::BindLambdaForTesting([blocked, resume] {
    blocked->Signal();
    resume->Wait();
  }));
  ASSERT_TRUE(WaitWithoutUiReplies(blocked));
  bool replied = false;
  CoreLogShareSession session;
  session.StartForTesting("private destination", base::BindLambdaForTesting(
      [&](base::FilePath path, base::ScopedClosureRunner) {
        EXPECT_TRUE(path.empty());
        replied = true;
      }), runner, parent.GetPath());
  auto completed = std::make_shared<base::WaitableEvent>();
  AccessLocalCoreManager::StopAllForSessionEnding(base::BindLambdaForTesting(
      [completed] { completed->Signal(); }));
  unblock.RunAndReset();
  EXPECT_TRUE(WaitWithoutUiReplies(completed));
  EXPECT_FALSE(replied);
  EXPECT_TRUE(base::IsDirectoryEmpty(parent.GetPath()));
  environment.RunUntilIdle();
  EXPECT_TRUE(replied);
}

TEST_F(AccessLocalCoreFaultTest, MissingDiagnosticPipeStillStartsPinnedChild) {
  auto input = Input("unauthenticated-response");
  auto log = base::MakeRefCounted<AccessCoreLogStore>();
  input.log_store = log;
  input.create_log_pipe_for_testing =
      [](base::ScopedFD*, base::ScopedFD*, bool) { return false; };
  AccessLocalCoreManager manager(std::move(input));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
  ASSERT_TRUE(State());
  EXPECT_EQ(*State()->FindString("phase"), "unauthenticated-response");
  EXPECT_TRUE(log->Snapshot().empty());
}

TEST_F(AccessLocalCoreFaultTest, CapturesDiagnosticWithoutAdmittingFailedChild) {
  auto input = Input("exit-with-diagnostic");
  auto log = base::MakeRefCounted<AccessCoreLogStore>();
  input.log_store = log;
  AccessLocalCoreManager manager(std::move(input));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
  EXPECT_EQ(log->Snapshot(), "2026/11/11 12:10:09 [Warning] core: Xray 1.2.3 started");
  auto [level, generation] = log->LaunchConfig();
  log->SetLevel("none");
  log->SetLevel("debug");
  log->Add(generation, log->clear_epoch(), "2026/11/11 12:10:09 [Warning] core: Xray 1.2.3 started", {});
  EXPECT_TRUE(log->Snapshot().empty());
}

TEST_F(AccessLocalCoreFaultTest, RejectsMultilineNodeBeforeStartingChild) {
  auto input = Input("exit-with-diagnostic\n2026/11/11 12:10:09 [Warning] core: Xray 12345678.1 started");
  auto log = base::MakeRefCounted<AccessCoreLogStore>();
  input.log_store = log;
  AccessLocalCoreManager manager(std::move(input));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
  EXPECT_FALSE(State());
  EXPECT_TRUE(log->Snapshot().empty());
}

TEST_F(AccessLocalCoreFaultTest, PinnedChildExitCannotBecomeReady) {
  AccessLocalCoreManager manager(Input("exit-before-listen"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
}

TEST_F(AccessLocalCoreFaultTest, ListeningWithoutAuthenticatedTlsCannotBecomeReady) {
  AccessLocalCoreManager manager(Input("unauthenticated-response"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
  ASSERT_TRUE(State());
  EXPECT_EQ(*State()->FindString("phase"), "unauthenticated-response");
}

TEST_F(AccessLocalCoreFaultTest, RejectedProxyCredentialsCannotBecomeReady) {
  AccessLocalCoreManager manager(Input("reject-auth"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
  EXPECT_EQ(prepared.Get().error, "Local proxy authentication failed.");
  auto state = State();
  ASSERT_TRUE(state);
  EXPECT_GE(state->FindInt("requests").value_or(0), 2);
}

TEST_F(AccessLocalCoreFaultTest, AuthenticatedIngressIsNotTargetReadiness) {
  AccessLocalCoreManager manager(Input("target-unavailable"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
  auto state = State();
  ASSERT_TRUE(state);
  EXPECT_EQ(*state->FindString("phase"), "authenticated-target-unavailable");
}

TEST_F(AccessLocalCoreFaultTest, StopCancelsARealPendingProbe) {
  AccessLocalCoreManager manager(Input("hold-tunnel"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  // The child is a separate process. Its state-file write cannot wake an idle
  // UI RunLoop, so observe that handshake explicitly before requesting Stop.
  base::test::TestFuture<void> tunnel;
  base::RepeatingTimer observation;
  observation.Start(FROM_HERE, base::Milliseconds(10),
      base::BindLambdaForTesting([&] {
    auto state = State();
    if (state && state->FindString("phase") &&
        *state->FindString("phase") == "authenticated-tunnel-held") {
      observation.Stop();
      tunnel.SetValue();
    }
  }));
  ASSERT_TRUE(tunnel.Wait());
  EXPECT_FALSE(prepared.IsReady());
  base::test::TestFuture<void> stopped;
  manager.Stop(stopped.GetCallback());
  ASSERT_TRUE(stopped.Wait());
  ExpectUnavailable(prepared.Get());
  EXPECT_EQ(prepared.Get().error, "Proxy preparation was cancelled.");
  base::test::TestFuture<AccessLocalCoreReady> after;
  manager.Verify(after.GetCallback());
  ExpectUnavailable(after.Get());
}

TEST_F(AccessLocalCoreFaultTest, SessionEndingCancelsPendingAuthenticatedProbe) {
  AccessLocalCoreManager manager(Input("hold-tunnel"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  base::test::TestFuture<void> tunnel;
  base::RepeatingTimer observation;
  observation.Start(FROM_HERE, base::Milliseconds(10),
      base::BindLambdaForTesting([&] {
    auto state = State();
    if (state && state->FindString("phase") &&
        *state->FindString("phase") == "authenticated-tunnel-held") {
      observation.Stop();
      tunnel.SetValue();
    }
  }));
  ASSERT_TRUE(tunnel.Wait());
  ASSERT_FALSE(prepared.IsReady());
  const auto child_pid = State()->FindInt("pid");
  ASSERT_TRUE(child_pid);
  ASSERT_EQ(kill(*child_pid, 0), 0);
  auto stopped = std::make_shared<base::WaitableEvent>();
  AccessLocalCoreManager::StopAllForSessionEnding(base::BindOnce(
      [](std::shared_ptr<base::WaitableEvent> event) { event->Signal(); },
      stopped));
  {
    base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
    ASSERT_TRUE(stopped->TimedWait(base::Seconds(5)));
  }
  EXPECT_EQ(kill(*child_pid, 0), -1);
  EXPECT_EQ(errno, ESRCH);
  ExpectUnavailable(prepared.Get());
  EXPECT_EQ(prepared.Get().error, "Proxy preparation was cancelled.");
  base::test::TestFuture<AccessLocalCoreReady> after;
  manager.Prepare(after.GetCallback());
  ExpectUnavailable(after.Get());
  EXPECT_EQ(after.Get().error, "The local proxy is shutting down.");
}

TEST_F(AccessLocalCoreFaultTest, SessionEndingIncludesPendingServiceDestruction) {
  auto manager = std::make_unique<AccessLocalCoreManager>(Input("hold-tunnel"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager->Prepare(prepared.GetCallback());
  base::test::TestFuture<void> tunnel;
  base::RepeatingTimer observation;
  observation.Start(FROM_HERE, base::Milliseconds(10),
      base::BindLambdaForTesting([&] {
    auto state = State();
    if (state && state->FindString("phase") &&
        *state->FindString("phase") == "authenticated-tunnel-held") {
      observation.Stop();
      tunnel.SetValue();
    }
  }));
  ASSERT_TRUE(tunnel.Wait());
  const auto child_pid = State()->FindInt("pid");
  ASSERT_TRUE(child_pid);
  ASSERT_EQ(kill(*child_pid, 0), 0);

  // Service destruction schedules Worker destruction and a thread-pool join.
  // EndSession must include the outstanding child even if no UI replies run.
  manager.reset();
  auto stopped = std::make_shared<base::WaitableEvent>();
  AccessLocalCoreManager::StopAllForSessionEnding(base::BindOnce(
      [](std::shared_ptr<base::WaitableEvent> event) { event->Signal(); },
      stopped));
  {
    base::ScopedAllowBaseSyncPrimitivesForTesting allow_wait;
    ASSERT_TRUE(stopped->TimedWait(base::Seconds(5)));
  }
  EXPECT_EQ(kill(*child_pid, 0), -1);
  EXPECT_EQ(errno, ESRCH);
}

TEST_F(AccessLocalCoreFaultTest, StalledAuthenticatedTunnelTimesOut) {
  AccessLocalCoreManager manager(Input("hold-tunnel"));
  base::test::TestFuture<AccessLocalCoreReady> prepared;
  manager.Prepare(prepared.GetCallback());
  ExpectUnavailable(prepared.Get());
  EXPECT_EQ(prepared.Get().error, "Proxy connectivity check timed out.");
  auto state = State();
  ASSERT_TRUE(state);
  EXPECT_EQ(*state->FindString("phase"), "authenticated-tunnel-held");
}

TEST_F(AccessLocalCoreFaultTest, SessionEndingEscalatesUnresponsiveChild) {
  CheckUnresponsiveSessionEnding(StopInFlight::kNone);
}
TEST_F(AccessLocalCoreFaultTest, SessionEndingInterruptsUnresponsiveOrdinaryStop) {
  CheckUnresponsiveSessionEnding(StopInFlight::kExplicitStop);
}
TEST_F(AccessLocalCoreFaultTest, SessionEndingInterruptsUnresponsiveDestruction) {
  CheckUnresponsiveSessionEnding(StopInFlight::kDestruction);
}
#endif
}  // namespace
}  // namespace aegis::access
