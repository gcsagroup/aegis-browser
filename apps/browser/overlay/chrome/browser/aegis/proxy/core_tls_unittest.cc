// Copyright 2026 GCSA
#include "chrome/browser/aegis/proxy/core_tls.h"

#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>

#include <array>
#include <cerrno>
#include <memory>
#include <string>
#include <string_view>
#include <utility>

#include "base/containers/span.h"
#include "base/files/scoped_file.h"
#include "chrome/browser/aegis/proxy/core_control_wire_guard.h"
#include "chrome/browser/aegis/proxy/core_relay_pair.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "third_party/boringssl/src/include/openssl/mem.h"

namespace aegis::proxy {
namespace {

using Status = CoreTlsSocket::Status;

bool MakePair(std::array<base::ScopedFD, 2>& out) {
  int fds[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0)
    return false;
  out[0].reset(fds[0]);
  out[1].reset(fds[1]);
  for (auto& fd : out) {
    const int enabled = 1;
    if (fcntl(fd.get(), F_SETFD, FD_CLOEXEC) ||
        fcntl(fd.get(), F_SETFL, O_NONBLOCK) ||
        setsockopt(fd.get(), SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                   sizeof(enabled))) {
      return false;
    }
  }
  return true;
}

bool Pending(Status status) {
  return status == Status::kWantRead || status == Status::kWantWrite;
}

void DriveRelay(CoreRelayPair& relay) {
  pollfd fds[] = {relay.ClientPoll(), relay.BackendPoll()};
  if (poll(fds, 2, 1) >= 0)
    relay.Pump(fds[0].revents, fds[1].revents);
}

TEST(CoreTlsTest, CurrentGuardRejectsUnnegotiatedFrontCertificateField) {
  wire::Control control;
  control.set_version(1);
  control.set_sequence(1);
  control.set_session_id(std::string(64, 'a'));
  auto* reply = control.mutable_reply();
  reply->set_session_id(control.session_id());
  auto* endpoint = reply->add_endpoints();
  endpoint->set_listener_id(std::string(64, 'b'));
  endpoint->set_front_port(1234);
  std::string bytes;
  ASSERT_TRUE(control.SerializeToString(&bytes));
  ASSERT_TRUE(internal::HasUnambiguousCoreControlWire(bytes));
  endpoint->set_front_tls_certificate_der("unnegotiated");
  ASSERT_TRUE(control.SerializeToString(&bytes));
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(bytes));
}

TEST(CoreTlsTest, KeysAreDistinctAndOnlyBackendIdentityExportsConfig) {
  const auto now = base::Time::Now();
  auto front = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kFront, now);
  auto backend = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kBackend, now);
  ASSERT_TRUE(front);
  ASSERT_TRUE(backend);
  EXPECT_NE(front->certificate_der(), backend->certificate_der());
  EXPECT_TRUE(front->FrontServerContext());
  EXPECT_FALSE(backend->FrontServerContext());
  base::DictValue inbound;
  EXPECT_FALSE(front->AddBackendXrayTls(inbound));
  EXPECT_TRUE(backend->AddBackendXrayTls(inbound));
  const auto* stream = inbound.FindDict("streamSettings");
  ASSERT_TRUE(stream);
  EXPECT_EQ(*stream->FindString("security"), "tls");
  const auto* tls = stream->FindDict("tlsSettings");
  ASSERT_TRUE(tls);
  EXPECT_EQ(*tls->FindString("minVersion"), "1.3");
  EXPECT_EQ(tls->FindBool("enableSessionResumption"), false);
  // The configuration builder owns the production tree cleanse. This test
  // owns this synthetic tree and must clear its private fixture copy too.
  auto* certs = inbound.FindDict("streamSettings")
                    ->FindDict("tlsSettings")->FindList("certificates");
  ASSERT_TRUE(certs);
  auto* keys = (*certs)[0].GetDict().FindList("key");
  ASSERT_TRUE(keys);
  auto& pem = (*keys)[0].GetString();
  OPENSSL_cleanse(pem.data(), pem.size());
}

