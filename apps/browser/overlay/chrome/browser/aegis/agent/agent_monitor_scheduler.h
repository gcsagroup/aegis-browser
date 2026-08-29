// Copyright 2026 GCSA
// Browser-lifetime monitor scheduler. No OS daemon is installed.

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SCHEDULER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SCHEDULER_H_

#include <map>
#include <string>
#include <string_view>
#include <vector>

#include "base/time/time.h"
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
  base::TimeDelta interval = base::Minutes(15);
  base::Time next_run;
  base::Time last_run;
  int consecutive_failures = 0;
  bool enabled = true;

  bool IsValid() const;
};

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
  bool MarkFinished(const std::string& monitor_id,
                    bool success,
                    base::Time now);
  std::vector<AgentMonitorDefinition> Snapshot() const;

 private:
  std::map<std::string, AgentMonitorDefinition> monitors_;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_MONITOR_SCHEDULER_H_
