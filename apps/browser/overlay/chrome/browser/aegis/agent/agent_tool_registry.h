// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_TOOL_REGISTRY_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_TOOL_REGISTRY_H_

#include <optional>
#include <string_view>
#include <vector>

#include "chrome/browser/aegis/agent/agent_model_protocol.h"
#include "chrome/browser/aegis/agent/agent_types.h"

namespace aegis::agent {

struct AgentToolDescriptor {
  std::string_view name;
  AgentRiskLevel risk;
  AgentDataClass data_class;
  bool requires_origin;
  bool requires_document;
  bool has_external_side_effect;
  bool supports_undo;
};

class AgentToolRegistry {
 public:
  AgentToolRegistry();
  AgentToolRegistry(const AgentToolRegistry&) = delete;
  AgentToolRegistry& operator=(const AgentToolRegistry&) = delete;
  ~AgentToolRegistry();

  const AgentToolDescriptor* Find(std::string_view name) const;
  std::vector<std::string_view> Names() const;
  std::optional<AgentModelToolDefinition> ModelToolForName(
      std::string_view name) const;
  std::vector<AgentModelToolDefinition> ModelToolsForScope(
      const AgentTaskScope& scope) const;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_TOOL_REGISTRY_H_
