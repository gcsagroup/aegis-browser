// Copyright 2026 GCSA
// Browser-lifetime monitor scheduler. No OS daemon is installed.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SCHEDULER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SCHEDULER_H_

#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/time/time.h"
#include "base/values.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace aegis::agent {

// 返回稳定的操作身份，使持久化后的重放覆盖同一监控，而不是重复产生副作用。
std::string AgentMonitorIdempotencyKey(std::string_view task_id,
                                       std::string_view action_id);

enum class AgentMonitorKind {
  kPrice = 0,
  kInventory = 1,
  kPageChange = 2,
  kUrlStatus = 3,
};

// 只持久化固定状态码，不写入请求地址、服务端正文或凭据。
enum class AgentMonitorCheckStatus {
  kNotChecked = 0,
  kSucceeded = 1,
  kHttpError = 2,
  kLoginRequired = 3,
  kRateLimited = 4,
  kNetworkError = 5,
  kTimeout = 6,
  kRedirectBlocked = 7,
  kTargetUnavailable = 8,
  kPageUnavailable = 9,
  kBudgetExhausted = 10,
  kCheckFailed = 11,
  kContentUnavailable = 12,
  kSecureStorageUnavailable = 13,
  kSummaryUnavailable = 14,
};

struct AgentMonitorDefinition {
  std::string monitor_id;
  std::string task_id;
  AgentMonitorKind kind = AgentMonitorKind::kPageChange;
  url::Origin origin;
  std::string target_hash;
  // The exact URL exists only in memory. Persistence uses OS-encrypted bytes
  // so paths, queries, and fragments never appear as plaintext in the DB.
  GURL target_url;
  std::string target_ciphertext;
  std::string last_value_hash;
  // 历史价格、库存和页面片段只在内存保留明文；数据库仅存系统加密后的字节。
  std::string last_observation;
  std::string last_observation_ciphertext;
  base::TimeDelta interval = base::Minutes(15);
  base::Time next_run;
  base::Time last_run;
  int consecutive_failures = 0;
  bool enabled = true;
  // Session-only monitors keep their exact target in memory and are never
  // written to the task database. This is the safe fallback when OSCrypt is
  // unavailable (for example, an ad-hoc signed development build on macOS).
  bool session_only = false;
  AgentMonitorCheckStatus last_check_status =
      AgentMonitorCheckStatus::kNotChecked;
  int last_http_status = 0;

  bool IsValid() const;
};

// URL 检查通知只依赖固定状态与结果摘要，不包含目标路径或响应正文。
bool ShouldNotifyMonitorUrlResult(const AgentMonitorDefinition& previous,
                                 AgentMonitorCheckStatus next_status,
                                 std::string_view next_value_hash);

// 只从已验证的可见语义节点提取结果；多个不同价格或冲突库存不猜测。
// 返回版本化、有界的数据，供加密保存和下一轮条件比较使用。
std::optional<std::string> ReadAgentMonitorObservation(
    AgentMonitorKind kind,
    const base::ListValue& nodes);
bool IsValidAgentMonitorObservation(AgentMonitorKind kind,
                                    std::string_view observation);
bool DidAgentMonitorConditionMatch(AgentMonitorKind kind,
                                   std::string_view previous,
                                   std::string_view current);

class AgentMonitorScheduler {
 public:
  AgentMonitorScheduler();
  AgentMonitorScheduler(const AgentMonitorScheduler&) = delete;
  AgentMonitorScheduler& operator=(const AgentMonitorScheduler&) = delete;
  ~AgentMonitorScheduler();

  bool Upsert(AgentMonitorDefinition monitor);
  bool Remove(const std::string& monitor_id);
  void Restore(std::vector<AgentMonitorDefinition> monitors, base::Time now);

  // Claims at most three due checks. A missed interval after browser restart is
  // collapsed to one immediate run rather than replayed repeatedly.
  std::vector<AgentMonitorDefinition> ClaimDue(base::Time now);
  bool MarkFinished(
      const std::string& monitor_id,
      bool success,
      base::Time now,
      AgentMonitorCheckStatus status = AgentMonitorCheckStatus::kNotChecked,
      int http_status = 0);
  std::vector<AgentMonitorDefinition> Snapshot() const;

 private:
  std::map<std::string, AgentMonitorDefinition> monitors_;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SCHEDULER_H_
