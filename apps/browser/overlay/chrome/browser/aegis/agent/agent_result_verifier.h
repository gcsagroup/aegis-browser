// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_RESULT_VERIFIER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_RESULT_VERIFIER_H_

#include <string>

#include "chrome/browser/aegis/agent/agent_task.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"

namespace aegis::agent {

struct AgentVerificationDecision {
  bool accepted = false;
  bool postcondition_met = false;
  AgentErrorCode error = AgentErrorCode::kVerificationFailed;
  std::string reason;
};

// Validates browser-produced results before they enter the idempotency table or
// are returned to a model. It never accepts model prose as execution evidence.
class AgentResultVerifier {
 public:
  AgentResultVerifier();
  AgentResultVerifier(const AgentResultVerifier&) = delete;
  AgentResultVerifier& operator=(const AgentResultVerifier&) = delete;
  ~AgentResultVerifier();

  AgentVerificationDecision Verify(const AgentTask& task,
                                   const AgentToolCall& call,
                                   const AgentToolDescriptor& descriptor,
                                   const AgentToolResult& result) const;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_RESULT_VERIFIER_H_