TEST(CoreTlsTest, WrongBackendCannotCompleteClientFacingHandshake) {
  const auto now = base::Time::Now();
  auto front = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kFront, now);
  auto expected = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kBackend, now);
  auto impostor = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kFront, now);
  ASSERT_TRUE(front && expected && impostor);
  auto front_ctx = front->FrontServerContext();
  auto impostor_ctx = impostor->FrontServerContext();
  ASSERT_TRUE(front_ctx && impostor_ctx);
  std::array<base::ScopedFD, 2> client_fds, backend_fds;
  ASSERT_TRUE(MakePair(client_fds));
  ASSERT_TRUE(MakePair(backend_fds));
  auto client = CoreTlsSocket::Connect(client_fds[1].get(),
                                        front->certificate_der());
  auto wrong_server = CoreTlsSocket::Accept(backend_fds[1].get(), *impostor_ctx);
  ASSERT_TRUE(client && wrong_server);
  const auto deadline = base::TimeTicks::Now() + base::Seconds(2);
  CoreRelayPair relay(std::move(client_fds[0]), std::move(backend_fds[0]),
                      *front_ctx, expected->certificate_der(), deadline);
  Status client_status = client->Handshake();
  ASSERT_TRUE(Pending(client_status));
  while (!relay.finished() && base::TimeTicks::Now() < deadline) {
    DriveRelay(relay);
    wrong_server->Handshake();
    client_status = client->Handshake();
    ASSERT_NE(Status::kReady, client_status);
  }
  EXPECT_TRUE(relay.finished());
  EXPECT_NE(Status::kReady, client->Write("secret", 6).status);
}

TEST(CoreTlsTest, RelayTransfersOnlyAfterBothHandshakesAndClosesOnCancel) {
  const auto now = base::Time::Now();
  // A separate local test server stands in for the Xray TLS socket. Its
  // certificate and key never serve as the relay's frontend identity.
  auto front = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kFront, now);
  auto server = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kFront, now);
  ASSERT_TRUE(front && server);
  auto front_ctx = front->FrontServerContext();
  auto server_ctx = server->FrontServerContext();
  ASSERT_TRUE(front_ctx && server_ctx);
  std::array<base::ScopedFD, 2> client_fds, backend_fds;
  ASSERT_TRUE(MakePair(client_fds));
  ASSERT_TRUE(MakePair(backend_fds));
  auto client = CoreTlsSocket::Connect(client_fds[1].get(),
                                        front->certificate_der());
  auto backend = CoreTlsSocket::Accept(backend_fds[1].get(), *server_ctx);
  ASSERT_TRUE(client && backend);
  const auto deadline = base::TimeTicks::Now() + base::Seconds(2);
  CoreRelayPair relay(std::move(client_fds[0]), std::move(backend_fds[0]),
                      *front_ctx, server->certificate_der(), deadline);
  EXPECT_NE(Status::kReady, client->Write("before", 6).status);
  Status client_status = client->Handshake();
  Status backend_status = backend->Handshake();
  while ((Pending(client_status) || Pending(backend_status)) &&
         !relay.finished() && base::TimeTicks::Now() < deadline) {
    DriveRelay(relay);
    if (Pending(client_status)) client_status = client->Handshake();
    if (Pending(backend_status)) backend_status = backend->Handshake();
  }
  ASSERT_EQ(Status::kReady, client_status);
  ASSERT_EQ(Status::kReady, backend_status);
  ASSERT_EQ(Status::kReady, client->Write("through", 7).status);
  char message[7];
  CoreTlsSocket::Result received{Status::kWantRead};
  while (Pending(received.status) && !relay.finished() &&
         base::TimeTicks::Now() < deadline) {
    DriveRelay(relay);
    received = backend->Read(message, sizeof(message));
  }
  ASSERT_EQ(Status::kReady, received.status);
  EXPECT_EQ(std::string_view(message, received.count), "through");
  relay.Cancel();
  EXPECT_TRUE(relay.finished());
  EXPECT_EQ(Status::kFailed, backend->Read(message, sizeof(message)).status);
}

