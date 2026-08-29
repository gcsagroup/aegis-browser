// Copyright 2026 GCSA

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/containers/span.h"
#include "base/json/json_reader.h"
#include "base/strings/string_view_util.h"
#include "chrome/browser/aegis/agent/agent_model_protocol.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"
#include "testing/libfuzzer/libfuzzer_base_wrappers.h"

namespace aegis::agent {

DEFINE_LLVM_FUZZER_TEST_ONE_INPUT_SPAN(base::span<const uint8_t> data) {
  constexpr size_t kMaxInputBytes = 128 * 1024;
  if (data.size() < 2 || data.size() > kMaxInputBytes) {
    return 0;
  }
  AgentToolRegistry registry;
  const std::vector<std::string_view> names = registry.Names();
  if (names.empty()) {
    return 0;
  }
  std::optional<AgentModelToolDefinition> tool =
      registry.ModelToolForName(names[data.front() % names.size()]);
  std::optional<base::Value> value = base::JSONReader::Read(
      base::as_string_view(data.subspan(1u)), base::JSON_PARSE_RFC);
  if (!tool || !value || !value->is_dict()) {
    return 0;
  }
  std::string error;
  ValidateAgentToolArguments(*tool, value->GetDict(), &error);
  return 0;
}

}  // namespace aegis::agent
