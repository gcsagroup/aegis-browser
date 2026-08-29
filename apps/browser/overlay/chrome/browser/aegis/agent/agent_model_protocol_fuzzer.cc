// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_model_protocol.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/strings/string_view_util.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"
#include "testing/libfuzzer/libfuzzer_base_wrappers.h"

namespace aegis::agent {
namespace {

std::vector<AgentModelToolDefinition> AllModelTools() {
  AgentToolRegistry registry;
  std::vector<AgentModelToolDefinition> tools;
  for (std::string_view name : registry.Names()) {
    std::optional<AgentModelToolDefinition> tool =
        registry.ModelToolForName(name);
    if (tool) {
      tools.push_back(std::move(*tool));
    }
  }
  return tools;
}

}  // namespace

DEFINE_LLVM_FUZZER_TEST_ONE_INPUT_SPAN(base::span<const uint8_t> data) {
  constexpr size_t kMaxInputBytes = 256 * 1024;
  if (data.empty() || data.size() > kMaxInputBytes) {
    return 0;
  }
  static const std::vector<AgentModelToolDefinition> kTools = AllModelTools();
  const AgentModelProvider provider =
      static_cast<AgentModelProvider>(data.front() % 3);
  const std::string body(base::as_string_view(data.subspan(1u)));
  ParseAgentModelResponse(provider, body, /*is_stream=*/false, kTools);
  ParseAgentModelResponse(provider, body, /*is_stream=*/true, kTools);
  return 0;
}

}  // namespace aegis::agent