// All peers use nonblocking socketpairs. Bound both elapsed time and turns so
// a missing wakeup and an always-writable descriptor both fail the test.
template <typename Condition>
bool DriveUntil(CoreRelayPair& relay, Condition done) {
  const auto limit = base::TimeTicks::Now() + base::Seconds(4);
  for (int turn = 0; turn < 8192 && base::TimeTicks::Now() < limit; ++turn) {
    if (done())
      return true;
    if (relay.finished())
      return false;
    DriveRelay(relay);
  }
  return false;
}

bool NoWireBytes(int fd) {
  char byte;
  return recv(fd, &byte, 1, MSG_PEEK) < 0 &&
         (errno == EAGAIN || errno == EWOULDBLOCK);
}

struct RelayPeers {
  void Open(base::TimeDelta handshake_timeout, int server_fd = -1) {
    const auto now = base::Time::Now();
    auto front = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kFront, now);
    auto server = CoreTlsIdentity::Generate(CoreTlsIdentity::Role::kFront, now);
    ASSERT_TRUE(front && server);
    auto front_ctx = front->FrontServerContext();
    auto server_ctx = server->FrontServerContext();
    ASSERT_TRUE(front_ctx && server_ctx);
    std::array<base::ScopedFD, 2> front_pair, backend_pair;
    ASSERT_TRUE(MakePair(front_pair));
    ASSERT_TRUE(MakePair(backend_pair));
    client_fd = std::move(front_pair[1]);
    backend_fd = std::move(backend_pair[1]);
    client = CoreTlsSocket::Connect(client_fd.get(), front->certificate_der());
    backend = CoreTlsSocket::Accept(server_fd < 0 ? backend_fd.get() : server_fd,
                                    *server_ctx);
    ASSERT_TRUE(client && backend);
    handshake_deadline = base::TimeTicks::Now() + handshake_timeout;
    relay = std::make_unique<CoreRelayPair>(
        std::move(front_pair[0]), std::move(backend_pair[0]), *front_ctx,
        server->certificate_der(), handshake_deadline);
    ASSERT_FALSE(relay->finished());
  }

  void Connect() {
    ASSERT_NO_FATAL_FAILURE(Open(base::Seconds(10)));
    Status front = Status::kWantRead;
    Status back = Status::kWantRead;
    ASSERT_TRUE(DriveUntil(*relay, [&] {
      if (Pending(front))
        front = client->Handshake();
      if (Pending(back))
        back = backend->Handshake();
      return !Pending(front) && !Pending(back);
    }));
    ASSERT_EQ(Status::kReady, front);
    ASSERT_EQ(Status::kReady, back);
    // The client may complete before the relay processes its Finished.
    ASSERT_TRUE(DriveUntil(*relay, [&] {
      return relay->ClientPoll().fd >= 0 && relay->BackendPoll().fd >= 0;
    }));
  }

  CoreTlsSocket::Result Read(CoreTlsSocket& peer, char* buffer, int size) {
    CoreTlsSocket::Result result{Status::kWantRead};
    DriveUntil(*relay, [&] {
      result = peer.Read(buffer, size);
      return !Pending(result.status);
    });
    return result;
  }

  void ExpectBytes(CoreTlsSocket& peer, std::string_view expected) {
    std::string received(expected.size(), '\0');
    size_t offset = 0;
    while (offset < received.size()) {
      auto remaining = base::span(received).subspan(offset);
      const auto result =
          Read(peer, remaining.data(), static_cast<int>(remaining.size()));
      ASSERT_EQ(Status::kReady, result.status);
      ASSERT_GT(result.count, 0);
      ASSERT_LE(static_cast<size_t>(result.count), received.size() - offset);
      offset += result.count;
    }
    EXPECT_EQ(expected, received);
  }

  base::ScopedFD client_fd, backend_fd;
  std::unique_ptr<CoreTlsSocket> client, backend;
  std::unique_ptr<CoreRelayPair> relay;
  base::TimeTicks handshake_deadline;
};

