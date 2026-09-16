// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_H_
#define COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_H_

#include <cstddef>
#include <map>
#include <memory>
#include <optional>
#include <string>

#include "components/aegis_access/access_route_types.h"

namespace aegis_access {

enum class RequestOwnershipLifecycle {
  kNew,
  kDispatched,
  kStreaming,
};

enum class RequestOwnershipStatus {
  kOk,
  kInvalidRecord,
  kCapacityExceeded,
  kDuplicateRequestId,
  kNotFound,
  kOwnershipMismatch,
  kStaleGeneration,
  kInvalidLifecycle,
  kMissingTerminationHandle,
};

// The browser-side adapter owns concrete URLLoader/navigation/stream handles.
// The neutral registry only needs a one-shot termination capability so it can
// remain testable without depending on browser or Network Service types.
class RequestTerminationHandle {
 public:
  virtual ~RequestTerminationHandle() = default;
  virtual void Terminate() = 0;
};

// Browser-owned, already-normalized identity for one in-flight request. The
// registry does not parse URLs or trust renderer-provided Profile/partition
// strings. RequestPolicyContext is the intended source for these fields.
struct RequestOwnershipRecord {
  std::string request_id;
  OwnershipKey owner;
  GenerationTuple generations;
  std::string document_token;
  std::string pending_navigation_token;
  bool site_ownership_reliable = false;
  std::string top_level_site;
  std::string exact_host;
  RequestScheme scheme = RequestScheme::kInvalid;
  uint16_t port = 0;

  friend bool operator==(const RequestOwnershipRecord&,
                         const RequestOwnershipRecord&) = default;
};

struct RequestOwnershipSnapshot {
  RequestOwnershipRecord record;
  RequestOwnershipLifecycle lifecycle = RequestOwnershipLifecycle::kNew;
  bool has_termination_handle = false;
};

struct RequestOwnershipLookupResult {
  RequestOwnershipStatus status = RequestOwnershipStatus::kNotFound;
  std::optional<RequestOwnershipSnapshot> snapshot;
};

struct RequestOwnershipTerminalResult {
  RequestOwnershipStatus status = RequestOwnershipStatus::kNotFound;
  std::optional<RequestOwnershipRecord> record;
  RequestOwnershipLifecycle previous_lifecycle =
      RequestOwnershipLifecycle::kNew;
  bool termination_invoked = false;
};

// Bounded request ownership state. Every mutable operation rechecks the exact
// owner and generation tuple supplied by the browser caller. Mismatches never
// consume or replace the registered entry. Terminal operations erase the entry
// before invoking an external termination handle so late/reentrant callbacks
// cannot observe a request as still active.
class RequestOwnershipRegistry {
 public:
  explicit RequestOwnershipRegistry(size_t max_entries);
  RequestOwnershipRegistry(const RequestOwnershipRegistry&) = delete;
  RequestOwnershipRegistry& operator=(const RequestOwnershipRegistry&) = delete;
  ~RequestOwnershipRegistry();

  RequestOwnershipStatus Register(RequestOwnershipRecord record);
  RequestOwnershipLookupResult Lookup(
      const std::string& request_id,
      const OwnershipKey& expected_owner,
      const GenerationTuple& expected_generations) const;

  RequestOwnershipStatus MarkDispatched(
      const std::string& request_id,
      const OwnershipKey& expected_owner,
      const GenerationTuple& expected_generations,
      std::unique_ptr<RequestTerminationHandle> termination_handle);
  RequestOwnershipStatus MarkStreaming(
      const std::string& request_id,
      const OwnershipKey& expected_owner,
      const GenerationTuple& expected_generations);

  RequestOwnershipTerminalResult Complete(
      const std::string& request_id,
      const OwnershipKey& expected_owner,
      const GenerationTuple& expected_generations);
  RequestOwnershipTerminalResult Cancel(
      const std::string& request_id,
      const OwnershipKey& expected_owner,
      const GenerationTuple& expected_generations);

  size_t size() const { return entries_.size(); }
  size_t max_entries() const { return max_entries_; }

 private:
  struct Entry {
    RequestOwnershipRecord record;
    RequestOwnershipLifecycle lifecycle = RequestOwnershipLifecycle::kNew;
    std::unique_ptr<RequestTerminationHandle> termination_handle;
  };

  size_t max_entries_;
  std::map<std::string, Entry> entries_;
};

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_REQUEST_OWNERSHIP_REGISTRY_H_
