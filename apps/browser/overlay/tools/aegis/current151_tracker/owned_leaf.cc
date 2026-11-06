// Copyright 2026 GCSA
// Sole creator/reaper of one direct child. This is NOT a GN/Ninja executor.
#include "tools/aegis/current151_tracker/bounded_runtime.h"

#include <fcntl.h>
#include <poll.h>
#include <sandbox.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <algorithm>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

namespace {
using aegis_access::bounded::BootIdentity;
using aegis_access::bounded::MonotonicNowNs;
using aegis_access::bounded::OwnerGate;
using aegis_access::bounded::FreshOwnerBoundary;

class OwnedChild {
 public:
  OwnedChild(const OwnedChild&) = delete;
  OwnedChild& operator=(const OwnedChild&) = delete;
  static OwnedChild Create() { return OwnedChild(fork()); }
  bool IsChild() const { return pid_ == 0; }
  bool Created() const { return pid_ > 0; }
  bool Retired() const { return retired_; }
  bool Reaped() const { return reaped_; }
  int Status() const { return status_; }

  bool Poll() {
    if (retired_ || pid_ <= 0)
      return false;
    const pid_t result = waitpid(pid_, &status_, WNOHANG);
    // Return to the caller's fixed deadline/cleanup loop after EINTR.
    if (result == -1 && errno == EINTR)
      return true;
    if (result == 0)
      return true;
    // A successful reap or ANY uncertain wait failure permanently revokes
    // signal authority. ECHILD never permits importing/recovering a PID.
    retired_ = true;
    reaped_ = result == pid_;
    return false;
  }

  bool KillOwned() {
    // A zombie remains owned until our reap; no other reaper or SIGCHLD
    // auto-reap is allowed. This is the only kill site and never targets a group.
    return Poll() && kill(pid_, SIGKILL) == 0;
  }

 private:
  explicit OwnedChild(pid_t pid) : pid_(pid) {}
  const pid_t pid_;
  bool retired_ = false;
  bool reaped_ = false;
  int status_ = 0;
};

bool ParseNumber(std::string_view value, uint64_t* output) {
  const auto result = std::from_chars(value.data(), value.data() + value.size(), *output);
  return result.ec == std::errc() && result.ptr == value.data() + value.size();
}

bool ReadProfile(const char* path, bool positive_control, std::string* profile) {
  const int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0)
    return false;
  struct stat info{};
  bool valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size <= 65536;
  char bytes[4096];
  while (valid) {
    const ssize_t count = read(fd, bytes, sizeof(bytes));
    if (count == 0)
      break;
    if (count < 0 || profile->size() + count > 65536) {
      valid = false;
      break;
    }
    profile->append(bytes, count);
  }
  close(fd);
  // The supplied exact profile defines admitted reads/private writes/services.
  // Qualification's matching positive control permits its single harmless
  // self-probe. Only that exact support payload selects the positive profile;
  // tracker and ordinary qualification always enforce process-fork denial.
  // Both profiles must be separately granted and match in all other rules.
  profile->append(positive_control ? "\n(allow process-fork)\n" : "\n(deny process-fork)\n");
  profile->append("(deny network*)\n");
  return valid && profile->find('\0') == std::string::npos;
}

std::string JsonString(std::string_view value) {
  std::string result = "\"";
  for (unsigned char byte : value) {
    if (byte == '"' || byte == '\\') {
      result += '\\';
      result += static_cast<char>(byte);
    } else if (byte < 32) {
      char escaped[7];
      snprintf(escaped, sizeof(escaped), "\\u%04x", static_cast<unsigned>(byte));
      result += escaped;
    } else {
      result += static_cast<char>(byte);
    }
  }
  return result + "\"";
}

bool ArmDeadline(uint64_t deadline) {
  const uint64_t now = MonotonicNowNs();
  if (!now || now >= deadline)
    return false;
  const uint64_t micros = std::min<uint64_t>((deadline - now) / 1000, 120000000);
  if (!micros)
    return false;
  struct sigaction alarm_action{};
  alarm_action.sa_handler = SIG_DFL;
  sigemptyset(&alarm_action.sa_mask);
  if (sigaction(SIGALRM, &alarm_action, nullptr) != 0)
    return false;
  sigset_t alarms;
  sigemptyset(&alarms);
  sigaddset(&alarms, SIGALRM);
  if (sigprocmask(SIG_UNBLOCK, &alarms, nullptr) != 0)
    return false;
  itimerval timer{};
  timer.it_value.tv_sec = micros / 1000000;
  timer.it_value.tv_usec = micros % 1000000;
  return setitimer(ITIMER_REAL, &timer, nullptr) == 0;
}