enum class HandshakeEnd { kEof, kDeadline };

void CheckPartialBackendHandshake(HandshakeEnd end) {
  // A separate socketpair lets the real server consume the relay's ClientHello
  // and lets us deliver only four bytes of its first five-byte record header.
  std::array<base::ScopedFD, 2> server_pair;
  ASSERT_TRUE(MakePair(server_pair));
  RelayPeers peers;
  const auto timeout =
      end == HandshakeEnd::kEof ? base::Seconds(10) : base::Seconds(2);
  ASSERT_NO_FATAL_FAILURE(peers.Open(timeout, server_pair[0].get()));
  auto& relay = *peers.relay;
  DriveRelay(relay);
  // Drain just the initial flight, before anything is sent on the front leg.
  // The limit is an upper bound on fixture traffic, independent of record size.
  std::array<char, 4096> chunk;
  size_t flight_size = 0;
  while (!NoWireBytes(peers.backend_fd.get())) {
    const auto n = recv(peers.backend_fd.get(), chunk.data(), chunk.size(), 0);
    ASSERT_GT(n, 0);
    flight_size += n;
    ASSERT_LE(flight_size, 65536u);
    ASSERT_EQ(n, send(server_pair[1].get(), chunk.data(), n, 0));
  }
  ASSERT_GT(flight_size, 0u);
  ASSERT_TRUE(Pending(peers.backend->Handshake()));
  char prefix[4];
  ASSERT_EQ(4, recv(server_pair[1].get(), prefix, sizeof(prefix), 0));
  ASSERT_EQ(4, send(peers.backend_fd.get(), prefix, sizeof(prefix), 0));

  ASSERT_TRUE(Pending(peers.client->Handshake()));
  const auto denied = peers.client->Write("front", 5);
  ASSERT_EQ(Status::kFailed, denied.status);
  ASSERT_EQ(0, denied.count);
  DriveRelay(relay);
  ASSERT_FALSE(relay.finished());
  ASSERT_EQ(-1, relay.ClientPoll().fd);
  const auto backend_poll = relay.BackendPoll();
  ASSERT_GE(backend_poll.fd, 0);
  ASSERT_TRUE(backend_poll.events & POLLIN);
  ASSERT_TRUE(NoWireBytes(backend_poll.fd));  // Relay consumed the fragment.
  ASSERT_TRUE(NoWireBytes(peers.client_fd.get()));
  ASSERT_TRUE(NoWireBytes(peers.backend_fd.get()));

  if (end == HandshakeEnd::kEof) {
    ASSERT_EQ(0, shutdown(peers.backend_fd.get(), SHUT_WR));
  }
  ASSERT_TRUE(DriveUntil(relay, [&] { return relay.finished(); }));
  if (end == HandshakeEnd::kEof) {
    EXPECT_LT(base::TimeTicks::Now(), peers.handshake_deadline);
  } else {
    EXPECT_GE(base::TimeTicks::Now(), peers.handshake_deadline);
  }
  EXPECT_EQ(-1, relay.ClientPoll().fd);
  EXPECT_EQ(-1, relay.BackendPoll().fd);
  EXPECT_TRUE(NoWireBytes(peers.client_fd.get()));
  peers.relay.reset();  // The supervisor erases finished pairs.
  EXPECT_EQ(Status::kFailed, peers.client->Handshake());

  // After the initial ClientHello, only EOF or a single plaintext fatal alert
  // is legal on this unfinished backend handshake. Neither carries app bytes.
  std::array<unsigned char, 8> tail{};
  size_t used = 0;
  while (used < tail.size()) {
    auto remaining = base::span(tail).subspan(used);
    const auto n =
        recv(peers.backend_fd.get(), remaining.data(), remaining.size(), 0);
    ASSERT_GE(n, 0);
    if (n == 0)
      break;
    used += n;
  }
  if (used != 0) {
    ASSERT_EQ(7u, used);
    EXPECT_EQ(21, tail[0]);  // TLS alert
    EXPECT_EQ(0, tail[3]);
    EXPECT_EQ(2, tail[4]);
    EXPECT_EQ(2, tail[5]);  // fatal
  }
}

