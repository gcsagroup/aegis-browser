// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_SOCKS5_INBOUND_PARSER_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_SOCKS5_INBOUND_PARSER_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace aegis_access {

// SOCKS5 no-auth inbound parser (RFC 1928 subset).
//
// Admitted: version 5, method 0x00, CONNECT.
// Rejected: username/password-only greetings, BIND, UDP ASSOCIATE.
enum class Socks5InboundParseStatus {
  kNeedMoreData,
  kOk,
  kMalformedGreeting,
  kNoAcceptableAuthMethod,
  kUsernamePasswordNotAdmitted,
  kMalformedRequest,
  kUnsupportedCommand,
  kUnsupportedAddressType,
};

struct Socks5ConnectTarget {
  enum class AddressType {
    kIPv4,
    kDomain,
    kIPv6,
  };

  AddressType address_type = AddressType::kDomain;
  std::string host;
  uint16_t port = 0;
};

struct Socks5GreetingParseResult {
  Socks5InboundParseStatus status = Socks5InboundParseStatus::kNeedMoreData;
  // Number of greeting bytes consumed when status == kOk.
  size_t consumed = 0;
  // Method-selection reply bytes when status == kOk (VER + METHOD).
  std::vector<uint8_t> method_reply;
};

struct Socks5ConnectParseResult {
  Socks5InboundParseStatus status = Socks5InboundParseStatus::kNeedMoreData;
  size_t consumed = 0;
  std::optional<Socks5ConnectTarget> target;
};

Socks5GreetingParseResult ParseSocks5NoAuthGreeting(
    const std::vector<uint8_t>& buffer);

Socks5ConnectParseResult ParseSocks5ConnectRequest(
    const std::vector<uint8_t>& buffer);

// Success reply with BND.ADDR 0.0.0.0 / BND.PORT 0 (tunnel endpoint only).
std::vector<uint8_t> Socks5SuccessReply();
std::vector<uint8_t> Socks5NoAcceptableMethodReply();
std::vector<uint8_t> Socks5CommandNotSupportedReply();

}  // namespace aegis_access

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_SOCKS5_INBOUND_PARSER_H_
