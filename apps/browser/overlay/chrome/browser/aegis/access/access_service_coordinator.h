// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SERVICE_COORDINATOR_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SERVICE_COORDINATOR_H_

#include <cstdint>

#include "base/supports_user_data.h"

class Profile;

namespace aegis::access {

// Profile owned coordination point for future product mutations and committed
// policy flows. The coordinator owns the order of state publication: durable
// state is committed first, then generations are captured, then runtime state
// is published.
//
// This first slice intentionally exposes only the lifecycle boundary. Request
// routing continues to consume published snapshots until a product entry point
// is wired here.
class AccessServiceCoordinator : public base::SupportsUserData::Data {
 public:
  static AccessServiceCoordinator* Get(Profile* profile);
  static AccessServiceCoordinator* GetOrCreate(Profile* profile);

  AccessServiceCoordinator(const AccessServiceCoordinator&) = delete;
  AccessServiceCoordinator& operator=(const AccessServiceCoordinator&) = delete;
  ~AccessServiceCoordinator() override;

  uint64_t state_generation() const { return state_generation_; }

 private:
  AccessServiceCoordinator();

  uint64_t state_generation_ = 0;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_SERVICE_COORDINATOR_H_
