// Copyright 2026 GCSA
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "src/interpreter/aegis-bytecode-shadow.h"

#include <algorithm>
#include <atomic>

#include "src/flags/flags.h"
#include "src/heap/parked-scope-inl.h"
#include "src/interpreter/bytecode-array-iterator.h"
#include "src/interpreter/bytecodes.h"
#include "src/objects/bytecode-array-inl.h"
#include "src/tracing/trace-event.h"

namespace v8 {
namespace internal {
namespace interpreter {
namespace {

constexpr uint64_t kFnvOffsetBasis = 14695981039346656037ULL;
constexpr uint64_t kFnvPrime = 1099511628211ULL;
constexpr uint8_t kSignatureSchemaVersion = 1;
constexpr unsigned int kHardMaxBytes = 64 * 1024;
constexpr unsigned int kHardMaxRecords = 1000;

std::atomic<unsigned int> g_aegis_shadow_records{0};

uint64_t HashByte(uint64_t hash, uint8_t value) {
  return (hash ^ value) * kFnvPrime;
}

uint64_t FinalizeSignature(uint64_t hash, uint64_t opcode_count) {
  for (int shift = 0; shift < 64; shift += 8) {
    hash = HashByte(hash, static_cast<uint8_t>(opcode_count >> shift));
  }
  return hash;
}

bool TryReserveRecord(unsigned int requested_limit) {
  const unsigned int limit = std::min(requested_limit, kHardMaxRecords);
  unsigned int current = g_aegis_shadow_records.load(std::memory_order_relaxed);
  while (current < limit) {
    if (g_aegis_shadow_records.compare_exchange_weak(
            current, current + 1, std::memory_order_relaxed,
            std::memory_order_relaxed)) {
      return true;
    }
  }
  return false;
}

}  // namespace

uint64_t AegisOpcodeSequenceSignature(base::Vector<const uint8_t> opcodes) {
  uint64_t hash = HashByte(kFnvOffsetBasis, kSignatureSchemaVersion);
  for (uint8_t opcode : opcodes) {
    hash = HashByte(hash, opcode);
  }
  // Domain-separate a sequence from a same-prefix sequence with a different
  // length without incorporating bytecode operands or source metadata.
  return FinalizeSignature(hash, opcodes.size());
}

AegisBytecodeShadowSummary SummarizeAegisBytecode(
    Handle<BytecodeArray> bytecodes, unsigned int max_bytes) {
  AegisBytecodeShadowSummary summary;
  summary.byte_length = bytecodes->length();
  if (summary.byte_length < 0 ||
      static_cast<unsigned int>(summary.byte_length) > max_bytes) {
    summary.skipped_too_large = true;
    return summary;
  }

  uint64_t hash = HashByte(kFnvOffsetBasis, kSignatureSchemaVersion);
  {
    DisallowGarbageCollection no_gc;
    for (BytecodeArrayIterator iterator(bytecodes, 0, no_gc); !iterator.done();
         iterator.Advance()) {
      hash = HashByte(hash, Bytecodes::ToByte(iterator.current_bytecode()));
      summary.opcode_count += 1;
    }
  }
  summary.signature = FinalizeSignature(hash, summary.opcode_count);
  return summary;
}

void MaybeObserveAegisBytecode(Handle<BytecodeArray> bytecodes) {
  if (!v8_flags.aegis_bytecode_shadow) return;
  if (!TRACE_EVENT_CATEGORY_ENABLED(
          TRACE_DISABLED_BY_DEFAULT("v8.aegis.bytecode_shadow"))) {
    return;
  }
  const unsigned int configured_max_records =
      v8_flags.aegis_bytecode_shadow_max_records;
  if (!TryReserveRecord(configured_max_records)) return;

  const unsigned int configured_max_bytes =
      v8_flags.aegis_bytecode_shadow_max_bytes;
  const AegisBytecodeShadowSummary summary = SummarizeAegisBytecode(
      bytecodes, std::min(configured_max_bytes, kHardMaxBytes));
  TRACE_EVENT_INSTANT(
      TRACE_DISABLED_BY_DEFAULT("v8.aegis.bytecode_shadow"),
      "V8.AegisBytecodeShadow", "record_schema", 2u, "signature_schema", 1u,
      "mode_code", 0u, "status_code", summary.skipped_too_large ? 1u : 0u,
      "bytes", static_cast<uint32_t>(summary.byte_length), "opcodes",
      static_cast<uint32_t>(summary.opcode_count), "signature_hi",
      static_cast<uint32_t>(summary.signature >> 32), "signature_lo",
      static_cast<uint32_t>(summary.signature), "would_block", 0u);
}

}  // namespace interpreter
}  // namespace internal
}  // namespace v8
