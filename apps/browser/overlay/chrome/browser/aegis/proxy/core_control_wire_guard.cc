// Copyright 2026 GCSA
#include "chrome/browser/aegis/proxy/core_control_wire_guard.h"
#include <cstdint>
#include <bit>
#include <limits>
#include "chrome/browser/aegis/proxy/core_control_limits.h"
namespace aegis::proxy::internal {
namespace {
enum class Message { kControl, kLaunch, kGroup, kInbound, kOwner, kLifecycle,
                     kReply, kEndpoint, kNone };
enum class Kind { kInvalid, kVarint, kString, kBytes, kMessage };
struct Rule {
  Kind kind = Kind::kInvalid;
  Message child = Message::kNone;
  unsigned repeated_limit = 0;
  uint64_t maximum = std::numeric_limits<uint64_t>::max();
};
constexpr Rule Scalar(uint64_t maximum = std::numeric_limits<uint64_t>::max()) {
  return {Kind::kVarint, Message::kNone, 0, maximum};
}
constexpr Rule Text() { return {Kind::kString}; }
constexpr Rule Nested(Message child, unsigned limit = 0) {
  return {Kind::kMessage, child, limit};
}
Rule Field(Message message, unsigned field, uint32_t version) {
  switch (message) {
    case Message::kOwner:
      switch (field) {
        case 1: return Scalar(0xffffffffu);
        case 2: return Text();
        case 3: return Text();
      }
      break;
    case Message::kGroup:
      switch (field) {
        case 1: return Nested(Message::kOwner);
        case 2: return Text();
        case 3: return Scalar();
        case 4: return Scalar(0xffffffffu);
        case 5: return Text();
        case 6: return Scalar(0xffffffffu);
        case 7: return Text();
        case 8: return Text();
        case 9: return Text();
        case 10: return Text();
        case 11: return Text();
        case 12: return Scalar(2);
        case 13: return Scalar(3);
        case 14: return Scalar(1);
        case 15: return {Kind::kString, Message::kNone, 0, 2};
        case 16: return {Kind::kString, Message::kNone, 0, 259};
      }
      break;
    case Message::kInbound:
      switch (field) {
        case 1: return Scalar(0xffffffffu);
        case 2: return Scalar(0xffffffffu);
        case 3: return Text();
        case 4: return Text();
        case 5: return Text();
        case 6: return Text();
        case 7: return Text();
      }
      break;
    case Message::kLaunch:
      switch (field) {
        case 1: return Text();
        case 2: return Scalar(0xffffffffu);
        case 3: return Text();
        case 4: return Scalar();
        case 5: return Scalar();
        case 6: return Nested(Message::kGroup, 16);
        case 7: return Nested(Message::kInbound, 32);
        case 8: return Text();
        case 9: return Scalar(0xffffffffu);
        case 10: return Text();
        case 11: return Text();
        case 12: return Text();
        case 13: return Scalar(0xffffffffu);
        case 14: return Scalar();
        case 15: return version == 2 ? Scalar(2) : Rule{};
      }
      break;
    case Message::kLifecycle:
      switch (field) {
        case 1: return Scalar(0xffffffffu);
        case 2: return Text();
        case 3: return Scalar();
        case 4: return Scalar(0xffffffffu);
        case 5: return Scalar(0xffffffffu);
      }
      break;
    case Message::kEndpoint:
      switch (field) {
        case 1: return Text();
        case 2: return Scalar(0xffffffffu);
        case 3: return version == 2
            ? Rule{Kind::kBytes, Message::kNone, 0, 4096} : Rule{};
      }
      break;
    case Message::kReply:
      switch (field) {
        case 1: return Scalar(0xffffffffu);
        case 2: return Text();
        case 3: return Text();
        case 4: return Text();
        case 5: return Text();
        case 6: return Scalar();
        case 7: return Nested(Message::kEndpoint, 32);
        case 8: return Scalar(1);
        case 9: return Scalar();
        case 10: return Scalar();
        case 11: return Scalar();
        case 12: return Scalar();
      }
      break;
    case Message::kControl:
      switch (field) {
        case 1: return Scalar(0xffffffffu);
        case 2: return Scalar();
        case 3: return Text();
        case 4: return Nested(Message::kLaunch);
        case 5: return Nested(Message::kLifecycle);
        case 6: return Nested(Message::kReply);
      }
      break;
    case Message::kNone: break;
  }
  return {};
}
bool Varint(std::string_view& input, uint64_t& value) {
  value = 0;
  for (unsigned shift = 0; shift < 64; shift += 7) {
    if (input.empty()) return false;
    const auto byte = static_cast<uint8_t>(input.front());
    input.remove_prefix(1);
    if (shift == 63 && byte > 1) return false;
    value |= static_cast<uint64_t>(byte & 0x7f) << shift;
    if (!(byte & 0x80)) return true;
  }
  return false;
}
// The generated parser must never allocate/log a malformed UTF-8 string.
bool UTF8(std::string_view text) {
  size_t i = 0;
  auto continuation = [&](size_t index) {
    return index < text.size() &&
           (static_cast<uint8_t>(text[index]) & 0xc0) == 0x80;
  };
  while (i < text.size()) {
    const auto lead = static_cast<uint8_t>(text[i++]);
    if (lead < 0x80) continue;
    if (lead >= 0xc2 && lead <= 0xdf) {
      if (!continuation(i)) return false;
      ++i;
    } else if (lead >= 0xe0 && lead <= 0xef) {
      if (!continuation(i) || !continuation(i + 1)) return false;
      const auto next = static_cast<uint8_t>(text[i]);
      if ((lead == 0xe0 && next < 0xa0) || (lead == 0xed && next > 0x9f))
        return false;
      i += 2;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      if (!continuation(i) || !continuation(i + 1) || !continuation(i + 2))
        return false;
      const auto next = static_cast<uint8_t>(text[i]);
      if ((lead == 0xf0 && next < 0x90) || (lead == 0xf4 && next > 0x8f))
        return false;
      i += 3;
    } else {
      return false;
    }
  }
  return true;
}
bool Scan(std::string_view input, Message message, unsigned depth,
          uint32_t version) {
  if (depth > 4) return false;  // Control / Launch / Group / Owner.
  uint32_t seen = 0;
  unsigned groups = 0, inbounds = 0, endpoints = 0, payloads = 0;
  while (!input.empty()) {
    uint64_t tag = 0;
    if (!Varint(input, tag) || tag == 0 || (tag >> 3) > 16) return false;
    const auto field = static_cast<unsigned>(tag >> 3);
    if (field == 0) return false;
    const Rule rule = Field(message, field, version);
    if (rule.kind == Kind::kInvalid) return false;
    const uint32_t bit = uint32_t{1} << field;
    if (rule.repeated_limit) {
      unsigned& count = message == Message::kReply ? endpoints :
                        field == 6 ? groups : inbounds;
      if (++count > rule.repeated_limit) return false;
    } else {
      if (seen & bit) return false;
      seen |= bit;
    }
    if (message == Message::kControl && field >= 4 && ++payloads != 1)
      return false;
    if (rule.kind == Kind::kVarint) {
      uint64_t ignored = 0;
      if ((tag & 7) != 0 || !Varint(input, ignored) || ignored > rule.maximum)
        return false;
      if (message == Message::kGroup &&
          ((field == 12 && ignored != 2) ||
           (field == 13 && ignored == 0) ||
           (field == 14 && ignored != 1))) return false;
      if (message == Message::kLaunch && field == 15 && ignored != 2)
        return false;
      continue;
    }
    uint64_t length = 0;
    if ((tag & 7) != 2 || !Varint(input, length) || length > input.size())
      return false;
    const auto nested = input.substr(0, static_cast<size_t>(length));
    input.remove_prefix(static_cast<size_t>(length));
    if (rule.kind == Kind::kBytes && (!length || length > rule.maximum))
      return false;
    if (rule.kind == Kind::kString &&
        (length > rule.maximum || !UTF8(nested))) return false;
    if (message == Message::kGroup && field == 15) {
      if (nested.size() > 2 || (nested.size() == 2 && nested[0] == nested[1]))
        return false;
      for (unsigned char value : nested) if (value > 1) return false;
    }
    if (rule.kind == Kind::kMessage && !Scan(nested, rule.child, depth + 1, version))
      return false;
  }
  if (message == Message::kLaunch && version == 2 && !(seen & (1u << 15)))
    return false;
  if (message == Message::kGroup) {
    constexpr uint32_t required = (1u << 12) | (1u << 13) | (1u << 14);
    if ((seen & required) != required) return false;
  }
  return message != Message::kControl || payloads == 1;
}

// A second allocation-free walk fills fresh, retained protobuf fields directly.
// Do not call protobuf's generic parser: its patch/string parser buffers are
// outside delivery's erasure custody. Every destination string is empty and
// written exactly once after the entire frame has passed preflight.
struct WireField { unsigned number = 0; uint64_t scalar = 0; std::string_view bytes; };
bool NextField(std::string_view& input, WireField& field) {
  uint64_t tag = 0;
  if (!Varint(input, tag)) return false;
  field.number = static_cast<unsigned>(tag >> 3);
  if ((tag & 7) == 0) return Varint(input, field.scalar);
  uint64_t length = 0;
  if ((tag & 7) != 2 || !Varint(input, length) || length > input.size())
    return false;
  field.bytes = input.substr(0, static_cast<size_t>(length));
  input.remove_prefix(static_cast<size_t>(length)); return true;
}
bool Fill(wire::Owner&, std::string_view);
bool Fill(wire::Group&, std::string_view);
bool Fill(wire::Inbound&, std::string_view);
bool Fill(wire::Launch&, std::string_view);
bool Fill(wire::Lifecycle&, std::string_view);
bool Fill(wire::Endpoint&, std::string_view);
bool Fill(wire::Reply&, std::string_view);
bool Fill(wire::Control&, std::string_view);
bool Fill(wire::Owner& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: output.set_channel(static_cast<uint32_t>(field.scalar)); break;
      case 2: output.mutable_profile()->assign(field.bytes.data(), field.bytes.size()); break;
      case 3: output.mutable_partition()->assign(field.bytes.data(), field.bytes.size()); break;
      default: return false;
    }
  }
  return true;
}
bool Fill(wire::Group& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: if (!Fill(*output.mutable_owner(), field.bytes)) return false; break;
      case 2: output.mutable_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 3: output.set_selection(static_cast<uint64_t>(field.scalar)); break;
      case 4: output.set_transport(static_cast<uint32_t>(field.scalar)); break;
      case 5: output.mutable_server_ip()->assign(field.bytes.data(), field.bytes.size()); break;
      case 6: output.set_server_port(static_cast<uint32_t>(field.scalar)); break;
      case 7: output.mutable_vless_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 8: output.mutable_server_name()->assign(field.bytes.data(), field.bytes.size()); break;
      case 9: output.mutable_reality_key()->assign(field.bytes.data(), field.bytes.size()); break;
      case 10: output.mutable_short_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 11: output.mutable_ws_path()->assign(field.bytes.data(), field.bytes.size()); break;
      case 12: output.set_configuration_version(static_cast<uint32_t>(field.scalar)); break;
      case 13: output.set_address_kind(static_cast<uint32_t>(field.scalar)); break;
      case 14: output.set_fingerprint(static_cast<uint32_t>(field.scalar)); break;
      case 15: output.mutable_alpn()->assign(field.bytes.data(), field.bytes.size()); break;
      case 16: output.mutable_ws_host()->assign(field.bytes.data(), field.bytes.size()); break;
      default: return false;
    }
  }
  return true;
}
bool Fill(wire::Inbound& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: output.set_group_index(static_cast<uint32_t>(field.scalar)); break;
      case 2: output.set_transport(static_cast<uint32_t>(field.scalar)); break;
      case 3: output.mutable_username()->assign(field.bytes.data(), field.bytes.size()); break;
      case 4: output.mutable_password()->assign(field.bytes.data(), field.bytes.size()); break;
      case 5: output.mutable_listener_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 6: output.mutable_registration_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 7: output.mutable_credential_slot()->assign(field.bytes.data(), field.bytes.size()); break;
      default: return false;
    }
  }
  return true;
}
bool Fill(wire::Launch& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: output.mutable_profile()->assign(field.bytes.data(), field.bytes.size()); break;
      case 2: output.set_channel(static_cast<uint32_t>(field.scalar)); break;
      case 3: output.mutable_lease_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 4: output.set_expiry_unix_ms(std::bit_cast<int64_t>(field.scalar)); break;
      case 5: output.set_network_epoch(static_cast<uint64_t>(field.scalar)); break;
      case 6: if (!Fill(*output.add_groups(), field.bytes)) return false; break;
      case 7: if (!Fill(*output.add_inbounds(), field.bytes)) return false; break;
      case 8: output.mutable_probe_host()->assign(field.bytes.data(), field.bytes.size()); break;
      case 9: output.set_probe_port(static_cast<uint32_t>(field.scalar)); break;
      case 10: output.mutable_probe_path()->assign(field.bytes.data(), field.bytes.size()); break;
      case 11: output.mutable_xray_path()->assign(field.bytes.data(), field.bytes.size()); break;
      case 12: output.mutable_session_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 13: output.set_remaining_ms(static_cast<uint32_t>(field.scalar)); break;
      case 14: output.set_group_set_version(static_cast<uint64_t>(field.scalar)); break;
      case 15: output.set_local_proxy_tls_version(static_cast<uint32_t>(field.scalar)); break;
      default: return false;
    }
  }
  return true;
}
bool Fill(wire::Lifecycle& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: output.set_kind(static_cast<wire::Lifecycle::Kind>(field.scalar)); break;
      case 2: output.mutable_attempt()->assign(field.bytes.data(), field.bytes.size()); break;
      case 3: output.set_epoch(static_cast<uint64_t>(field.scalar)); break;
      case 4: output.set_remaining_ms(static_cast<uint32_t>(field.scalar)); break;
      case 5: output.set_reason(static_cast<uint32_t>(field.scalar)); break;
      default: return false;
    }
  }
  return true;
}
bool Fill(wire::Endpoint& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: output.mutable_listener_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 2: output.set_front_port(static_cast<uint32_t>(field.scalar)); break;
      case 3: output.mutable_front_tls_certificate_der()->assign(field.bytes.data(), field.bytes.size()); break;
      default: return false;
    }
  }
  return true;
}
bool Fill(wire::Reply& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: output.set_error(static_cast<uint32_t>(field.scalar)); break;
      case 2: output.mutable_session_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 3: output.mutable_asset_digest()->assign(field.bytes.data(), field.bytes.size()); break;
      case 4: output.mutable_config_digest()->assign(field.bytes.data(), field.bytes.size()); break;
      case 5: output.mutable_probe_digest()->assign(field.bytes.data(), field.bytes.size()); break;
      case 6: output.set_epoch(static_cast<uint64_t>(field.scalar)); break;
      case 7: if (!Fill(*output.add_endpoints(), field.bytes)) return false; break;
      case 8: output.set_child_reaped(field.scalar != 0); break;
      case 9: output.set_child_pid(std::bit_cast<int64_t>(field.scalar)); break;
      case 10: output.set_child_parent(std::bit_cast<int64_t>(field.scalar)); break;
      case 11: output.set_child_birth_seconds(static_cast<uint64_t>(field.scalar)); break;
      case 12: output.set_child_birth_microseconds(static_cast<uint64_t>(field.scalar)); break;
      default: return false;
    }
  }
  return true;
}
bool Fill(wire::Control& output, std::string_view input) {
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    switch (field.number) {
      case 1: output.set_version(static_cast<uint32_t>(field.scalar)); break;
      case 2: output.set_sequence(static_cast<uint64_t>(field.scalar)); break;
      case 3: output.mutable_session_id()->assign(field.bytes.data(), field.bytes.size()); break;
      case 4: if (!Fill(*output.mutable_launch(), field.bytes)) return false; break;
      case 5: if (!Fill(*output.mutable_lifecycle(), field.bytes)) return false; break;
      case 6: if (!Fill(*output.mutable_reply(), field.bytes)) return false; break;
      default: return false;
    }
  }
  return true;
}
}  // namespace
bool HasUnambiguousCoreControlWire(std::string_view frame) noexcept {
  if (frame.empty() || frame.size() > kCoreControlMaxBytes) return false;
  // Establish the envelope version without allocations, independently of field
  // order. The full scan below still rejects every duplicate and unknown tag.
  uint32_t version = 0;
  auto input = frame;
  while (!input.empty()) {
    WireField field;
    if (!NextField(input, field)) return false;
    if (field.number == 1) {
      if (version || (field.scalar != 1 && field.scalar != 2)) return false;
      version = static_cast<uint32_t>(field.scalar);
    }
  }
  return version && Scan(frame, Message::kControl, 1, version);
}
bool DecodeCoreControlWire(std::string_view frame, wire::Control& output) noexcept {
  // Never replace an existing payload or populated string owned by a caller.
  if (output.ByteSizeLong() != 0 || !HasUnambiguousCoreControlWire(frame))
    return false;
  return Fill(output, frame);
}
}  // namespace aegis::proxy::internal
