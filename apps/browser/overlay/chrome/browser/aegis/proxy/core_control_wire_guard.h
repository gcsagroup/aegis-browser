// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_PROXY_CORE_CONTROL_WIRE_GUARD_H_
#define CHROME_BROWSER_AEGIS_PROXY_CORE_CONTROL_WIRE_GUARD_H_
#include <string_view>
#include "chrome/browser/aegis/proxy/access_core_control.pb.h"
namespace aegis::proxy::internal {
// Allocation-free structural preflight for the fixed Control schema. Rejects
// unknown fields, wrong wire types, singular replacements and any repeated
// oneof payload before protobuf may allocate a secret-bearing message.
// This accepts data only; it verifies no authority, identity or currentness.
bool HasUnambiguousCoreControlWire(std::string_view frame) noexcept;
// Output must be empty; on an unexpected fill failure, its caller must erase
// retained contents before destruction. No generic protobuf parser is used.
bool DecodeCoreControlWire(std::string_view frame, wire::Control& output) noexcept;
}  // namespace aegis::proxy::internal
#endif