bool InstallBoundary(const std::string& profile) {
  const rlimit core{0, 0}, files{8 * 1024 * 1024, 8 * 1024 * 1024}, cpu{120, 120};
  if (setrlimit(RLIMIT_CORE, &core) != 0 || setrlimit(RLIMIT_FSIZE, &files) != 0 ||
      setrlimit(RLIMIT_CPU, &cpu) != 0 ||
      profile.empty())
    return false;
  char* error = nullptr;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const int result = sandbox_init(profile.c_str(), 0, &error);
  sandbox_free_error(error);
#pragma clang diagnostic pop
  return result == 0;
}
}  // namespace

int main(int argc, char** argv) {
  // Deadline/boot are the ORIGINAL values. No UTC parsing or lease renewal.
  // argv: owner deadline-ns boot profile receipt cwd -- absolute-leaf args...
  uint64_t deadline = 0;
  const uint64_t now = MonotonicNowNs();
  const std::string boot = BootIdentity();
  if (argc < 8 || std::strcmp(argv[6], "--") != 0 || argv[7][0] != '/' ||
      !ParseNumber(argv[1], &deadline) || boot.empty() || !now || boot != argv[2] ||
      deadline <= now || deadline - now > 8ULL * 3600 * 1000000000)
    return 126;
  const std::string_view leaf(argv[7]);
  const bool support = leaf.substr(leaf.find_last_of('/') + 1) ==
                       "current151_tracker_support_regressions";
  if (support ? !aegis_access::bounded::ValidQualificationArguments(argc - 7, argv + 7)
              : !aegis_access::bounded::ValidTrackerArguments(argc - 7, argv + 7))
    return 126;
  const bool positive_control = support && argc == 9 &&
      std::strcmp(argv[8], "--aegis-qualification-positive-control") == 0;
  const bool noncreating_support = support && argc == 9 &&
      (std::strcmp(argv[8], "--aegis-qualification-clock-probe") == 0 ||
       std::strcmp(argv[8], "--aegis-qualification-owner-boundaries") == 0);
  // Bind the receipt to this exact owner invocation before setup/birth.
  std::string command = "[";
  for (int i = 0; i < argc; ++i) {
    if (std::strlen(argv[i]) > 16384)
      return 126;
    if (i)
      command += ',';
    command += JsonString(argv[i]);
    if (command.size() > 16384)
      return 126;
  }
  command += ']';
  struct stat input_info{};
  const int flags = fcntl(STDIN_FILENO, F_GETFL);
  if (fstat(STDIN_FILENO, &input_info) != 0 || !S_ISFIFO(input_info.st_mode) ||
      flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) != 0)
    return 126;
  OwnerGate gate;
  std::string profile;
  if (!ReadProfile(argv[3], positive_control, &profile))
    return 126;
  const int receipt = open(argv[4], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
  if (receipt < 0)
    return 126;
  int control[2];
  if (pipe(control) != 0) {
    close(receipt);
    return 126;
  }
  // Fail instead of inheriting a control descriptor that the bounded entry
  // cannot validate. Typical private invocations allocate descriptors 3..10.
  if (control[0] < 3 || control[0] > 1024) {
    close(control[0]);
    close(control[1]);
    close(receipt);
    return 126;
  }
  std::vector<std::string> storage;
  storage.emplace_back(argv[7]);
  for (int i = 8; i < argc; ++i)
    storage.emplace_back(argv[i]);
  storage.push_back("--aegis-control-fd=" + std::to_string(control[0]));
  storage.push_back("--aegis-deadline-ns=" + std::to_string(deadline));
  storage.push_back("--aegis-boot=" + std::string(argv[2]));
  std::vector<char*> child_argv;
  for (std::string& arg : storage)
    child_argv.push_back(arg.data());
  child_argv.push_back(nullptr);
  // Single thread, default SIGCHLD, exclusive waitpid ownership throughout.
  struct sigaction child_action{};
  child_action.sa_handler = SIG_DFL;
  sigemptyset(&child_action.sa_mask);
  if (sigaction(SIGCHLD, &child_action, nullptr) != 0) {
    close(control[0]);
    close(control[1]);
    close(receipt);
    return 126;
  }
  if (signal(SIGPIPE, SIG_IGN) == SIG_ERR ||
      !FreshOwnerBoundary(STDIN_FILENO, &gate, deadline, boot)) {
    close(control[0]);
    close(control[1]);
    close(receipt);
    return 125;
  }
  // No setup or I/O intervenes between the fresh boundary and creation.
  OwnedChild child = OwnedChild::Create();
  if (child.IsChild()) {
    // Arm first, including the pre-exec descriptor/setup interval. This timer
    // is not renewed by exec or by the bounded entry's watchdog.
    if (!ArmDeadline(deadline))
      _exit(126);
    close(control[1]);
    close(receipt);
    // The inherited control descriptor is the only non-stdio descriptor.
    const int highest = getdtablesize();
    for (int fd = 3; fd < highest; ++fd) {
      if (fd != control[0])
        close(fd);
    }
    // stdin belongs to the owner/controller protocol, never to the leaf.
    close(STDIN_FILENO);
    if (chdir(argv[5]) != 0 || !InstallBoundary(profile))
      _exit(126);
    execv(child_argv[0], child_argv.data());
    _exit(126);
  }
  close(control[0]);
  if (!child.Created()) {
    close(control[1]);
    close(receipt);
    return 126;
  }
  while (child.Poll()) {
    if (!FreshOwnerBoundary(STDIN_FILENO, &gate, deadline, boot))
      break;
    if (gate.go_seen && !gate.go_sent) {
      // The same gate rechecks queued cancellation/expiry just before GO.
      if (!FreshOwnerBoundary(STDIN_FILENO, &gate, deadline, boot) ||
          write(control[1], "G", 1) != 1) {
        gate.Fail();
        break;
      }
      gate.go_sent = true;
    }
    pollfd input{STDIN_FILENO, POLLIN, 0};
    if (poll(&input, 1, 20) < 0)
      gate.Fail();
  }
  // EOF first lets the qualification creator drain its known probe. The
  // original deadline is never extended for new work. Cleanup has a fixed10s
  // allowance, with the last3s reserved for actual root wait after a signal.
  close(control[1]);
  const uint64_t cleanup_start = MonotonicNowNs();
  const uint64_t cleanup_end = cleanup_start + 10ULL * 1000000000;
  const bool cooperative = support && !noncreating_support;
  const uint64_t kill_at = cleanup_start +
      (cooperative ? 7ULL * 1000000000 : 0);
  bool kill_attempted = false;
  while (child.Poll()) {
    const uint64_t cleanup_now = MonotonicNowNs();
    if (!cleanup_start || !cleanup_now || cleanup_now >= cleanup_end) {
      gate.Fail();
      break;
    }
    if (cleanup_now >= kill_at && !kill_attempted) {
      gate.Fail();
      kill_attempted = true;
      child.KillOwned();  // only the actual unreaped direct child
    }
    usleep(1000);
  }
  if (!child.Reaped())
    gate.Fail();  // UNVERIFIED; never signal at the deadline without wait time.
  FreshOwnerBoundary(STDIN_FILENO, &gate, deadline, boot);
  const int child_status = child.Status();
  const bool leaf_success = gate.go_sent && child.Reaped() &&
      WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0;
  if (!leaf_success)
    gate.Fail();
  // Immutable provisional evidence. There is no authoritative accepted field:
  // actual owner completion and the consumer's final guards are mandatory.
  const std::string terminal =
      "{\"version\":1,\"kind\":\"provisional\",\"command\":" + command +
      ",\"deadline_ns\":" + std::to_string(deadline) + ",\"boot\":" + JsonString(boot) +
      ",\"reaped\":" + (child.Reaped() ? "true" : "false") +
      ",\"stopped\":" + (gate.failure ? "true" : "false") +
      ",\"go\":" + (gate.go_sent ? "true" : "false") +
      ",\"status\":" + std::to_string(child.Status()) + "}\n";
  // Cancellation during ANY terminal I/O is latched after close. Never rewrite
  // the provisional receipt or promote it when this final boundary refuses.
  const bool finished = aegis_access::bounded::FinishTerminal(
      &gate,
      [&] { return terminal.size() <= 32768 &&
          write(receipt, terminal.data(), terminal.size()) == static_cast<ssize_t>(terminal.size()); },
      [&] { return fsync(receipt) == 0; },
      [&] { return close(receipt) == 0; },
      [&] { return FreshOwnerBoundary(STDIN_FILENO, &gate, deadline, boot); });
  return finished && leaf_success ? 0 : 125;
}
