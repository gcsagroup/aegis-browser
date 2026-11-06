// Copyright 2026 GCSA
#include "chrome/browser/aegis/proxy/core_relay_pair.h"
#include <algorithm>
#include "chrome/browser/aegis/proxy/core_tls.h"
#include <cerrno>
#include "base/containers/span.h"
#include <utility>
#include <sys/socket.h>
#include "third_party/boringssl/src/include/openssl/mem.h"
namespace aegis::proxy {

struct CoreRelayPair::TlsState {
  using Status = CoreTlsSocket::Status;
  struct Side {
    std::unique_ptr<CoreTlsSocket> socket;
    short handshake = POLLIN | POLLOUT;
    short read = POLLIN;
    short write = POLLOUT;
    short close = POLLOUT;
    bool ready = false;
    bool write_pending = false;
  };
  Side front;
  Side backend;
  base::TimeTicks handshake_deadline;

  static short Want(Status s) {
    if (s == Status::kWantRead)
      return POLLIN;
    if (s == Status::kWantWrite)
      return POLLOUT;
    return 0;
  }

  static short Events(const Side& side, const Direction& outgoing,
                      const Direction& incoming) {
    short events = 0;
    if (!outgoing.read_eof && !outgoing.size)
      events |= side.read;
    if (incoming.size)
      events |= side.write;
    if (incoming.read_eof && !incoming.size && !incoming.write_shutdown)
      events |= side.close;
    return events;
  }

  static bool Handshake(Side& side, short events, bool& failed) {
    if (side.ready || !(events & (side.handshake | POLLHUP)))
      return false;
    const auto s = side.socket->Handshake();
    side.ready = s == Status::kReady;
    side.handshake = Want(s);
    if (!side.ready && !side.handshake)
      failed = true;
    return side.ready;
  }

