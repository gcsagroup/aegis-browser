// Copyright 2026 GCSA

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>

#include "base/containers/span.h"
#include "base/strings/string_view_util.h"
#include "chrome/browser/aegis/agent/agent_task_store.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"
#include "testing/libfuzzer/libfuzzer_base_wrappers.h"

namespace aegis::agent {

DEFINE_LLVM_FUZZER_TEST_ONE_INPUT_SPAN(base::span<const uint8_t> data) {
  constexpr size_t kMaxInputBytes = 128 * 1024;
  if (data.empty() || data.size() > kMaxInputBytes) {
    return 0;
  }
  const std::string input(base::as_string_view(data));
  std::optional<AgentTaskScope> scope = AgentTaskStore::DeserializeScope(input);
  if (scope) {
    AgentToolRegistry registry;
    registry.ModelToolsForScope(*scope);
  }
  return 0;
}

}  // namespace aegis::agent
