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
#include "base/test/bind.h"
#include "base/test/run_until.h"
#include "base/test/scoped_run_loop_timeout.h"
#include "base/test/scoped_command_line.h"
#include "base/test/scoped_path_override.h"
#include "base/test/test_future.h"
#include "base/threading/thread_restrictions.h"
#include "base/timer/timer.h"
#include "chrome/browser/aegis/access/access_buildflags.h"
#include "build/build_config.h"
#include "crypto/hash.h"
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
  ASSERT_TRUE(input);
#if BUILDFLAG(AEGIS_ALPHA_TEST_NODE_ENABLED)
  EXPECT_EQ(input->source, AccessLocalCoreSource::kAlphaBundle);
  EXPECT_EQ(input->manifest, canonical_directory.AppendASCII(
      "AegisAlphaAccess/core-manifest.json"));
  EXPECT_EQ(input->node_config, canonical_directory.AppendASCII(
      "AegisAlphaAccess/node.json"));
#else
  EXPECT_EQ(input->source, AccessLocalCoreSource::kDevFiles);
  EXPECT_EQ(input->manifest, canonical_directory.AppendASCII("dev-manifest"));
  EXPECT_EQ(input->node_config, canonical_directory.AppendASCII("dev-node"));
#endif
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
  base::ScopedTempDir directory_;
  base::FilePath binary_, state_;
  std::string pin_;
  base::test::ScopedRunLoopTimeout timeout_{FROM_HERE, base::Seconds(45)};
};

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
#endif
}  // namespace
}  // namespace aegis::access