  static bool Transfer(Side& side, short events, Direction& outgoing,
                       Direction& incoming, bool& failed) {
    bool progress = false;
    if (incoming.size && (events & (side.write | POLLHUP))) {
      auto r = side.socket->Write(incoming.bytes.data(),
                                  static_cast<int>(incoming.size));
      if (r.status == Status::kReady &&
          static_cast<size_t>(r.count) == incoming.size) {
        OPENSSL_cleanse(incoming.bytes.data(), incoming.size);
        incoming.size = 0;
        side.write = POLLOUT;
        side.write_pending = false;
        progress = true;
      } else {
        side.write = Want(r.status);
        side.write_pending = side.write != 0;
        if (!side.write) {
          failed = true;
          return progress;
        }
      }
    }
    // Retry a write waiting for input before starting another SSL operation.
    // A write waiting for output keeps its exact source buffer unchanged.
    if (!(side.write_pending && side.write == POLLIN) &&
        !outgoing.read_eof && !outgoing.size &&
        ((events & (side.read | POLLHUP)) ||
         (side.read == POLLIN && side.socket->HasBufferedData()))) {
      auto r = side.socket->Read(outgoing.bytes.data(), outgoing.bytes.size());
      if (r.status == Status::kReady) {
        outgoing.size = r.count;
        side.read = POLLIN;
        progress = true;
      } else if (r.status == Status::kClosed) {
        outgoing.read_eof = true;
        progress = true;
      } else {
        side.read = Want(r.status);
        if (!side.read) {
          failed = true;
          return progress;
        }
      }
    }
    if (incoming.read_eof && !incoming.size && !incoming.write_shutdown &&
        (events & (side.close | POLLHUP))) {
      const auto result = side.socket->CloseWrite();
      if (result == Status::kReady) {
        incoming.write_shutdown = true;
        progress = true;
      } else {
        side.close = Want(result);
        if (!side.close)
          failed = true;
      }
    }
    return progress;
  }
};

CoreRelayPair::CoreRelayPair(base::ScopedFD client, base::ScopedFD backend,
                             SSL_CTX& front, std::string_view backend_der,
                             base::TimeTicks handshake_deadline)
    : client_(std::move(client)), backend_(std::move(backend)),
      tls_(std::make_unique<TlsState>()) {
  tls_->handshake_deadline = handshake_deadline;
  tls_->front.socket = CoreTlsSocket::Accept(client_.get(), front);
  tls_->backend.socket = CoreTlsSocket::Connect(backend_.get(), backend_der);
  failed_ = !tls_->front.socket || !tls_->backend.socket;
}

void CoreRelayPair::Cancel() {
  failed_ = true;
  tls_.reset();
  client_.reset();
  backend_.reset();
  OPENSSL_cleanse(to_backend_.bytes.data(), to_backend_.bytes.size());
  OPENSSL_cleanse(to_client_.bytes.data(), to_client_.bytes.size());
}

CoreRelayPair::CoreRelayPair(base::ScopedFD client, base::ScopedFD backend)
    : client_(std::move(client)), backend_(std::move(backend)) {}
CoreRelayPair::~CoreRelayPair() {
  OPENSSL_cleanse(to_backend_.bytes.data(), to_backend_.bytes.size());
  OPENSSL_cleanse(to_client_.bytes.data(), to_client_.bytes.size());
}
short CoreRelayPair::Events(const Direction& outgoing,
                           const Direction& incoming) const {
  return ((!outgoing.read_eof && outgoing.size < outgoing.bytes.size()) ? POLLIN : 0) |
         ((!incoming.write_shutdown && incoming.size) ? POLLOUT : 0);
}
pollfd CoreRelayPair::ClientPoll() const {
  if (tls_) {
    if (failed_ || !tls_->backend.ready)
      return {-1, 0, 0};
    const short events = tls_->front.ready
        ? TlsState::Events(tls_->front, to_backend_, to_client_)
        : tls_->front.handshake;
    return {events ? client_.get() : -1, events, 0};
  }
  short events = Events(to_backend_, to_client_);
  return {events ? client_.get() : -1, events, 0};
}
pollfd CoreRelayPair::BackendPoll() const {
  if (tls_) {
    if (failed_)
      return {-1, 0, 0};
    const short events = !tls_->backend.ready
        ? tls_->backend.handshake
        : (tls_->front.ready
               ? TlsState::Events(tls_->backend, to_client_, to_backend_) : 0);
    return {events ? backend_.get() : -1, events, 0};
  }
  short events = Events(to_client_, to_backend_);
  return {events ? backend_.get() : -1, events, 0};
}
bool CoreRelayPair::Transfer(int fd, short events, Direction& outgoing,
                             Direction& incoming) {
  if (events & (POLLERR | POLLNVAL)) { failed_ = true; return false; }
  bool progress = false;
  if (!outgoing.read_eof && outgoing.size < outgoing.bytes.size() &&
      events & (POLLIN | POLLHUP)) {
    auto available = base::span(outgoing.bytes).subspan(outgoing.size);
    auto destination = available.first(std::min<size_t>(4096, available.size()));
    auto n = recv(fd, destination.data(), destination.size(), 0);
    if (n > 0) { outgoing.size += static_cast<size_t>(n); progress = true; }
    else if (n == 0) outgoing.read_eof = true;
    else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
      failed_ = true;
  }
  if (!incoming.write_shutdown && incoming.size && events & POLLOUT) {
    auto n = send(fd, incoming.bytes.data(), incoming.size, 0);
    if (n > 0) {
      const auto count = static_cast<size_t>(n);
      const auto remaining = incoming.size - count;
      auto buffered = base::span(incoming.bytes).first(incoming.size);
      buffered.first(remaining).copy_from(buffered.subspan(count));
      auto consumed = buffered.subspan(remaining, count);
      OPENSSL_cleanse(consumed.data(), consumed.size());
      incoming.size = remaining;
      progress = true;
    } else if (n == 0 || (errno != EINTR && errno != EAGAIN &&
                          errno != EWOULDBLOCK)) failed_ = true;
  }
  return progress;
}
void CoreRelayPair::HalfClose(int destination, Direction& outgoing) {
  if (!outgoing.read_eof || outgoing.size || outgoing.write_shutdown) return;
  outgoing.write_shutdown = true;
  if (shutdown(destination, SHUT_WR) && errno != ENOTCONN) failed_ = true;
}
bool CoreRelayPair::Pump(short client_events, short backend_events) {
  if (failed_)
    return false;
  if (tls_) {
    if ((client_events | backend_events) & (POLLERR | POLLNVAL)) {
      failed_ = true;
      return false;
    }
    if (!tls_->front.ready || !tls_->backend.ready) {
      if (base::TimeTicks::Now() >= tls_->handshake_deadline) {
        failed_ = true;
        return false;
      }
      // Do not complete the client-facing handshake until the backend
      // presented the exact expected key on this connection.
      if (!tls_->backend.ready)
        return TlsState::Handshake(tls_->backend, backend_events, failed_);
      return TlsState::Handshake(tls_->front, client_events, failed_);
    }
    bool progress = TlsState::Transfer(tls_->front, client_events,
                                       to_backend_, to_client_, failed_);
    if (!failed_)
      progress = TlsState::Transfer(tls_->backend, backend_events, to_client_,
                                    to_backend_, failed_) || progress;
    return progress;
  }
  bool progress = Transfer(client_.get(), client_events, to_backend_, to_client_);
  if (failed_) return progress;
  progress = Transfer(backend_.get(), backend_events, to_client_, to_backend_) || progress;
  HalfClose(backend_.get(), to_backend_);
  HalfClose(client_.get(), to_client_);
  return progress;
}
bool CoreRelayPair::finished() const {
  return failed_ || (to_backend_.read_eof && to_client_.read_eof &&
      !to_backend_.size && !to_client_.size &&
      to_backend_.write_shutdown && to_client_.write_shutdown);
}
}  // namespace aegis::proxy
