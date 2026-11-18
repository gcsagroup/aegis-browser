// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_OPTIONS_STORE_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_OPTIONS_STORE_H_

#include "chrome/browser/aegis/access/access_rule_store.h"
#include "components/aegis_access/access_options_capability.h"

namespace aegis::access {
inline constexpr int kAccessOptionsSchemaVersion = 2;
struct AccessOptionsSnapshot {
  uint64_t revision = 0;
  std::string configuration = "{}";
  int schema_version = kAccessOptionsSchemaVersion;
};

// Sequence-bound store. Its owner must schedule disk work off the UI thread.
// Private instances own their own in-memory database and never open disk paths.
class AccessOptionsStore {
 public:
  AccessOptionsStore(aegis_access::AccessBuildIdentity identity,
                     base::FilePath profile_path,
                     std::string profile_id,
                     bool is_private);
  ~AccessOptionsStore();
  StoreStatus Open();
  void SetInterruptBackupForTesting(bool value) { interrupt_backup_ = value; }
  void SetInterruptMigrationForTesting(bool value) { interrupt_migration_ = value; }
  StoreResult<AccessOptionsSnapshot> Read();
  StoreResult<AccessOptionsSnapshot> OpenAndRead();
  StoreStatus Write(uint64_t expected_revision, const std::string& configuration);
  const base::FilePath& database_path() const { return database_path_; }

 private:
  StoreStatus ValidateIdentity();
  StoreStatus MigrateVersionOne();
  bool Admitted(aegis_access::AccessOptionsOperation operation) const;
  aegis_access::AccessBuildIdentity identity_;
  base::FilePath database_path_;
  std::string profile_id_;
  bool private_;
  bool open_ = false;
  bool interrupt_migration_ = false;
  bool interrupt_backup_ = false;
  sql::Database database_;
  SEQUENCE_CHECKER(sequence_checker_);
};
}  // namespace aegis::access
#endif
