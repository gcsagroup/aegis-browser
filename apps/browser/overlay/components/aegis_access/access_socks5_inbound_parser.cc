// Copyright 2026 GCSA

#include "components/aegis_access/access_socks5_inbound_parser.h"

#include <cstdio>

namespace aegis_access {
namespace {

constexpr uint8_t kVersion = 0x05;
constexpr uint8_t kMethodNoAuth = 0x00;
constexpr uint8_t kMethodUsernamePassword = 0x02;
constexpr uint8_t kMethodNoneAcceptable = 0xFF;
constexpr uint8_t kCommandConnect = 0x01;
constexpr uint8_t kAtypIPv4 = 0x01;
constexpr uint8_t kAtypDomain = 0x03;
constexpr uint8_t kAtypIPv6 = 0x04;
constexpr uint8_t kReplySucceeded = 0x00;
constexpr uint8_t kReplyCommandNotSupported = 0x07;

}  // namespace

Socks5GreetingParseResult ParseSocks5NoAuthGreeting(
    const std::vector<uint8_t>& buffer) {
  Socks5GreetingParseResult result;
  if (buffer.empty()) {
    return result;
  }
  if (buffer[0] != kVersion) {
    result.status = Socks5InboundParseStatus::kMalformedGreeting;
    return result;
  }
  if (buffer.size() < 2) {
    return result;
  }
  const size_t nmethods = buffer[1];
  const size_t total = 2 + nmethods;
  if (nmethods == 0) {
    result.status = Socks5InboundParseStatus::kMalformedGreeting;
    return result;
  }
  if (buffer.size() < total) {
    return result;
  }

  bool offers_no_auth = false;
  bool offers_userpass = false;
  for (size_t i = 2; i < total; ++i) {
    if (buffer[i] == kMethodNoAuth) {
      offers_no_auth = true;
    } else if (buffer[i] == kMethodUsernamePassword) {
      offers_userpass = true;
    }
  }

  if (offers_no_auth) {
    result.status = Socks5InboundParseStatus::kOk;
    result.consumed = total;
    result.method_reply = {kVersion, kMethodNoAuth};
    return result;
  }
  if (offers_userpass) {
    result.status = Socks5InboundParseStatus::kUsernamePasswordNotAdmitted;
    return result;
  }
  result.status = Socks5InboundParseStatus::kNoAcceptableAuthMethod;
  return result;
}

Socks5ConnectParseResult ParseSocks5ConnectRequest(
    const std::vector<uint8_t>& buffer) {
  Socks5ConnectParseResult result;
  if (buffer.empty()) {
    return result;
  }
  if (buffer[0] != kVersion) {
    result.status = Socks5InboundParseStatus::kMalformedRequest;
    return result;
  }
  if (buffer.size() < 4) {
    return result;
  }
  if (buffer[2] != 0x00) {
    result.status = Socks5InboundParseStatus::kMalformedRequest;
    return result;
  }
  if (buffer[1] != kCommandConnect) {
    result.status = Socks5InboundParseStatus::kUnsupportedCommand;
    return result;
  }

  const uint8_t atyp = buffer[3];
  Socks5ConnectTarget target;
  size_t need = 0;
  switch (atyp) {
    case kAtypIPv4: {
      need = 4 + 4 + 2;
      if (buffer.size() < need) {
        return result;
      }
      char host[32];
      std::snprintf(host, sizeof(host), "%u.%u.%u.%u", buffer[4], buffer[5],
                    buffer[6], buffer[7]);
      target.address_type = Socks5ConnectTarget::AddressType::kIPv4;
      target.host = host;
      target.port =
          (static_cast<uint16_t>(buffer[8]) << 8) | static_cast<uint16_t>(buffer[9]);
      break;
    }
    case kAtypDomain: {
      if (buffer.size() < 5) {
        return result;
      }
      const size_t len = buffer[4];
      need = 5 + len + 2;
      if (buffer.size() < need) {
        return result;
      }
      if (len == 0) {
        result.status = Socks5InboundParseStatus::kMalformedRequest;
        return result;
      }
      target.address_type = Socks5ConnectTarget::AddressType::kDomain;
      target.host.assign(reinterpret_cast<const char*>(&buffer[5]), len);
      target.port = (static_cast<uint16_t>(buffer[5 + len]) << 8) |
                    static_cast<uint16_t>(buffer[6 + len]);
      break;
    }
    case kAtypIPv6: {
      need = 4 + 16 + 2;
      if (buffer.size() < need) {
        return result;
      }
      std::string host;
      for (size_t i = 4; i < 20; i += 2) {
        if (!host.empty()) {
          host.push_back(':');
        }
        char part[8];
        const uint16_t value = (static_cast<uint16_t>(buffer[i]) << 8) |
                               static_cast<uint16_t>(buffer[i + 1]);
        std::snprintf(part, sizeof(part), "%x", value);
        host.append(part);
      }
      target.address_type = Socks5ConnectTarget::AddressType::kIPv6;
      target.host = host;
      target.port = (static_cast<uint16_t>(buffer[20]) << 8) |
                    static_cast<uint16_t>(buffer[21]);
      break;
    }
    default:
      result.status = Socks5InboundParseStatus::kUnsupportedAddressType;
      return result;
  }

  if (target.port == 0 || target.host.empty()) {
    result.status = Socks5InboundParseStatus::kMalformedRequest;
    return result;
  }
  result.status = Socks5InboundParseStatus::kOk;
  result.consumed = need;
  result.target = target;
  return result;
}

std::vector<uint8_t> Socks5SuccessReply() {
  return {kVersion, kReplySucceeded, 0x00, kAtypIPv4, 0, 0, 0, 0, 0, 0};
}

std::vector<uint8_t> Socks5NoAcceptableMethodReply() {
  return {kVersion, kMethodNoneAcceptable};
}

std::vector<uint8_t> Socks5CommandNotSupportedReply() {
  return {kVersion, kReplyCommandNotSupported, 0x00, kAtypIPv4, 0, 0, 0, 0, 0,
          0};
}

}  // namespace aegis_access
