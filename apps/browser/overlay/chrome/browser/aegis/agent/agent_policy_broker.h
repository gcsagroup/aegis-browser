// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_POLICY_BROKER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_POLICY_BROKER_H_

#include <map>
#include <optional>
#include <string>

#include "base/time/time.h"
#include "chrome/browser/aegis/agent/agent_task.h"
#include "chrome/browser/aegis/agent/agent_tool_registry.h"

namespace aegis::agent {

enum class AgentPolicyDisposition {
  kAllow = 0,
  kRequireTaskConsent = 1,
  kRequireActionApproval = 2,
  kRequireUserTakeover = 3,
  kDeny = 4,
};

struct AgentPolicyDecision {
  AgentPolicyDisposition disposition = AgentPolicyDisposition::kDeny;
  AgentRiskLevel risk = AgentRiskLevel::kBlocked;
  AgentErrorCode error = AgentErrorCode::kScopeViolation;
  std::string reason;
};

struct AgentApprovalReceipt {
  std::string approval_id;
  std::string task_id;
  std::string action_hash;
  base::Time expires_at;
  int uses_remaining = 1;
};

class AgentPolicyBroker {
 public:
  explicit AgentPolicyBroker(const AgentToolRegistry* registry);
  AgentPolicyBroker(const AgentPolicyBroker&) = delete;
  AgentPolicyBroker& operator=(const AgentPolicyBroker&) = delete;
  ~AgentPolicyBroker();

  AgentPolicyDecision Evaluate(
      const AgentTask& task,
      const AgentToolCall& call,
      const std::optional<std::string>& approval_id = std::nullopt,
      base::Time now = base::Time::Now());

  std::optional<AgentApprovalReceipt> IssueApproval(
      const AgentTask& task,
      const AgentToolCall& call,
      base::TimeDelta ttl = base::Minutes(2),
      int uses = 1,
      base::Time now = base::Time::Now());

  void RevokeTaskApprovals(const std::string& task_id);
  // Stable fingerprint shown to the user and consumed by the one-use approval
  // receipt. It covers the exact action, arguments, origin, and document.
  static std::string ActionHash(const AgentToolCall& call);
  size_t approval_count_for_testing() const { return approvals_.size(); }

 private:
  static bool HasTaskConsent(const AgentTask& task);
  bool ConsumeApproval(const AgentTask& task,
                       const AgentToolCall& call,
                       const std::string& approval_id,
                       base::Time now);

  const raw_ptr<const AgentToolRegistry> registry_;
  std::map<std::string, AgentApprovalReceipt> approvals_;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_POLICY_BROKER_H_
