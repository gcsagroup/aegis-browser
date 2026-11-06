// Copyright 2026 GCSA
#include "chrome/browser/aegis/proxy/core_tls.h"

#include <cstdint>
#include <utility>

#include "base/containers/span.h"
#include "net/cert/x509_util.h"
#include "third_party/boringssl/src/include/openssl/bio.h"
#include "third_party/boringssl/src/include/openssl/bytestring.h"
#include "third_party/boringssl/src/include/openssl/err.h"
#include "third_party/boringssl/src/include/openssl/mem.h"
#include "third_party/boringssl/src/include/openssl/pem.h"
#include "third_party/boringssl/src/include/openssl/x509.h"

namespace aegis::proxy {
namespace {

constexpr size_t kMaxCertificateBytes = 4096;
constexpr uint8_t kHttp11Alpn[] = {8, 'h', 't', 't', 'p', '/', '1', '.', '1'};

bssl::UniquePtr<SSL_CTX> NewContext() {
  bssl::UniquePtr<SSL_CTX> ctx(SSL_CTX_new(TLS_method()));
  if (!ctx || !SSL_CTX_set_min_proto_version(ctx.get(), TLS1_3_VERSION) ||
      !SSL_CTX_set_max_proto_version(ctx.get(), TLS1_3_VERSION) ||
      !SSL_CTX_set_num_tickets(ctx.get(), 0)) {
    return nullptr;
  }
  SSL_CTX_set_session_cache_mode(ctx.get(), SSL_SESS_CACHE_OFF);
  SSL_CTX_set_options(ctx.get(), SSL_OP_NO_TICKET);
  return ctx;
}

int SelectHttp11(SSL*, const uint8_t** selected, uint8_t* selected_size,
                 const uint8_t* offered, unsigned offered_size, void*) {
  CBS protocols;
  CBS_init(&protocols, offered, offered_size);
  const auto expected = base::span(kHttp11Alpn).subspan<1>();
  while (CBS_len(&protocols)) {
    CBS protocol;
    if (!CBS_get_u8_length_prefixed(&protocols, &protocol) ||
        !CBS_len(&protocol)) {
      return SSL_TLSEXT_ERR_ALERT_FATAL;
    }
    if (CBS_mem_equal(&protocol, expected.data(), expected.size())) {
      *selected = CBS_data(&protocol);
      *selected_size = static_cast<uint8_t>(CBS_len(&protocol));
      return SSL_TLSEXT_ERR_OK;
    }
  }
  return SSL_TLSEXT_ERR_ALERT_FATAL;
}

bssl::UniquePtr<X509> ParseExactDer(std::string_view der) {
  if (der.empty() || der.size() > kMaxCertificateBytes)
    return nullptr;
  const auto bytes = base::as_byte_span(der);
  const auto* next = bytes.data();
  bssl::UniquePtr<X509> cert(d2i_X509(nullptr, &next, der.size()));
  if (!cert || next != bytes.subspan(bytes.size()).data())
    return nullptr;
  return cert;
}

bool MatchesLeaf(SSL* ssl, std::string_view expected) {
  const auto* chain = SSL_get0_peer_certificates(ssl);
  return chain && sk_CRYPTO_BUFFER_num(chain) == 1 &&
         !expected.empty() && expected.size() <= kMaxCertificateBytes &&
         net::x509_util::CryptoBufferAsStringPiece(
             sk_CRYPTO_BUFFER_value(chain, 0)) == expected;
}

class KeyPem final {
 public:
  KeyPem() : bio_(BIO_new(BIO_s_mem())) {}
  ~KeyPem() {
    const uint8_t* p;
    size_t n;
    if (bio_ && BIO_mem_contents(bio_.get(), &p, &n) && n)
      OPENSSL_cleanse(const_cast<uint8_t*>(p), n);
  }
  std::string_view Encode(const EVP_PKEY* key) {
    const uint8_t* p;
    size_t n;
    if (!bio_ ||
        !PEM_write_bio_PrivateKey(bio_.get(), key, nullptr, nullptr, 0, nullptr,
                                 nullptr) ||
        !BIO_mem_contents(bio_.get(), &p, &n) || !n || n > 8192) {
      return {};
    }
    return {reinterpret_cast<const char*>(p), n};
  }
 private:
  bssl::UniquePtr<BIO> bio_;
};

}  // namespace

CoreTlsIdentity::CoreTlsIdentity(Role role, crypto::keypair::PrivateKey key,
                                 std::string certificate_der)
    : role_(role), key_(std::move(key)),
      certificate_der_(std::move(certificate_der)) {}

CoreTlsIdentity::~CoreTlsIdentity() = default;

std::unique_ptr<CoreTlsIdentity> CoreTlsIdentity::Generate(Role role,
                                                           base::Time now) {
  if (now.is_null())
    return nullptr;
  auto key = crypto::keypair::PrivateKey::GenerateEcP256();
  std::string der;
  const char* name = role == Role::kFront ? "CN=Aegis owned front"
                                         : "CN=Aegis owned backend";
  // These times are certificate encoding only. Session admission, deadlines
  // and lease bounds come from the independent operation fence.
  if (!net::x509_util::CreateSelfSignedCert(
          key.key(), net::x509_util::DIGEST_SHA256, name, 1,
          now - base::Minutes(1), now + base::Hours(1), {}, &der) ||
      !ParseExactDer(der)) {
    return nullptr;
  }
  return std::unique_ptr<CoreTlsIdentity>(
      new CoreTlsIdentity(role, std::move(key), std::move(der)));
}

bssl::UniquePtr<SSL_CTX> CoreTlsIdentity::FrontServerContext() const {
  if (role_ != Role::kFront)
    return nullptr;
  auto ctx = NewContext();
  if (!ctx ||
      !SSL_CTX_use_certificate_ASN1(
          ctx.get(), certificate_der_.size(),
          reinterpret_cast<const uint8_t*>(certificate_der_.data())) ||
      !SSL_CTX_use_PrivateKey(ctx.get(), const_cast<EVP_PKEY*>(key_.key())) ||
      !SSL_CTX_check_private_key(ctx.get())) {
    return nullptr;
  }
  SSL_CTX_set_alpn_select_cb(ctx.get(), SelectHttp11, nullptr);
  return ctx;
}

bool CoreTlsIdentity::AddBackendXrayTls(base::DictValue& inbound) const {
  if (role_ != Role::kBackend)
    return false;
  auto cert = ParseExactDer(certificate_der_);
  bssl::UniquePtr<BIO> cert_bio(BIO_new(BIO_s_mem()));
  const uint8_t* pem;
  size_t size;
  if (!cert || !cert_bio || !PEM_write_bio_X509(cert_bio.get(), cert.get()) ||
      !BIO_mem_contents(cert_bio.get(), &pem, &size) || !size || size > 8192) {
    return false;
  }
  KeyPem key_pem;
  auto key = key_pem.Encode(key_.key());
  if (key.empty())
    return false;

  base::ListValue certificate;
  certificate.Append(std::string(reinterpret_cast<const char*>(pem), size));
  base::ListValue private_key;
  private_key.Append(std::string(key));
  base::DictValue pair;
  pair.Set("certificate", std::move(certificate));
  pair.Set("key", std::move(private_key));
  pair.Set("oneTimeLoading", true);
  base::ListValue pairs;
  pairs.Append(std::move(pair));
  base::ListValue alpn;
  alpn.Append("http/1.1");
  base::DictValue tls;
  tls.Set("certificates", std::move(pairs));
  tls.Set("alpn", std::move(alpn));
  tls.Set("minVersion", "1.3");
  tls.Set("maxVersion", "1.3");
  tls.Set("enableSessionResumption", false);
  base::DictValue stream;
  stream.Set("security", "tls");
  stream.Set("tlsSettings", std::move(tls));
  inbound.Set("streamSettings", std::move(stream));
  return true;
}

CoreTlsSocket::CoreTlsSocket(bssl::UniquePtr<SSL> ssl, std::string expected_peer)
    : ssl_(std::move(ssl)), expected_peer_(std::move(expected_peer)) {}

CoreTlsSocket::~CoreTlsSocket() = default;

std::unique_ptr<CoreTlsSocket> CoreTlsSocket::Accept(int fd, SSL_CTX& front) {
  bssl::UniquePtr<SSL> ssl(SSL_new(&front));
  if (!ssl || !SSL_set_fd(ssl.get(), fd))
    return nullptr;
  SSL_set_early_data_enabled(ssl.get(), 0);
  SSL_set_accept_state(ssl.get());
  return std::unique_ptr<CoreTlsSocket>(new CoreTlsSocket(std::move(ssl), {}));
}

std::unique_ptr<CoreTlsSocket> CoreTlsSocket::Connect(
    int fd, std::string_view exact_peer_der) {
  if (!ParseExactDer(exact_peer_der))
    return nullptr;
  auto ctx = NewContext();
  if (!ctx || SSL_CTX_set_alpn_protos(ctx.get(), kHttp11Alpn,
                                      sizeof(kHttp11Alpn)) != 0) {
    return nullptr;
  }
  SSL_CTX_set_custom_verify(ctx.get(), SSL_VERIFY_PEER, VerifyPeer);
  bssl::UniquePtr<SSL> ssl(SSL_new(ctx.get()));
  if (!ssl || !SSL_set_fd(ssl.get(), fd))
    return nullptr;
  SSL_set_early_data_enabled(ssl.get(), 0);
  SSL_set_connect_state(ssl.get());
  auto connection = std::unique_ptr<CoreTlsSocket>(
      new CoreTlsSocket(std::move(ssl), std::string(exact_peer_der)));
  if (!SSL_set_app_data(connection->ssl_.get(), connection.get()))
    return nullptr;
  return connection;
}

ssl_verify_result_t CoreTlsSocket::VerifyPeer(SSL* ssl, uint8_t* alert) {
  const auto* self = static_cast<const CoreTlsSocket*>(SSL_get_app_data(ssl));
  if (self && MatchesLeaf(ssl, self->expected_peer_))
    return ssl_verify_ok;
  *alert = SSL_AD_BAD_CERTIFICATE;
  return ssl_verify_invalid;
}

CoreTlsSocket::Status CoreTlsSocket::StatusFor(int result) const {
  switch (SSL_get_error(ssl_.get(), result)) {
    case SSL_ERROR_WANT_READ: return Status::kWantRead;
    case SSL_ERROR_WANT_WRITE: return Status::kWantWrite;
    case SSL_ERROR_ZERO_RETURN: return Status::kClosed;
    default: return Status::kFailed;
  }
}

CoreTlsSocket::Status CoreTlsSocket::Handshake() {
  if (failed_)
    return Status::kFailed;
  if (ready_)
    return Status::kReady;
  ERR_clear_error();
  const int rv = SSL_do_handshake(ssl_.get());
  if (rv != 1) {
    const auto status = StatusFor(rv);
    if (status == Status::kWantRead || status == Status::kWantWrite)
      return status;
    failed_ = true;
    return Status::kFailed;
  }
  const uint8_t* alpn;
  unsigned size;
  SSL_get0_alpn_selected(ssl_.get(), &alpn, &size);
  CBS negotiated;
  CBS_init(&negotiated, alpn, size);
  const auto expected = base::span(kHttp11Alpn).subspan<1>();
  const bool http11 =
      CBS_mem_equal(&negotiated, expected.data(), expected.size());
  if (!http11 || SSL_version(ssl_.get()) != TLS1_3_VERSION ||
      SSL_session_reused(ssl_.get()) ||
      (!expected_peer_.empty() && !MatchesLeaf(ssl_.get(), expected_peer_))) {
    failed_ = true;
    return Status::kFailed;
  }
  ready_ = true;
  return Status::kReady;
}

CoreTlsSocket::Result CoreTlsSocket::Read(char* data, int size) {
  if (!ready_ || failed_ || size <= 0)
    return {Status::kFailed};
  ERR_clear_error();
  const int rv = SSL_read(ssl_.get(), data, size);
  return rv > 0 ? Result{Status::kReady, rv} : Result{StatusFor(rv)};
}

CoreTlsSocket::Result CoreTlsSocket::Write(const char* data, int size) {
  if (!ready_ || failed_ || size <= 0)
    return {Status::kFailed};
  ERR_clear_error();
  const int rv = SSL_write(ssl_.get(), data, size);
  return rv > 0 ? Result{Status::kReady, rv} : Result{StatusFor(rv)};
}

CoreTlsSocket::Status CoreTlsSocket::CloseWrite() {
  if (!ready_ || failed_)
    return Status::kFailed;
  ERR_clear_error();
  const int rv = SSL_shutdown(ssl_.get());
  return rv >= 0 ? Status::kReady : StatusFor(rv);
}

bool CoreTlsSocket::HasBufferedData() const {
  return ready_ && SSL_pending(ssl_.get()) > 0;
}

}  // namespace aegis::proxy
