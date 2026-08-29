// Copyright 2026 GCSA

#include "chrome/browser/aegis/agent/agent_monitor_scheduler.h"

#include <algorithm>
#include <utility>

#include "base/strings/string_number_conversions.h"
#include "crypto/sha2.h"

namespace aegis::agent {

std::string AgentMonitorIdempotencyKey(std::string_view task_id,
                                       std::string_view action_id) {
  return "aegis-" + base::HexEncode(crypto::SHA256HashString(
                        std::string(task_id) + "\n" + std::string(action_id)));
}

bool AgentMonitorDefinition::IsValid() const {
  const bool runtime_target_valid =
      target_url.is_empty() ||
      (target_url.is_valid() && target_url.SchemeIsHTTPOrHTTPS() &&
       target_url.username().empty() && target_url.password().empty() &&
       target_url.spec().size() <= 8192u &&
       url::Origin::Create(target_url) == origin);
  return !monitor_id.empty() && monitor_id.size() <= 128u && !task_id.empty() &&
         task_id.size() <= 128u && !origin.opaque() &&
         (origin.scheme() == "http" || origin.scheme() == "https") &&
         !target_hash.empty() && target_hash.size() <= 128u &&
         target_ciphertext.size() <= 16384u && last_value_hash.size() <= 128u &&
         runtime_target_valid && interval >= base::Minutes(15) &&
         interval <= base::Days(7) && consecutive_failures >= 0 &&
         consecutive_failures <= 20;
}

AgentMonitorScheduler::AgentMonitorScheduler() = default;
AgentMonitorScheduler::~AgentMonitorScheduler() = default;

bool AgentMonitorScheduler::Upsert(AgentMonitorDefinition monitor) {
  if (!monitor.IsValid()) {
    return false;
  }
  monitors_.insert_or_assign(monitor.monitor_id, std::move(monitor));
  return true;
}

bool AgentMonitorScheduler::Remove(const std::string& monitor_id) {
  return monitors_.erase(monitor_id) == 1u;
}

void AgentMonitorScheduler::Restore(
    std::vector<AgentMonitorDefinition> monitors,
    base::Time now) {
  monitors_.clear();
  for (AgentMonitorDefinition& monitor : monitors) {
    if (!monitor.IsValid()) {
      continue;
    }
    if (monitor.enabled &&
        (monitor.next_run.is_null() || monitor.next_run < now)) {
      monitor.next_run = now;
    }
    Upsert(std::move(monitor));
  }
}

std::vector<AgentMonitorDefinition> AgentMonitorScheduler::ClaimDue(
    base::Time now) {
  std::vector<AgentMonitorDefinition*> due;
  for (auto& [id, monitor] : monitors_) {
    if (monitor.enabled && !monitor.next_run.is_null() &&
        monitor.next_run <= now) {
      due.push_back(&monitor);
    }
  }
  std::ranges::sort(due, [](const AgentMonitorDefinition* left,
                            const AgentMonitorDefinition* right) {
    if (left->next_run != right->next_run) {
      return left->next_run < right->next_run;
    }
    return left->monitor_id < right->monitor_id;
  });
  if (due.size() > 3u) {
    due.resize(3u);
  }
  std::vector<AgentMonitorDefinition> claimed;
  for (AgentMonitorDefinition* monitor : due) {
    monitor->last_run = now;
    monitor->next_run = now + monitor->interval;
    claimed.push_back(*monitor);
  }
  return claimed;
}

bool AgentMonitorScheduler::MarkFinished(const std::string& monitor_id,
                                         bool success,
                                         base::Time now) {
  auto it = monitors_.find(monitor_id);
  if (it == monitors_.end()) {
    return false;
  }
  AgentMonitorDefinition& monitor = it->second;
  monitor.last_run = now;
  if (success) {
    monitor.consecutive_failures = 0;
    monitor.next_run = now + monitor.interval;
    return true;
  }
  monitor.consecutive_failures = std::min(monitor.consecutive_failures + 1, 20);
  const int exponent = std::min(monitor.consecutive_failures, 6);
  const base::TimeDelta backoff =
      std::min(monitor.interval * (1 << exponent), base::Hours(24));
  monitor.next_run = now + backoff;
  return true;
}

std::vector<AgentMonitorDefinition> AgentMonitorScheduler::Snapshot() const {
  std::vector<AgentMonitorDefinition> result;
  result.reserve(monitors_.size());
  for (const auto& [id, monitor] : monitors_) {
    result.push_back(monitor);
  }
  return result;
}

}  // namespace aegis::agent
