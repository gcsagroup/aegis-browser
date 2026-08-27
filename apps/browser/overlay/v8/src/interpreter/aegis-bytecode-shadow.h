// Copyright 2026 GCSA
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef V8_INTERPRETER_AEGIS_BYTECODE_SHADOW_H_
#define V8_INTERPRETER_AEGIS_BYTECODE_SHADOW_H_

#include <cstdint>

#include "src/base/vector.h"
#include "src/handles/handles.h"

namespace v8 {
namespace internal {

class BytecodeArray;

namespace interpreter {

struct AegisBytecodeShadowSummary {
  uint64_t signature = 0;
  int byte_length = 0;
  int opcode_count = 0;
  bool skipped_too_large = false;
};

// Hashes opcode identity only. Operands, constants, source, names, URLs, and
// source positions are deliberately excluded from the signature.
V8_EXPORT_PRIVATE uint64_t
AegisOpcodeSequenceSignature(base::Vector<const uint8_t> opcodes);

V8_EXPORT_PRIVATE AegisBytecodeShadowSummary
SummarizeAegisBytecode(Handle<BytecodeArray> bytecodes, unsigned int max_bytes);

// Default-off, bounded, observe-only diagnostic hook. When its dedicated trace
// category is enabled, it emits numeric metadata without source identity and
// never changes the BytecodeArray or execution result.
void MaybeObserveAegisBytecode(Handle<BytecodeArray> bytecodes);

}  // namespace interpreter
}  // namespace internal
}  // namespace v8

#endif  // V8_INTERPRETER_AEGIS_BYTECODE_SHADOW_H_
