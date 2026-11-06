// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_PROXY_CORE_TLS_H_
#define CHROME_BROWSER_AEGIS_PROXY_CORE_TLS_H_

#include <memory>
#include <string>
#include <string_view>

#include "base/time/time.h"
#include "base/values.h"
#include "crypto/keypair.h"
#include "third_party/boringssl/src/include/openssl/ssl.h"

namespace aegis::proxy {

// Supervisor-local key ownership. A front identity cannot export a child key.
class CoreTlsIdentity final {
 public:
  enum class Role { kFront, kBackend };

  static std::unique_ptr<CoreTlsIdentity> Generate(Role role, base::Time now);
  ~CoreTlsIdentity();
  CoreTlsIdentity(const CoreTlsIdentity&) = delete;
  CoreTlsIdentity& operator=(const CoreTlsIdentity&) = delete;

  std::string_view certificate_der() const { return certificate_der_; }
  bssl::UniquePtr<SSL_CTX> FrontServerContext() const;
  bool AddBackendXrayTls(base::DictValue& inbound) const;

 private:
  CoreTlsIdentity(Role role, crypto::keypair::PrivateKey key,
                  std::string certificate_der);
  const Role role_;
  crypto::keypair::PrivateKey key_;
  std::string certificate_der_;
};

class CoreTlsSocket final {
 public:
  enum class Status { kReady, kWantRead, kWantWrite, kClosed, kFailed };
  struct Result {
    Status status;
    int count = 0;
  };

  // The FD remains owned by the caller and must be nonblocking.
  static std::unique_ptr<CoreTlsSocket> Accept(int fd, SSL_CTX& front);
  static std::unique_ptr<CoreTlsSocket> Connect(int fd,
                                               std::string_view exact_peer_der);
  ~CoreTlsSocket();
  CoreTlsSocket(const CoreTlsSocket&) = delete;
  CoreTlsSocket& operator=(const CoreTlsSocket&) = delete;

  Status Handshake();
  Result Read(char* data, int size);
  Result Write(const char* data, int size);
  // A successful return means our close_notify has been sent. Read can
  // continue until the peer closes its sending direction.
  Status CloseWrite();
  bool HasBufferedData() const;

 private:
  CoreTlsSocket(bssl::UniquePtr<SSL> ssl, std::string expected_peer);
  static ssl_verify_result_t VerifyPeer(SSL* ssl, uint8_t* alert);
  Status StatusFor(int result) const;

  bssl::UniquePtr<SSL> ssl_;
  const std::string expected_peer_;
  bool ready_ = false;
  bool failed_ = false;
};

}  // namespace aegis::proxy

#endif  // CHROME_BROWSER_AEGIS_PROXY_CORE_TLS_H_
