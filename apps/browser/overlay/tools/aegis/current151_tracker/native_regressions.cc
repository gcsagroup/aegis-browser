// Copyright 2026 GCSA
// Native boundary canaries. NOT qualified until an admitted Darwin run occurs.
#include "tools/aegis/current151_tracker/bounded_runtime.h"

#include <mach-o/dyld.h>
#include <limits.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdio>
#include <cerrno>
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>

extern char** environ;

namespace {
constexpr int kHarmlessProbeExit = 73;

// Called only with a positive PID just returned by our own creation operation.
// No other thread reaps; SIGCHLD auto-reaping is disabled below. A zombie pins
// identity until this function's waitpid; ECHILD/uncertain errors revoke signals.
bool RetireCreatedProbe(pid_t pid,
                        aegis_access::bounded::QualificationSession* session,
                        int expected_exit) {
  if (pid <= 0)
    return false;
  const uint64_t start = aegis_access::bounded::MonotonicNowNs();
  const uint64_t observe_end = std::min<uint64_t>(
      session->work_end, start + 5000000000ULL);
  const uint64_t reap_end = std::min<uint64_t>(
      session->hard_end - 500000000ULL, observe_end + 2000000000ULL);
  bool stopped = false, signal_sent = false;
  for (;;) {
    int status = 0;
    const pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == pid) {
      fprintf(stderr, "probe_pid=%d actual_wait=true status=%d stopped=%s\n",
              static_cast<int>(pid), status, stopped ? "true" : "false");
      return !stopped && session->Check() &&
             WIFEXITED(status) && WEXITSTATUS(status) == expected_exit;
    }
    if (result < 0 && errno != EINTR) {
      // In particular ECHILD irrevocably removes signal authority.
      fprintf(stderr, "probe_pid=%d actual_wait=false errno=%d authority=revoked\n",
              static_cast<int>(pid), errno);
      return false;
    }
    const uint64_t now = aegis_access::bounded::MonotonicNowNs();
    if (!now || now >= reap_end) {
      fprintf(stderr, "probe_pid=%d actual_wait=false retirement=UNVERIFIED\n",
              static_cast<int>(pid));
      return false;
    }
    if (!session->Check() || now >= observe_end) {
      stopped = true;
      session->stopped = true;
      if (!signal_sent && result == 0) {
        // This exact positive child was created here and has not been reaped.
        // Keep waiting after a failed signal; never substitute an imported PID.
        signal_sent = true;
        if (kill(pid, SIGKILL) != 0)
          fprintf(stderr, "probe_pid=%d kill_errno=%d\n",
                  static_cast<int>(pid), errno);
      }
    }
    usleep(1000);
  }
}
}  // namespace

