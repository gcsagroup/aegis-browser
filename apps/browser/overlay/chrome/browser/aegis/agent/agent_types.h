// Copyright 2026 GCSA
// Core contracts for Aegis Browser Agent tasks and tool calls.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_TYPES_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_TYPES_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/containers/flat_set.h"
#include "base/time/time.h"
#include "base/values.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {

inline constexpr int kAgentSchemaVersion = 1;

enum class AgentMode {
  kAsk = 0,
  kAct = 1,
  kAutomate = 2,
};

enum class AgentTaskState {
  kDraft = 0,
  kPlanning = 1,
  kAwaitingTaskConsent = 2,
  kRunning = 3,
  kReflecting = 4,
  kAwaitingActionApproval = 5,
  kPausedByUser = 6,
  kUserTakeover = 7,
  kRecovering = 8,
  kVerifying = 9,
  kCompleted = 10,
  kFailed = 11,
  kCancelled = 12,
  kExpired = 13,
};

enum class AgentRiskLevel {
  kR0ReadOnly = 0,
  kR1Reversible = 1,
  kR2ExternalSideEffect = 2,
  kR3UserTakeover = 3,
  kBlocked = 4,
};

enum class AgentDataClass {
  kPublicPage = 0,
  kBrowserMetadata = 1,
  kBookmarks = 2,
  kHistory = 3,
  kDownloads = 4,
  kFormData = 5,
  kSecret = 6,
};

enum class AgentErrorCode {
  kNone = 0,
  kInvalidRequest = 1,
  kScopeViolation = 2,
  kApprovalRequired = 3,
  kStaleDocument = 4,
  kBudgetExhausted = 5,
  kToolUnavailable = 6,
  kVerificationFailed = 7,
  kCancelled = 8,
  kInternal = 9,
};

struct AgentBudgets {
  int max_tabs = 8;
  int max_tool_calls = 50;
  int max_model_calls = 20;
  int max_network_requests = 100;
  base::TimeDelta max_duration = base::Minutes(30);

  bool IsValid() const;
  bool IsNoBroaderThan(const AgentBudgets& other) const;
};

struct AgentModelDestination {
  enum class Kind {
    kOnDevice = 0,
    kLoopback = 1,
    kCloud = 2,
  };

  Kind kind = Kind::kOnDevice;
  std::string provider;
  std::string endpoint;
  std::string model;

  bool IsValid() const;
  bool operator==(const AgentModelDestination&) const = default;
};

struct AgentTaskScope {
  std::vector<url::Origin> allowed_origins;
  base::flat_set<int32_t> allowed_tab_ids;
  base::flat_set<std::string> allowed_tools;
  base::flat_set<AgentDataClass> allowed_data_classes;
  AgentBudgets budgets;
  AgentModelDestination model_destination;

  bool IsValid() const;
  bool AllowsOrigin(const GURL& url) const;
  bool AllowsTab(int32_t tab_id) const;
  bool AllowsTool(const std::string& tool_name) const;
  bool AllowsDataClass(AgentDataClass data_class) const;
  bool IsNoBroaderThan(const AgentTaskScope& other) const;
};

struct AgentDocumentRef {
  int32_t tab_id = 0;
  std::string frame_token;
  std::string document_token;
  GURL committed_url;

  bool IsValid() const;
};

struct AgentToolCall {
  int schema_version = kAgentSchemaVersion;
  std::string action_id;
  std::string tool_name;
  base::DictValue arguments;
  GURL committed_url;
  std::optional<AgentDocumentRef> document;
};

struct AgentToolResult {
  int schema_version = kAgentSchemaVersion;
  std::string action_id;
  bool ok = false;
  AgentErrorCode error = AgentErrorCode::kNone;
  std::string message;
  base::DictValue value;
  base::ListValue evidence;
};

bool IsTerminalState(AgentTaskState state);
const char* AgentTaskStateToString(AgentTaskState state);

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_TYPES_H_