TEST(CoreTlsTest, PartialBackendHandshakeEofGatesFrontend) {
  ASSERT_NO_FATAL_FAILURE(CheckPartialBackendHandshake(HandshakeEnd::kEof));
}

TEST(CoreTlsTest, PartialBackendHandshakeExpiresWithPeerStillOpen) {
  ASSERT_NO_FATAL_FAILURE(CheckPartialBackendHandshake(HandshakeEnd::kDeadline));
}

TEST(CoreTlsTest, CloseNotifyDrainsPendingReverseBytesAndAllowsReply) {
  RelayPeers peers;
  ASSERT_NO_FATAL_FAILURE(peers.Connect());
  auto& relay = *peers.relay;
  ASSERT_FALSE(relay.ClientPoll().events & POLLOUT);
  ASSERT_EQ(6, peers.backend->Write("queued", 6).count);
  // POLLOUT on a fully handshaken front leg indicates a queued backend write.
  ASSERT_TRUE(DriveUntil(
      relay, [&] { return (relay.ClientPoll().events & POLLOUT) != 0; }));
  ASSERT_EQ(4, peers.client->Write("last", 4).count);
  ASSERT_EQ(Status::kReady, peers.client->CloseWrite());
  ASSERT_NO_FATAL_FAILURE(peers.ExpectBytes(*peers.backend, "last"));
  char byte;
  const auto front_end = peers.Read(*peers.backend, &byte, 1);
  ASSERT_EQ(Status::kClosed, front_end.status);
  EXPECT_EQ(0, front_end.count);
  ASSERT_FALSE(relay.finished());
  ASSERT_NO_FATAL_FAILURE(peers.ExpectBytes(*peers.client, "queued"));

  ASSERT_EQ(5, peers.backend->Write("reply", 5).count);
  ASSERT_EQ(Status::kReady, peers.backend->CloseWrite());
  ASSERT_NO_FATAL_FAILURE(peers.ExpectBytes(*peers.client, "reply"));
  const auto back_end = peers.Read(*peers.client, &byte, 1);
  EXPECT_EQ(Status::kClosed, back_end.status);
  EXPECT_EQ(0, back_end.count);
  EXPECT_TRUE(DriveUntil(relay, [&] { return relay.finished(); }));
}

TEST(CoreTlsTest, TruncatedBackendRecordAbortsEstablishedFrontend) {
  RelayPeers peers;
  ASSERT_NO_FATAL_FAILURE(peers.Connect());
  ASSERT_EQ(6, peers.backend->Write("intact", 6).count);
  ASSERT_NO_FATAL_FAILURE(peers.ExpectBytes(*peers.client, "intact"));

  // The record promises 32 bytes of TLSCiphertext but supplies only two.
  constexpr unsigned char fragment[] = {23, 3, 3, 0, 32, 0xaa, 0xbb};
  ASSERT_EQ(static_cast<ssize_t>(sizeof(fragment)),
            send(peers.backend_fd.get(), fragment, sizeof(fragment), 0));
  DriveRelay(*peers.relay);
  ASSERT_FALSE(peers.relay->finished());
  char byte;
  const auto partial = peers.client->Read(&byte, 1);
  ASSERT_TRUE(Pending(partial.status));
  EXPECT_EQ(0, partial.count);
  ASSERT_EQ(0, shutdown(peers.backend_fd.get(), SHUT_WR));
  ASSERT_TRUE(
      DriveUntil(*peers.relay, [&] { return peers.relay->finished(); }));
  EXPECT_EQ(-1, peers.relay->ClientPoll().fd);
  EXPECT_EQ(-1, peers.relay->BackendPoll().fd);
  peers.relay.reset();
  const auto eof = peers.client->Read(&byte, 1);
  EXPECT_EQ(Status::kFailed, eof.status);
  EXPECT_EQ(0, eof.count);
}