// Known-process qualification, not arbitrary escaped-descendant containment.
// The one creator waits each actual probe before reporting success.
int RunProcessCanaries(bool positive_control,
                       aegis_access::bounded::QualificationSession* session) {
  if (!session->Check())
    return 125;
  char executable[PATH_MAX], self[PATH_MAX];
  uint32_t executable_size = sizeof(executable);
  if (_NSGetExecutablePath(executable, &executable_size) != 0 ||
      !realpath(executable, self))
    return 1;
  struct sigaction child_action{};
  child_action.sa_handler = SIG_DFL;
  sigemptyset(&child_action.sa_mask);
  if (sigaction(SIGCHLD, &child_action, nullptr) != 0)
    return 1;
  if (!positive_control) {
    if (!session->Check())
      return 125;
    const pid_t forked = fork();
    if (forked == 0)
      _exit(kHarmlessProbeExit);
    const int fork_error = errno;
    if (forked > 0) {
      RetireCreatedProbe(forked, session, kHarmlessProbeExit);
      return 1;
    }
    if (fork_error != EPERM && fork_error != EACCES)
      return 1;
    if (!session->Check())
      return 125;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    const pid_t vforked = vfork();
#pragma clang diagnostic pop
    if (vforked == 0)
      _exit(kHarmlessProbeExit);
    const int vfork_error = errno;
    if (vforked > 0) {
      RetireCreatedProbe(vforked, session, kHarmlessProbeExit);
      return 1;
    }
    if (vfork_error != EPERM && vfork_error != EACCES)
      return 1;
  }
  int probe[2];
  if (pipe(probe) != 0)
    return 1;
  constexpr int kProbeFd = 198;
  if (probe[0] == kProbeFd || probe[1] == kProbeFd ||
      fcntl(probe[0], F_SETFD, FD_CLOEXEC) != 0 ||
      fcntl(probe[1], F_SETFD, FD_CLOEXEC) != 0) {
    close(probe[0]);
    close(probe[1]);
    return 1;
  }
  unsigned char random[16];
  arc4random_buf(random, sizeof(random));
  std::string nonce;
  constexpr char kHex[] = "0123456789abcdef";
  for (unsigned char byte : random) {
    nonce += kHex[byte >> 4];
    nonce += kHex[byte & 15];
  }
  std::string fd_arg = "--aegis-probe-fd=" + std::to_string(kProbeFd);
  std::string deadline_arg = "--aegis-deadline-ns=" +
                            std::to_string(session->original_deadline);
  std::string boot_arg = "--aegis-boot=" + session->boot;
  std::string nonce_arg = "--aegis-probe-nonce=" + nonce;
  char mode[] = "--aegis-spawn-probe";
  char* args[] = {self, mode, fd_arg.data(), deadline_arg.data(),
                  boot_arg.data(), nonce_arg.data(), nullptr};
  posix_spawn_file_actions_t actions;
  if (posix_spawn_file_actions_init(&actions) != 0) {
    close(probe[0]);
    close(probe[1]);
    return 1;
  }
  const bool actions_ok =
      posix_spawn_file_actions_adddup2(&actions, probe[0], kProbeFd) == 0 &&
      posix_spawn_file_actions_addclose(&actions, probe[0]) == 0 &&
      posix_spawn_file_actions_addclose(&actions, probe[1]) == 0;
  pid_t spawned = -1;
  int spawn_result = ECANCELED;
  if (actions_ok && session->Check())
    spawn_result = posix_spawn(&spawned, self, &actions, nullptr, args, environ);
  posix_spawn_file_actions_destroy(&actions);
  close(probe[0]);
  if (spawn_result == 0 && spawned > 0 &&
      write(probe[1], nonce.data(), nonce.size()) != static_cast<ssize_t>(nonce.size()))
    session->stopped = true;
  close(probe[1]);  // private nonce must be followed by actual EOF
  bool passed = false;
  if (spawn_result == 0) {
    const bool reaped = spawned > 0 &&
        RetireCreatedProbe(spawned, session, kHarmlessProbeExit);
    passed = positive_control && reaped;
  } else {
    passed = !positive_control && session->Check() &&
             (spawn_result == EPERM || spawn_result == EACCES);
  }
  passed = passed && session->Check();
  printf("%s=%s\n",
         positive_control ? "self_spawn_positive_control" : "fork_vfork_self_spawn_denied",
         passed ? "true" : "false");
  return passed ? 0 : 1;
}

