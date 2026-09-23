// Copyright 2026 GCSA
// Core contracts for Aegis Browser Agent tasks and tool calls.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_TYPES_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_TYPES_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>
#include "chrome/browser/aegis/agent/agent_generation_profile.h"
#include "chrome/browser/aegis/agent/agent_model_accounting.h"

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

// The selection policy is browser-owned. TypeSafe may classify a task's
// requirements, but it never chooses a provider, endpoint, or model.
enum class AgentModelSelectionMode {
  kFixed = 0,
  kBalanced = 1,
  kQuality = 2,
  kCost = 3,
  kLocalOnly = 4,
};

struct AgentTaskScope {
  std::vector<url::Origin> allowed_origins;
  base::flat_set<int32_t> allowed_tab_ids;
  // 浏览器绑定的当前窗口，只允许 tab.list 读取元数据，不授予标签操作权限。
  int32_t tab_metadata_window_id = 0;
  base::flat_set<std::string> allowed_tools;
  base::flat_set<AgentDataClass> allowed_data_classes;
  AgentBudgets budgets;
  // `model_destination` remains the primary destination for backwards
  // compatibility with persisted tasks. A fallback is authorized with the
  // task up front and may be removed by scope narrowing, but never added or
  // replaced by a model-produced plan.
  AgentModelDestination model_destination;
  std::optional<AgentModelDestination> model_fallback_destination;
  AgentModelSelectionMode model_selection_mode =
      AgentModelSelectionMode::kFixed;
  int model_catalog_revision = 0;
  AgentGenerationProfile model_generation_profile;
  AgentGenerationProfile fallback_generation_profile;
  AgentTokenPrices model_token_prices;
  AgentTokenPrices fallback_token_prices;

  bool IsValid() const;
  bool AllowsOrigin(const GURL& url) const;
  bool AllowsTab(int32_t tab_id) const;
  bool AllowsTool(const std::string& tool_name) const;
  bool AllowsDataClass(AgentDataClass data_class) const;
  bool IsNoBroaderThan(const AgentTaskScope& other) const;
};

// Bounded, redacted per-task routing evidence. It never stores the goal,
// prompts, page/URL data, responses, or credentials.
struct AgentModelRoutingMetrics {
  bool typesafe_attempted = false;
  bool typesafe_qualified = false;
  std::string typesafe_outcome;
  std::string typesafe_model;
  std::string typesafe_decisions;
  int typesafe_input_tokens = 0;
  int typesafe_output_tokens = 0;
  int64_t typesafe_latency_ms = 0;
  bool fallback_used = false;
  std::optional<int64_t> primary_model_cost_microusd_per_million_tokens;
  std::optional<int64_t> fallback_model_cost_microusd_per_million_tokens;
  int64_t model_input_tokens = 0;
  int64_t model_output_tokens = 0;
  int64_t model_latency_ms = 0;
  std::vector<AgentModelAttempt> attempts;
  bool attempts_complete = false;

  bool IsValid() const;
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
