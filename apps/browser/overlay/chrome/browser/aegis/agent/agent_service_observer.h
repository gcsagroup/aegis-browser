// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_AGENT_AGENT_SERVICE_OBSERVER_H_
#define CHROME_BROWSER_AEGIS_AGENT_AGENT_SERVICE_OBSERVER_H_

#include "base/observer_list_types.h"

namespace aegis::agent {

class AegisAgentServiceObserver : public base::CheckedObserver {
 public:
  ~AegisAgentServiceObserver() override = default;
  virtual void OnAgentServiceSnapshotChanged() = 0;
};

}  // namespace aegis::agent

#endif  // CHROME_BROWSER_AEGIS_AGENT_AGENT_SERVICE_OBSERVER_H_