namespace {
// Pure source fixtures call the PRODUCTION transition helper; no processes or
// I/O are created here. Future native execution remains separately required.
bool QualificationBoundaryFixtures() {
  using aegis_access::bounded::QualificationWorkDeadline;
  // A three-second probe-drain reserve is inside the original timer/lease.
  if (QualificationWorkDeadline(20000000000ULL, 1000000000ULL,
                                 9000000000ULL) != 7000000000ULL ||
      QualificationWorkDeadline(5000000000ULL, 1000000000ULL,
                                 9000000000ULL) != 2000000000ULL ||
      QualificationWorkDeadline(4000000000ULL, 1000000000ULL,
                                 3000000000ULL) != 0 ||
      QualificationWorkDeadline(0, 1, 10000000000ULL) != 0)
    return false;
  char binary[] = "support";
  char positive[] = "--aegis-qualification-positive-control";
  char probe[] = "--aegis-spawn-probe";
  char* allowed[] = {binary, positive, nullptr};
  char* direct[] = {binary, probe, nullptr};
  return aegis_access::bounded::ValidQualificationArguments(2, allowed) &&
         !aegis_access::bounded::ValidQualificationArguments(2, direct) &&
         !aegis_access::bounded::EnterSpawnProbe(2, direct);
}

bool OwnerBoundaryFixtures() {
  if (!QualificationBoundaryFixtures())
    return false;
  using aegis_access::bounded::ControllerObservation;
  using aegis_access::bounded::OwnerGate;
  using aegis_access::bounded::ValidateOwnerBoundary;
  using aegis_access::bounded::FinishTerminal;
  for (int phase = 0; phase < 3; ++phase) {  // write / fsync / close
    for (int event = 0; event < 4; ++event) {  // cancel / EOF / expiry / I/O error
      OwnerGate gate;
      gate.Observe(ControllerObservation::kGo);
      gate.go_sent = true;
      int operations = 0;
      bool pending = false;
      auto io = [&] {
        const bool selected = operations++ == phase;
        pending = pending || selected;
        return !(selected && event == 3);
      };
      const bool result = FinishTerminal(&gate, io, io, io, [&] {
        if (!pending || operations != 3)
          return false;
        if (event < 2)
          gate.Observe(event == 0 ? ControllerObservation::kCancel : ControllerObservation::kEof);
        return ValidateOwnerBoundary(&gate, 200, "boot", event == 2 ? 200 : 100, "boot");
      });
      if (result || operations != 3 || !gate.failure)
        return false;
      const int first = gate.failure;
      gate.Fail(126);
      if (gate.failure != first)
        return false;
    }
  }
  OwnerGate normal_terminal;
  normal_terminal.Observe(ControllerObservation::kGo);
  normal_terminal.go_sent = true;
  int normal_calls = 0;
  auto normal_io = [&] { ++normal_calls; return true; };
  if (!FinishTerminal(&normal_terminal, normal_io, normal_io, normal_io, [&] {
        return normal_calls == 3 && ValidateOwnerBoundary(&normal_terminal, 200, "boot", 199, "boot");
      }))
    return false;
  // Simulate cancellation/expiry after setup, at the production pre-create
  // gate. The guarded creation counter must remain zero.
  for (int scenario = 0; scenario < 6; ++scenario) {
    OwnerGate gate;
    gate.Observe(ControllerObservation::kGo);
    if (scenario < 3)
      gate.Observe(scenario == 0 ? ControllerObservation::kCancel :
                   scenario == 1 ? ControllerObservation::kEof : ControllerObservation::kGo);
    int creations = 0;
    if (ValidateOwnerBoundary(&gate, 200, "boot", scenario == 3 ? 200 :
                              scenario == 4 ? 0 : 100, scenario == 5 ? "other" : "boot"))
      ++creations;
    if (creations != 0)
      return false;
  }
  OwnerGate healthy;
  healthy.Observe(ControllerObservation::kGo);  // a single pending GO survives
  if (!ValidateOwnerBoundary(&healthy, 200, "boot", 100, "boot") ||
      !healthy.go_seen || healthy.go_sent)
    return false;
  healthy.go_sent = true;
  return ValidateOwnerBoundary(&healthy, 200, "boot", 199, "boot");
}
}  // namespace

int main(int argc, char** argv) {
  if (argc > 1 && std::strcmp(argv[1], "--aegis-spawn-probe") == 0)
    return aegis_access::bounded::EnterSpawnProbe(argc, argv) ? kHarmlessProbeExit : 126;
  aegis_access::bounded::QualificationSession session;
  if (!aegis_access::bounded::EnterQualification(&argc, argv, &session))
    return 126;
  if (argc == 2 && std::strcmp(argv[1], "--aegis-qualification-clock-probe") == 0) {
    printf("{\"clock\":\"%s\",\"now_ns\":%llu,\"deadline_ns\":%llu,\"boot\":\"%s\"}\n",
           aegis_access::bounded::kDeadlineClockName,
           static_cast<unsigned long long>(aegis_access::bounded::MonotonicNowNs()),
           static_cast<unsigned long long>(session.original_deadline),
           session.boot.c_str());
    return session.Check() ? 0 : 125;
  }
  if (argc == 2 && std::strcmp(argv[1], "--aegis-qualification-owner-boundaries") == 0)
    return OwnerBoundaryFixtures() && session.Check() ? 0 : 1;
  const bool positive = argc == 2 &&
      std::strcmp(argv[1], "--aegis-qualification-positive-control") == 0;
  return RunProcessCanaries(positive, &session);
}
