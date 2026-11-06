// Copyright 2026 GCSA
#include "tools/aegis/current151_tracker/bounded_runtime.h"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <cstring>
#include <limits>
#include <ctime>
#include <string_view>
#include <thread>

namespace aegis_access::bounded {
namespace {
bool Number(std::string_view text, uint64_t* value) {
  const auto result = std::from_chars(text.data(), text.data() + text.size(), *value);
  return result.ec == std::errc() && result.ptr == text.data() + text.size();
}

int WaitMs(uint64_t deadline) {
  const uint64_t now = MonotonicNowNs();
  if (!now || now >= deadline)
    return 0;
  return static_cast<int>(std::min<uint64_t>(50, (deadline - now) / 1000000 + 1));
}
}  // namespace

uint64_t MonotonicNowNs() {
  timespec ts{};
  if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
    return 0;
  return static_cast<uint64_t>(ts.tv_sec) * 1000000000 +
         static_cast<uint64_t>(ts.tv_nsec);
}

std::string BootIdentity() {
  timeval boot{};
  size_t size = sizeof(boot);
  if (sysctlbyname("kern.boottime", &boot, &size, nullptr, 0) != 0 ||
      size != sizeof(boot))
    return {};
  return std::to_string(boot.tv_sec) + "." + std::to_string(boot.tv_usec);
}

uint64_t QualificationWorkDeadline(uint64_t original_deadline, uint64_t now,
                                   uint64_t alarm_remaining) {
  constexpr uint64_t kDrainReserve = 3000000000ULL;
  if (!now || !alarm_remaining || original_deadline <= now ||
      alarm_remaining > std::numeric_limits<uint64_t>::max() - now)
    return 0;
  const uint64_t hard_end = std::min(original_deadline, now + alarm_remaining);
  return hard_end - now > kDrainReserve ? hard_end - kDrainReserve : 0;
}

bool QualificationSession::Check() {
  if (stopped)
    return false;
  pollfd channel{control_fd, POLLIN, 0};
  const uint64_t now = MonotonicNowNs();
  if (control_fd < 3 || !now || now >= work_end ||
      now >= original_deadline || boot != BootIdentity() ||
      poll(&channel, 1, 0) != 0) {
    stopped = true;  // EOF, duplicate GO, cancellation and errors are sticky.
    return false;
  }
  return true;
}

void OwnerGate::Fail(int reason) {
  if (!failure)
    failure = reason;
}

void OwnerGate::Observe(ControllerObservation observation) {
  if (failure || observation == ControllerObservation::kQuiet)
    return;
  if (observation == ControllerObservation::kGo && !go_seen) {
    go_seen = true;
    return;
  }
  Fail();
}

void ObserveController(int fd, OwnerGate* gate) {
  // One queued GO is preserved for forwarding after birth. Inspect a following
  // byte/EOF too, so GO+cancel and repeated GO cannot hide behind that byte.
  for (int i = 0; i < 2 && !gate->failure; ++i) {
    pollfd channel{fd, POLLIN, 0};
    const int ready = poll(&channel, 1, 0);
    if (ready == 0)
      return;
    if (ready < 0 || (channel.revents & (POLLERR | POLLNVAL))) {
      gate->Observe(ControllerObservation::kError);
      return;
    }
    char byte = 0;
    const ssize_t count = read(fd, &byte, 1);
    if (count == 0)
      gate->Observe(ControllerObservation::kEof);
    else if (count == 1)
      gate->Observe(byte == 'G' ? ControllerObservation::kGo
                                : ControllerObservation::kCancel);
    else if (errno != EAGAIN && errno != EWOULDBLOCK)
      gate->Observe(ControllerObservation::kError);
    else
      return;
  }
}

bool ValidateOwnerBoundary(OwnerGate* gate, uint64_t deadline,
                           std::string_view expected_boot, uint64_t now,
                           std::string_view current_boot) {
  if (!now || now >= deadline || expected_boot.empty() || current_boot != expected_boot)
    gate->Fail();
  return !gate->failure;
}

bool FreshOwnerBoundary(int fd, OwnerGate* gate, uint64_t deadline,
                        std::string_view expected_boot) {
  ObserveController(fd, gate);
  const std::string boot = BootIdentity();
  return ValidateOwnerBoundary(gate, deadline, expected_boot, MonotonicNowNs(), boot);
}

bool FinishTerminal(OwnerGate* gate, const std::function<bool()>& write_once,
                    const std::function<bool()>& sync_once,
                    const std::function<bool()>& close_once,
                    const std::function<bool()>& final_boundary) {
  if (!write_once())
    gate->Fail();
  if (!sync_once())
    gate->Fail();
  if (!close_once())
    gate->Fail();
  if (!final_boundary())
    gate->Fail();
  return !gate->failure;
}

namespace {
bool EnterChannel(int* argc, char** argv, bool (*valid_arguments)(int, char**),
                  QualificationSession* qualification) {
  uint64_t deadline = 0, descriptor = 0;
  std::string boot;
  int seen = 0, kept = 1;
  for (int i = 1; i < *argc; ++i) {
    std::string_view arg(argv[i]);
    if (arg.starts_with("--aegis-deadline-ns=")) {
      if ((seen & 1) || !Number(arg.substr(20), &deadline))
        return false;
      seen |= 1;
    } else if (arg.starts_with("--aegis-control-fd=")) {
      if ((seen & 2) || !Number(arg.substr(19), &descriptor))
        return false;
      seen |= 2;
    } else if (arg.starts_with("--aegis-boot=")) {
      if (seen & 4)
        return false;
      boot = arg.substr(13);
      seen |= 4;
    } else {
      argv[kept++] = argv[i];
    }
  }
  const uint64_t now = MonotonicNowNs();
  if (seen != 7 || descriptor < 3 || descriptor > 1024 || boot.empty() || !now ||
      boot != BootIdentity() || deadline <= now ||
      deadline - now > 8ULL * 3600 * 1000000000)
    return false;
  const int fd = static_cast<int>(descriptor);
  struct stat info{};
  itimerval alarm{};
  if (fstat(fd, &info) != 0 || !S_ISFIFO(info.st_mode) ||
      fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || getitimer(ITIMER_REAL, &alarm) != 0 ||
      (alarm.it_value.tv_sec == 0 && alarm.it_value.tv_usec == 0))
    return false;
  *argc = kept;
  argv[kept] = nullptr;
  if (!valid_arguments(*argc, argv))
    return false;
  for (;;) {
    const int wait = WaitMs(deadline);
    if (!wait)
      return false;
    pollfd channel{fd, POLLIN, 0};
    const int polled = poll(&channel, 1, wait);
    if (polled < 0)
      return false;
    if (polled > 0) {
      char go = 0;
      if (read(fd, &go, 1) != 1 || go != 'G' || deadline <= MonotonicNowNs())
        return false;
      break;
    }
  }
  if (qualification) {
    // getitimer was sampled after "now"; adding it to that earlier clock
    // underestimates the fatal timer boundary rather than extending it.
    const uint64_t remaining =
        static_cast<uint64_t>(alarm.it_value.tv_sec) * 1000000000ULL +
        static_cast<uint64_t>(alarm.it_value.tv_usec) * 1000ULL;
    const uint64_t work_end = QualificationWorkDeadline(deadline, now, remaining);
    if (!work_end)
      return false;
    qualification->control_fd = fd;
    qualification->original_deadline = deadline;
    qualification->hard_end = work_end + 3000000000ULL;
    qualification->work_end = work_end;
    qualification->boot = boot;
    return qualification->Check();
  }
  std::thread([fd, deadline] {
    for (;;) {
      const int wait = WaitMs(deadline);
      if (!wait)
        _exit(124);
      pollfd channel{fd, POLLIN, 0};
      // EOF, repeated GO, any cancellation byte or poll error is terminal.
      if (poll(&channel, 1, wait) != 0)
        _exit(125);
    }
  }).detach();
  return true;
}
}  // namespace

bool Enter(int* argc, char** argv) {
  return EnterChannel(argc, argv, ValidTrackerArguments, nullptr);
}

bool EnterQualification(int* argc, char** argv, QualificationSession* session) {
  return session && EnterChannel(argc, argv, ValidQualificationArguments, session);
}

bool EnterSpawnProbe(int argc, char** argv) {
  constexpr std::string_view kFd = "--aegis-probe-fd=";
  constexpr std::string_view kDeadline = "--aegis-deadline-ns=";
  constexpr std::string_view kBoot = "--aegis-boot=";
  constexpr std::string_view kNonce = "--aegis-probe-nonce=";
  if (argc != 6 || std::strcmp(argv[1], "--aegis-spawn-probe") != 0)
    return false;
  const std::string_view fd_arg(argv[2]), deadline_arg(argv[3]),
      boot_arg(argv[4]), nonce_arg(argv[5]);
  uint64_t descriptor = 0, deadline = 0;
  if (!fd_arg.starts_with(kFd) || !deadline_arg.starts_with(kDeadline) ||
      !boot_arg.starts_with(kBoot) || !nonce_arg.starts_with(kNonce) ||
      !Number(fd_arg.substr(kFd.size()), &descriptor) ||
      !Number(deadline_arg.substr(kDeadline.size()), &deadline) ||
      descriptor < 3 || descriptor > 1024 ||
      boot_arg.substr(kBoot.size()) != BootIdentity())
    return false;
  const std::string_view nonce = nonce_arg.substr(kNonce.size());
  if (nonce.size() != 32 || nonce.find_first_not_of("0123456789abcdef") != std::string_view::npos)
    return false;
  const uint64_t now = MonotonicNowNs();
  if (!now || deadline <= now || deadline - now > 8ULL * 3600 * 1000000000)
    return false;
  const uint64_t end = std::min<uint64_t>(deadline, now + 2000000000ULL);
  if (end - now < 1000)
    return false;  // never install a zero timer (which would disarm it)
  struct stat info{};
  const int fd = static_cast<int>(descriptor);
  if (fstat(fd, &info) != 0 || !S_ISFIFO(info.st_mode) ||
      fcntl(fd, F_SETFD, FD_CLOEXEC) != 0)
    return false;
  // This private exec child has its own <=2s timer, always capped by the
  // original deadline. The admitted creator independently owns its real wait.
  itimerval timer{};
  timer.it_value.tv_sec = (end - now) / 1000000000ULL;
  timer.it_value.tv_usec = ((end - now) % 1000000000ULL) / 1000;
  struct sigaction action{};
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  sigset_t unblocked;
  sigemptyset(&unblocked);
  sigaddset(&unblocked, SIGALRM);
  if (sigaction(SIGALRM, &action, nullptr) != 0 ||
      sigprocmask(SIG_UNBLOCK, &unblocked, nullptr) != 0 ||
      setitimer(ITIMER_REAL, &timer, nullptr) != 0)
    return false;
  std::string observed;
  for (;;) {
    const int wait = WaitMs(end);
    if (!wait)
      return false;
    pollfd channel{fd, POLLIN, 0};
    if (poll(&channel, 1, wait) < 0)
      return false;
    if (!channel.revents)
      continue;
    if (channel.revents & (POLLERR | POLLNVAL))
      return false;
    char bytes[33];
    const ssize_t count = read(fd, bytes, sizeof(bytes));
    if (count < 0)
      return false;
    if (count == 0) {
      close(fd);
      return observed == nonce && MonotonicNowNs() < end &&
             boot_arg.substr(kBoot.size()) == BootIdentity();
    }
    if (observed.size() + count > 32)
      return false;
    observed.append(bytes, count);
  }
}

bool ValidQualificationArguments(int argc, char** argv) {
  return argc == 1 ||
         (argc == 2 &&
          (std::strcmp(argv[1], "--aegis-qualification-positive-control") == 0 ||
           std::strcmp(argv[1], "--aegis-qualification-clock-probe") == 0 ||
           std::strcmp(argv[1], "--aegis-qualification-owner-boundaries") == 0));
}

bool ValidTrackerArguments(int argc, char** argv) {
  if (argc == 3)
    return std::strcmp(argv[1], "--single-process-tests") == 0 &&
           std::strcmp(argv[2], "--gtest_list_tests") == 0;
  if (argc != 5 || std::strcmp(argv[1], "--single-process-tests") != 0 ||
      std::strcmp(argv[3], "--gtest_repeat=1") != 0)
    return false;
  const std::string_view filter(argv[2]), output(argv[4]);
  return (filter == "--gtest_filter=PolicyPublicationAckTrackerTest.SharedUnitContract" ||
          filter == "--gtest_filter=PolicyPublicationAckTrackerRegressionTest.SharedRegressionContract") &&
         output.starts_with("--test-launcher-output=/") && output.size() > 24;
}
}  // namespace aegis_access::bounded
