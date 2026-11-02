// Copyright 2026 GCSA
#ifndef TOOLS_AEGIS_CURRENT151_TRACKER_BOUNDED_RUNTIME_H_
#define TOOLS_AEGIS_CURRENT151_TRACKER_BOUNDED_RUNTIME_H_

#include <cstdint>
#include <functional>
#include <string>
#include <string_view>

namespace aegis_access::bounded {
inline constexpr char kDeadlineClockName[] = "CLOCK_MONOTONIC";
uint64_t MonotonicNowNs();
std::string BootIdentity();
// Consumes the inherited one-use GO and starts an EOF/deadline watchdog. The
// watchdog intentionally survives TestSuite and static destruction.
bool Enter(int* argc, char** argv);
bool ValidTrackerArguments(int argc, char** argv);
// Qualification keeps cooperative cancellation until its known probes are
// actually waited. Its inherited fatal timer remains armed and is never renewed.
struct QualificationSession {
  int control_fd = -1;
  uint64_t original_deadline = 0;
  uint64_t hard_end = 0;
  uint64_t work_end = 0;
  std::string boot;
  bool stopped = false;
  bool Check();
};
uint64_t QualificationWorkDeadline(uint64_t original_deadline, uint64_t now,
                                   uint64_t alarm_remaining);
bool EnterQualification(int* argc, char** argv, QualificationSession* session);
bool ValidQualificationArguments(int argc, char** argv);
// Separate private self-probe admission: exact inherited pipe + one-use nonce,
// boot and original deadline. Direct bare --aegis-spawn-probe always refuses.
bool EnterSpawnProbe(int argc, char** argv);

enum class ControllerObservation { kQuiet, kGo, kCancel, kEof, kError };
struct OwnerGate {
  bool go_seen = false;
  bool go_sent = false;
  int failure = 0;
  void Fail(int reason = 125);
  void Observe(ControllerObservation observation);
};
// fd must already be an admitted nonblocking pipe. Reads at most two bytes.
void ObserveController(int fd, OwnerGate* gate);
// Pure shared transition used by the owner and source-only native fixtures.
bool ValidateOwnerBoundary(OwnerGate* gate, uint64_t deadline,
                           std::string_view expected_boot, uint64_t now,
                           std::string_view current_boot);
bool FreshOwnerBoundary(int fd, OwnerGate* gate, uint64_t deadline,
                        std::string_view expected_boot);
// Exactly one write, sync, close and final observation, even on I/O failure.
// Operations are private owner callbacks; never receipt/grant-supplied code.
bool FinishTerminal(OwnerGate* gate, const std::function<bool()>& write_once,
                    const std::function<bool()>& sync_once,
                    const std::function<bool()>& close_once,
                    const std::function<bool()>& final_boundary);
}  // namespace aegis_access::bounded
#endif
