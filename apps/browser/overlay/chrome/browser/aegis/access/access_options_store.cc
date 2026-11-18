// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_options_store.h"

#include <limits>
#include "base/files/file_util.h"
#include "base/json/json_reader.h"
#include "base/files/important_file_writer.h"
#include "sql/statement.h"
#include "sql/transaction.h"

namespace aegis::access {
namespace {
constexpr int kVersion = kAccessOptionsSchemaVersion;
constexpr size_t kMaximumConfigurationBytes = 64 * 1024;
bool ValidConfiguration(const std::string& configuration) {
  if (configuration.size() > kMaximumConfigurationBytes)
    return false;
  auto value = base::JSONReader::Read(configuration, base::JSON_PARSE_RFC);
  return value && value->is_dict();
}
}  // namespace

AccessOptionsStore::AccessOptionsStore(aegis_access::AccessBuildIdentity identity,
                                     base::FilePath profile_path,
                                     std::string profile_id,
                                     bool is_private)
    : identity_(identity), profile_id_(std::move(profile_id)),
      private_(is_private), database_("AegisAccess") {
  DETACH_FROM_SEQUENCE(sequence_checker_);
  if (!private_ && !profile_path.empty()) {
    const char* channel = identity.product == aegis_access::AccessProductChannel::kDebug
        ? "debug" : "alpha";
    database_path_ = profile_path.AppendASCII("AccessOptions")
        .AppendASCII(channel).AppendASCII("options.db");
  }
}
AccessOptionsStore::~AccessOptionsStore() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
}
bool AccessOptionsStore::Admitted(aegis_access::AccessOptionsOperation operation) const {
  return aegis_access::CanUseAccessOptions(identity_, operation);
}
StoreStatus AccessOptionsStore::ValidateIdentity() {
  sql::Statement statement(database_.GetUniqueStatement(
      "SELECT version,channel,profile_id FROM identity WHERE singleton=1"));
  if (!statement.Step())
    return StoreStatus::kCorrupt;
  if (statement.ColumnInt(1) != static_cast<int>(identity_.channel) ||
      statement.ColumnString(2) != profile_id_)
    return StoreStatus::kConflict;
  if (statement.ColumnInt(0) != kVersion)
    return StoreStatus::kIncompatible;
  return StoreStatus::kValid;
}
StoreStatus AccessOptionsStore::MigrateVersionOne() {
  const auto directory = database_path_.DirName();
  const auto backup = directory.AppendASCII("options.v1.db");
  const auto backup_staging = directory.AppendASCII("options.backup-staging.db");
  const auto temporary = directory.AppendASCII("options.migrating.db");
  const auto marker = directory.AppendASCII("migration.pending");
  if (base::PathExists(marker)) {
    std::string state;
    if (!base::ReadFileToString(marker, &state) || state != "1->2")
      return StoreStatus::kRecoveryRequired;
  }
  sql::Statement version(database_.GetUniqueStatement(
      "SELECT version FROM identity WHERE singleton=1"));
  if (!version.Step() || version.ColumnInt(0) != 1)
    return StoreStatus::kIncompatible;
  version.Clear();
  sql::Statement contents(database_.GetUniqueStatement(
      "SELECT revision,payload FROM configuration WHERE singleton=1"));
  if (!contents.Step() || contents.ColumnInt64(0) < 0 ||
      !ValidConfiguration(contents.ColumnString(1)))
    return StoreStatus::kCorrupt;
  const auto revision = contents.ColumnInt64(0);
  const auto payload = contents.ColumnString(1);
  contents.Clear();
  auto validate_backup = [&](const base::FilePath& path) {
    sql::Database original("AegisAccess");
    if (!original.Open(path) || !original.DoesTableExist("identity") ||
        !original.DoesTableExist("configuration"))
      return StoreStatus::kRecoveryRequired;
    sql::Statement check(original.GetUniqueStatement(
        "SELECT i.version,i.channel,i.profile_id,c.revision,c.payload "
        "FROM identity i,configuration c WHERE i.singleton=1 AND c.singleton=1"));
    if (!check.Step() || check.ColumnInt(0) != 1 ||
        check.ColumnInt(1) != static_cast<int>(identity_.channel) ||
        check.ColumnString(2) != profile_id_ || check.ColumnInt64(3) != revision ||
        check.ColumnString(4) != payload)
      return StoreStatus::kConflict;
    return StoreStatus::kValid;
  };
  if (base::PathExists(backup)) {
    const auto status = validate_backup(backup);
    if (status != StoreStatus::kValid)
      return status;
  } else {
    // A crashed VACUUM may leave an incomplete destination. Only the staged
    // name can be discarded; a published recovery source is never overwritten.
    if (base::PathExists(backup_staging) && !base::DeleteFile(backup_staging))
      return StoreStatus::kIoError;
    if (interrupt_backup_) {
      if (!base::WriteFile(backup_staging, "interrupted-vacuum"))
        return StoreStatus::kIoError;
      return StoreStatus::kRecoveryRequired;
    }
    {
      sql::Statement copy(database_.GetUniqueStatement("VACUUM INTO ?"));
      copy.BindString(0, backup_staging.AsUTF8Unsafe());
      if (!copy.Run())
        return StoreStatus::kIoError;
    }
    if (validate_backup(backup_staging) != StoreStatus::kValid ||
        !base::ReplaceFile(backup_staging, backup, nullptr))
      return StoreStatus::kRecoveryRequired;
  }
  // The original remains intact at both paths until the upgraded temporary
  // database has committed and the durable recovery marker has been written.
  if (base::PathExists(temporary) && !base::DeleteFile(temporary))
    return StoreStatus::kIoError;
  {
    sql::Statement copy(database_.GetUniqueStatement("VACUUM INTO ?"));
    copy.BindString(0, temporary.AsUTF8Unsafe());
    if (!copy.Run())
      return StoreStatus::kIoError;
  }
  {
    sql::Database upgraded("AegisAccess");
    if (!upgraded.Open(temporary))
      return StoreStatus::kIoError;
    sql::Transaction transaction(&upgraded);
    if (!transaction.Begin() ||
        !upgraded.Execute("UPDATE identity SET version=2 WHERE singleton=1 AND version=1") ||
        !transaction.Commit())
      return StoreStatus::kIoError;
  }
  if (!base::ImportantFileWriter::WriteFileAtomically(marker, "1->2"))
    return StoreStatus::kIoError;
  if (interrupt_migration_)
    return StoreStatus::kRecoveryRequired;
  database_.Close();
  if (!base::ReplaceFile(temporary, database_path_, nullptr) ||
      !database_.Open(database_path_))
    return StoreStatus::kRecoveryRequired;
  const auto status = ValidateIdentity();
  if (status != StoreStatus::kValid || !base::DeleteFile(marker))
    return StoreStatus::kRecoveryRequired;
  return StoreStatus::kValid;
}
StoreStatus AccessOptionsStore::Open() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!Admitted(aegis_access::AccessOptionsOperation::kRead))
    return StoreStatus::kConflict;
  if (profile_id_.empty() || profile_id_.size() > 256 ||
      (!private_ && (!database_path_.IsAbsolute() || database_path_.ReferencesParent())))
    return StoreStatus::kInvalidArgument;
  if (!private_ && !base::CreateDirectory(database_path_.DirName()))
    return StoreStatus::kIoError;
  if (open_)
    return StoreStatus::kValid;
  if (database_.is_open())
    database_.Close();
  const bool existed = !private_ && base::PathExists(database_path_);
  if (!private_ && !existed) {
    const auto directory = database_path_.DirName();
    if (base::PathExists(directory.AppendASCII("migration.pending")) ||
        base::PathExists(directory.AppendASCII("options.v1.db")) ||
        base::PathExists(directory.AppendASCII("options.backup-staging.db")) ||
        base::PathExists(directory.AppendASCII("options.migrating.db")))
      return StoreStatus::kRecoveryRequired;
  }
  if (!(private_ ? database_.OpenInMemory() : database_.Open(database_path_)))
    return StoreStatus::kIoError;
  if (!database_.DoesTableExist("identity")) {
    if (existed) {
      database_.Close();
      return StoreStatus::kCorrupt;
    }
    sql::Transaction transaction(&database_);
    if (!transaction.Begin() ||
        !database_.Execute("CREATE TABLE identity(singleton INTEGER PRIMARY KEY CHECK(singleton=1),version INTEGER NOT NULL,channel INTEGER NOT NULL,profile_id TEXT NOT NULL)") ||
        !database_.Execute("CREATE TABLE configuration(singleton INTEGER PRIMARY KEY CHECK(singleton=1),revision INTEGER NOT NULL,payload TEXT NOT NULL)")) {
      return StoreStatus::kIoError;
    }
    sql::Statement insert(database_.GetUniqueStatement(
        "INSERT INTO identity VALUES(1,?,?,?)"));
    insert.BindInt(0, kVersion);
    insert.BindInt(1, static_cast<int>(identity_.channel));
    insert.BindString(2, profile_id_);
    if (!insert.Run() || !database_.Execute("INSERT INTO configuration VALUES(1,0,'{}')") ||
        !transaction.Commit()) {
      return StoreStatus::kIoError;
    }
  }
  auto status = ValidateIdentity();
  if (status == StoreStatus::kIncompatible && !private_)
    status = MigrateVersionOne();
  if (status == StoreStatus::kValid && !private_) {
    const auto marker = database_path_.DirName().AppendASCII("migration.pending");
    if (base::PathExists(marker)) {
      std::string state;
      if (!base::ReadFileToString(marker, &state) || state != "1->2" ||
          !base::DeleteFile(marker))
        status = StoreStatus::kRecoveryRequired;
    }
  }
  open_ = status == StoreStatus::kValid;
  if (!open_)
    database_.Close();
  return status;
}
StoreResult<AccessOptionsSnapshot> AccessOptionsStore::OpenAndRead() {
  const auto status = Open();
  if (status != StoreStatus::kValid)
    return {status, std::nullopt, "options_open_failed"};
  return Read();
}
StoreResult<AccessOptionsSnapshot> AccessOptionsStore::Read() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!open_ || !Admitted(aegis_access::AccessOptionsOperation::kRead))
    return {StoreStatus::kConflict, std::nullopt, "options_not_available"};
  sql::Statement configuration(database_.GetUniqueStatement(
      "SELECT revision,payload FROM configuration WHERE singleton=1"));
  if (!configuration.Step() || configuration.ColumnInt64(0) < 0 || !ValidConfiguration(configuration.ColumnString(1)))
    return {StoreStatus::kCorrupt, std::nullopt, "invalid_configuration"};
  return {StoreStatus::kValid,
          AccessOptionsSnapshot{static_cast<uint64_t>(configuration.ColumnInt64(0)), configuration.ColumnString(1)}, {}};
}
StoreStatus AccessOptionsStore::Write(uint64_t expected_revision,
                                     const std::string& configuration) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!open_ || !Admitted(aegis_access::AccessOptionsOperation::kWrite))
    return StoreStatus::kConflict;
  if (expected_revision >= static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
      !ValidConfiguration(configuration))
    return StoreStatus::kInvalidArgument;
  sql::Transaction transaction(&database_);
  if (!transaction.Begin())
    return StoreStatus::kIoError;
  auto current = Read();
  if (current.status != StoreStatus::kValid || current.value->revision != expected_revision)
    return StoreStatus::kConflict;
  sql::Statement update(database_.GetUniqueStatement(
      "UPDATE configuration SET revision=?,payload=? WHERE singleton=1 AND revision=?"));
  update.BindInt64(0, expected_revision + 1);
  update.BindString(1, configuration);
  update.BindInt64(2, expected_revision);
  if (!update.Run() || !transaction.Commit())
    return StoreStatus::kIoError;
  return StoreStatus::kValid;
}
}  // namespace aegis::access
