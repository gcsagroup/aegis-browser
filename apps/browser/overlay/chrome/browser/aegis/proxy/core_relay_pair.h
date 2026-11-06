// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_PROXY_CORE_RELAY_PAIR_H_
#define CHROME_BROWSER_AEGIS_PROXY_CORE_RELAY_PAIR_H_
#include <array>
#include <cstddef>
#include <memory>
#include <string_view>
#include <poll.h>
#include "base/files/scoped_file.h"
#include "base/time/time.h"
#include "third_party/boringssl/src/include/openssl/ssl.h"
namespace aegis::proxy {
// One owner, two bounded directional buffers. A TCP FIN ends only its read
// direction; shutdown(SHUT_WR) follows the corresponding buffer's last byte.
class CoreRelayPair final {
 public:
  CoreRelayPair(base::ScopedFD client, base::ScopedFD backend);
  CoreRelayPair(base::ScopedFD client, base::ScopedFD backend, SSL_CTX& front,
                std::string_view backend_der, base::TimeTicks handshake_deadline);
  ~CoreRelayPair();
  void Cancel();
  CoreRelayPair(const CoreRelayPair&) = delete;
  CoreRelayPair& operator=(const CoreRelayPair&) = delete;
  pollfd ClientPoll() const;
  pollfd BackendPoll() const;
  bool Pump(short client_events, short backend_events);
  bool finished() const;
 private:
  struct Direction {
    std::array<char, 16384> bytes{};
    size_t size = 0;
    bool read_eof = false;
    bool write_shutdown = false;
  };
  short Events(const Direction& outgoing, const Direction& incoming) const;
  bool Transfer(int fd, short events, Direction& outgoing, Direction& incoming);
  void HalfClose(int destination, Direction& outgoing);
  base::ScopedFD client_, backend_;
  Direction to_backend_, to_client_;
  struct TlsState;
  std::unique_ptr<TlsState> tls_;
  bool failed_ = false;
};
}  // namespace aegis::proxy
#endif