// Actual wire preflight/fill only; not deployment or currentness evidence.
TEST(CoreTlsTest, V2BinaryCertificateSurvivesRetainedFill) {
  wire::Control input;
  input.set_version(2);
  auto* endpoint = input.mutable_reply()->add_endpoints();
  endpoint->set_listener_id(std::string(64, 'b'));
  endpoint->set_front_port(1234);
  const std::string der("\x30\x00\xff\x80", 4);
  endpoint->set_front_tls_certificate_der(der);
  std::string bytes;
  ASSERT_TRUE(input.SerializeToString(&bytes));
  ASSERT_TRUE(internal::HasUnambiguousCoreControlWire(bytes));
  wire::Control output;
  ASSERT_TRUE(internal::DecodeCoreControlWire(bytes, output));
  ASSERT_EQ(output.reply().endpoints_size(), 1);
  EXPECT_EQ(output.reply().endpoints(0).front_tls_certificate_der(), der);
}
TEST(CoreTlsTest, V2RequiresExplicitLaunchTlsVersion) {
  wire::Control input;
  input.set_version(2);
  input.mutable_launch();
  std::string bytes;
  ASSERT_TRUE(input.SerializeToString(&bytes));
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(bytes));
  input.mutable_launch()->set_local_proxy_tls_version(1);
  ASSERT_TRUE(input.SerializeToString(&bytes));
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(bytes));
  input.mutable_launch()->set_local_proxy_tls_version(2);
  ASSERT_TRUE(input.SerializeToString(&bytes));
  wire::Control output;
  ASSERT_TRUE(internal::DecodeCoreControlWire(bytes, output));
  EXPECT_EQ(output.launch().local_proxy_tls_version(), 2u);
}
TEST(CoreTlsTest, VersionMayFollowPayloadButCannotRepeat) {
  const std::string bytes("\x22\x02\x78\x02\x08\x02", 6);
  EXPECT_TRUE(internal::HasUnambiguousCoreControlWire(bytes));
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(
      bytes + std::string("\x08\x02", 2)));
}
TEST(CoreTlsTest, V1LaunchRejectsTlsNegotiationField) {
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(
      std::string("\x08\x01\x22\x02\x78\x02", 6)));
  EXPECT_TRUE(internal::HasUnambiguousCoreControlWire(
      std::string("\x08\x01\x22\x00", 4)));
}
TEST(CoreTlsTest, CertificateBoundAndDuplicateRemainStrict) {
  wire::Control input;
  input.set_version(2);
  auto* endpoint = input.mutable_reply()->add_endpoints();
  endpoint->set_front_tls_certificate_der(std::string(4096, '\xff'));
  std::string bytes;
  ASSERT_TRUE(input.SerializeToString(&bytes));
  EXPECT_TRUE(internal::HasUnambiguousCoreControlWire(bytes));
  endpoint->set_front_tls_certificate_der(std::string(4097, '\xff'));
  ASSERT_TRUE(input.SerializeToString(&bytes));
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(bytes));
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(
      std::string("\x08\x02\x32\x08\x3a\x06\x1a\x01\xff\x1a\x01\xff", 12)));
}
TEST(CoreTlsTest, EmptyCertificateAndUnknownVersionFailPreflight) {
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(
      std::string("\x08\x02\x32\x04\x3a\x02\x1a\x00", 8)));
  EXPECT_FALSE(internal::HasUnambiguousCoreControlWire(
      std::string("\x08\x03\x32\x00", 4)));
}

}  // namespace
}  // namespace aegis::proxy
