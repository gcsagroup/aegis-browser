// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_rule_store.h"

#include <algorithm>
#include <cctype>
#include <limits>
#include <set>
#include <string_view>
#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/time/time.h"
#include "net/base/schemeful_site.h"
#include "sql/statement.h"
#include "sql/transaction.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

constexpr int kSchemaVersion = 1;
constexpr int kCompatibleVersion = 1;
constexpr int kPrepared = 0;
constexpr int kCommitted = 1;
constexpr int kSuperseded = 2;
constexpr int kCompleteSchemeMask = 0x0f;
constexpr size_t kMaxIdBytes = 256;
constexpr size_t kMaxSiteBytes = 512;
constexpr size_t kMaxMutationJournalRows = 128;
constexpr base::TimeDelta kMutationRetention = base::Days(7);

constexpr char kCreateIdentitySql[] = R"sql(
  CREATE TABLE access_store_identity(
    singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton=1),
    schema_version INTEGER NOT NULL,
    channel INTEGER NOT NULL,
    durable_profile_id TEXT NOT NULL,
    profile_path TEXT NOT NULL
  ))sql";

constexpr char kCreateCountersSql[] = R"sql(
  CREATE TABLE access_store_counters(
    singleton INTEGER PRIMARY KEY NOT NULL CHECK(singleton=1),
    operation_sequence INTEGER NOT NULL
  ))sql";

constexpr char kCreateGroupsSql[] = R"sql(
  CREATE TABLE access_site_groups(
    channel INTEGER NOT NULL,
    durable_profile_id TEXT NOT NULL,
    storage_partition_token TEXT NOT NULL,
    site_toggle_id TEXT NOT NULL,
    canonical_host TEXT NOT NULL,
    http_top_level_site TEXT NOT NULL,
    https_top_level_site TEXT NOT NULL,
    http_member_rule_id TEXT NOT NULL,
    https_member_rule_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    last_operation_sequence INTEGER NOT NULL,
    committed_policy_generation INTEGER NOT NULL,
    PRIMARY KEY(storage_partition_token, site_toggle_id),
    UNIQUE(storage_partition_token, canonical_host)
  ))sql";

constexpr char kCreateRulesSql[] = R"sql(
  CREATE TABLE access_rules(
    channel INTEGER NOT NULL,
    durable_profile_id TEXT NOT NULL,
    storage_partition_token TEXT NOT NULL,
    rule_id TEXT NOT NULL,
    site_toggle_id TEXT NOT NULL,
    site_toggle_revision INTEGER NOT NULL,
    scope INTEGER NOT NULL,
    top_level_site TEXT NOT NULL,
    destination_host TEXT NOT NULL,
    include_subdomains INTEGER NOT NULL,
    schemes_mask INTEGER NOT NULL,
    port_scope INTEGER NOT NULL,
    explicit_ports TEXT NOT NULL,
    mode INTEGER NOT NULL,
    proxy_group_id TEXT NOT NULL,
    protection_override INTEGER NOT NULL,
    source INTEGER NOT NULL,
    lifetime INTEGER NOT NULL,
    expires_at_micros INTEGER NOT NULL,
    created_by_batch_id TEXT NOT NULL,
    row_revision INTEGER NOT NULL,
    last_operation_sequence INTEGER NOT NULL,
    PRIMARY KEY(storage_partition_token, rule_id)
  ))sql";

constexpr char kCreateJournalSql[] = R"sql(
  CREATE TABLE access_mutation_journal(
    operation_id TEXT PRIMARY KEY NOT NULL,
    request_fingerprint TEXT NOT NULL,
    state INTEGER NOT NULL,
    schema_version INTEGER NOT NULL,
    channel INTEGER NOT NULL,
    durable_profile_id TEXT NOT NULL,
    profile_path TEXT NOT NULL,
    storage_partition_token TEXT NOT NULL,
    site_toggle_id TEXT NOT NULL,
    canonical_host TEXT NOT NULL,
    http_top_level_site TEXT NOT NULL,
    https_top_level_site TEXT NOT NULL,
    http_member_rule_id TEXT NOT NULL,
    https_member_rule_id TEXT NOT NULL,
    target_mode INTEGER NOT NULL,
    proxy_group_id TEXT NOT NULL,
    expected_revision INTEGER NOT NULL,
    target_revision INTEGER NOT NULL,
    operation_sequence INTEGER NOT NULL,
    committed_policy_generation INTEGER NOT NULL,
    created_at_micros INTEGER NOT NULL,
    completed_at_micros INTEGER NOT NULL,
    before_image TEXT NOT NULL,
    after_image TEXT NOT NULL
  ))sql";

bool IsKnownChannel(ChannelNamespace channel) {
  switch (channel) {
    case ChannelNamespace::kDev:
    case ChannelNamespace::kAlpha:
    case ChannelNamespace::kBeta:
    case ChannelNamespace::kRelease:
      return true;
    case ChannelNamespace::kInvalid:
      return false;
  }
  return false;
}

bool FitsSqlInt64(uint64_t value) {
  return value <= static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
}

bool Bounded(std::string_view value, size_t maximum = kMaxIdBytes) {
  return !value.empty() && value.size() <= maximum;
}

bool IsCanonicalHostLike(std::string_view host) {
  if (!Bounded(host, 253) || host.back() == '.') {
    return false;
  }
  const bool bracketed_ipv6 = host.front() == '[' && host.back() == ']';
  for (unsigned char character : host) {
    if (character >= 0x80 || std::isspace(character) ||
        std::isupper(character) || character == '/' || character == '\\' ||
        character == '@' || character == '?' || character == '#' ||
        character == '%') {
      return false;
    }
    if (character == ':' && !bracketed_ipv6) {
      return false;
    }
  }
  return true;
}

bool IsSchemefulSiteLike(std::string_view value, std::string_view scheme) {
  return Bounded(value, kMaxSiteBytes) && value.starts_with(scheme) &&
         IsCanonicalHostLike(value.substr(scheme.size()));
}

OwnershipKey OwnerFor(const AccessStoreBinding& binding,
                      const std::string& partition) {
  return {binding.channel(), binding.runtime_profile_token(), partition};
}

bool IsCompleteOwner(const OwnershipKey& owner) {
  return IsKnownChannel(owner.channel) && Bounded(owner.profile_token) &&
         Bounded(owner.storage_partition_token);
}

std::optional<std::pair<std::string, std::string>> CanonicalSitesForHost(
    std::string_view canonical_host) {
  GURL::Replacements replacements;
  replacements.SetHostStr(canonical_host);
  const GURL http_url =
      GURL("http://site.invalid/").ReplaceComponents(replacements);
  const GURL https_url =
      GURL("https://site.invalid/").ReplaceComponents(replacements);
  if (!http_url.is_valid() || !https_url.is_valid() ||
      http_url.host() != canonical_host || https_url.host() != canonical_host) {
    return std::nullopt;
  }
  const net::SchemefulSite http_site(http_url);
  const net::SchemefulSite https_site(https_url);
  if (http_site.opaque() || https_site.opaque()) {
    return std::nullopt;
  }
  return std::pair(http_site.Serialize(), https_site.Serialize());
}

aegis_access::GroupValidation ValidateBoundSiteGroup(
    const OwnershipKey& expected_owner,
    const SiteProxyRuleGroup* group,
    const std::vector<SiteProxyRuleMember>& members) {
  aegis_access::GroupValidation validation =
      ValidateSiteProxyRuleGroup(expected_owner, group, members);
  if (validation.error != GroupValidationError::kNone) {
    return validation;
  }
  const auto expected_sites = CanonicalSitesForHost(group->canonical_host);
  if (!expected_sites.has_value() ||
      group->http_top_level_site != expected_sites->first ||
      group->https_top_level_site != expected_sites->second) {
    validation.selection = aegis_access::GroupSelection::kUnknown;
    validation.error = GroupValidationError::kTopLevelSiteMismatch;
    return validation;
  }
  for (const SiteProxyRuleMember& member : members) {
    const std::string& expected_site =
        member.rule_id == group->member_rule_ids[0] ? expected_sites->first
                                                    : expected_sites->second;
    if (member.top_level_site != expected_site) {
      validation.selection = aegis_access::GroupSelection::kUnknown;
      validation.error = GroupValidationError::kTopLevelSiteMismatch;
      return validation;
    }
  }
  return validation;
}

int SchemeMask(const std::vector<RequestScheme>& schemes) {
  int mask = 0;
  for (RequestScheme scheme : schemes) {
    int bit = 0;
    switch (scheme) {
      case RequestScheme::kHttp:
        bit = 1 << 0;
        break;
      case RequestScheme::kHttps:
        bit = 1 << 1;
        break;
      case RequestScheme::kWs:
        bit = 1 << 2;
        break;
      case RequestScheme::kWss:
        bit = 1 << 3;
        break;
      case RequestScheme::kInvalid:
        return 0;
    }
    if ((mask & bit) != 0) {
      return 0;
    }
    mask |= bit;
  }
  return mask;
}

std::vector<RequestScheme> SchemesFromMask(int mask) {
  std::vector<RequestScheme> result;
  if ((mask & (1 << 0)) != 0) {
    result.push_back(RequestScheme::kHttp);
  }
  if ((mask & (1 << 1)) != 0) {
    result.push_back(RequestScheme::kHttps);
  }
  if ((mask & (1 << 2)) != 0) {
    result.push_back(RequestScheme::kWs);
  }
  if ((mask & (1 << 3)) != 0) {
    result.push_back(RequestScheme::kWss);
  }
  return result;
}

std::string SerializePorts(const std::vector<uint16_t>& ports) {
  std::string result;
  for (uint16_t port : ports) {
    if (!result.empty()) {
      result.push_back(',');
    }
    result.append(std::to_string(port));
  }
  return result;
}

std::optional<std::vector<uint16_t>> ParsePorts(std::string_view value) {
  std::vector<uint16_t> ports;
  if (value.empty()) {
    return ports;
  }
  size_t begin = 0;
  while (begin < value.size()) {
    const size_t end = value.find(',', begin);
    const std::string_view field =
        value.substr(begin, end == std::string_view::npos ? value.size() - begin
                                                          : end - begin);
    if (field.empty() || field.size() > 5) {
      return std::nullopt;
    }
    uint32_t parsed = 0;
    for (char c : field) {
      if (c < '0' || c > '9') {
        return std::nullopt;
      }
      parsed = parsed * 10 + static_cast<uint32_t>(c - '0');
    }
    if (parsed == 0 || parsed > 65535 ||
        (!ports.empty() && ports.back() >= parsed)) {
      return std::nullopt;
    }
    ports.push_back(static_cast<uint16_t>(parsed));
    if (end == std::string_view::npos) {
      break;
    }
    begin = end + 1;
  }
  return ports;
}

bool KnownSource(StoredRuleSource source) {
  return source == StoredRuleSource::kUserAction ||
         source == StoredRuleSource::kUserEdit ||
         source == StoredRuleSource::kRestored ||
         source == StoredRuleSource::kTestFixture;
}

bool KnownLifetime(StoredRuleLifetime lifetime) {
  return lifetime == StoredRuleLifetime::kPersistent ||
         lifetime == StoredRuleLifetime::kProfileSession ||
         lifetime == StoredRuleLifetime::kUntil;
}

bool ValidateStoredRule(const StoredAccessRule& rule,
                        const OwnershipKey& owner,
                        bool independent) {
  const AccessPolicyRule& policy = rule.policy;
  if (!IsCompleteOwner(owner) || policy.owner != owner ||
      !Bounded(policy.rule_id) ||
      !IsCanonicalHostLike(policy.destination_host) ||
      policy.row_revision == 0 || policy.last_operation_sequence == 0 ||
      !FitsSqlInt64(policy.row_revision) ||
      !FitsSqlInt64(policy.last_operation_sequence) ||
      !KnownSource(rule.source) || !KnownLifetime(rule.lifetime) ||
      SchemeMask(policy.schemes) == 0 ||
      !std::ranges::is_sorted(policy.schemes)) {
    return false;
  }
  if (policy.scope == PolicyScope::kSite) {
    if (!IsSchemefulSiteLike(policy.top_level_site, "http://") &&
        !IsSchemefulSiteLike(policy.top_level_site, "https://")) {
      return false;
    }
  } else if (policy.scope != PolicyScope::kProfile ||
             !policy.top_level_site.empty()) {
    return false;
  }
  if (policy.ports.scope == PortScope::kAllBrowserPermitted) {
    if (!policy.ports.explicit_ports.empty()) {
      return false;
    }
  } else if (policy.ports.scope == PortScope::kExplicitSubset) {
    if (policy.ports.explicit_ports.empty() ||
        !std::ranges::is_sorted(policy.ports.explicit_ports) ||
        std::ranges::adjacent_find(policy.ports.explicit_ports) !=
            policy.ports.explicit_ports.end() ||
        policy.ports.explicit_ports.front() == 0) {
      return false;
    }
  } else {
    return false;
  }
  if (policy.mode == AccessMode::kProxy) {
    if (!Bounded(policy.proxy_group_id)) {
      return false;
    }
  } else if (policy.mode == AccessMode::kDirect ||
             policy.mode == AccessMode::kReject) {
    if (!policy.proxy_group_id.empty() ||
        policy.protection_override != ProtectionOverride::kNone) {
      return false;
    }
  } else {
    return false;
  }
  if (rule.lifetime == StoredRuleLifetime::kUntil) {
    if (rule.expires_at_micros <= 0) {
      return false;
    }
  } else if (rule.expires_at_micros != 0) {
    return false;
  }
  if (independent) {
    return rule.site_toggle_id.empty() && rule.site_toggle_revision == 0;
  }
  return Bounded(rule.site_toggle_id) && rule.site_toggle_revision != 0 &&
         policy.scope == PolicyScope::kSite &&
         policy.row_revision == rule.site_toggle_revision &&
         rule.lifetime == StoredRuleLifetime::kPersistent &&
         rule.expires_at_micros == 0;
}

void AppendImageField(std::string* output, std::string_view value) {
  output->append(std::to_string(value.size()));
  output->push_back(':');
  output->append(value);
}

std::string GroupImage(const StoredSiteGroup* stored) {
  if (!stored) {
    return "missing";
  }
  std::string result = "group:";
  const SiteProxyRuleGroup& group = stored->group;
  AppendImageField(&result, group.site_toggle_id);
  AppendImageField(&result, group.canonical_host);
  AppendImageField(&result, group.http_top_level_site);
  AppendImageField(&result, group.https_top_level_site);
  result.append(std::to_string(group.revision)).push_back(':');
  result.append(std::to_string(group.last_operation_sequence)).push_back(':');
  for (const StoredAccessRule& member : stored->members) {
    AppendImageField(&result, member.policy.rule_id);
    result.append(std::to_string(static_cast<int>(member.policy.mode)))
        .push_back(':');
    AppendImageField(&result, member.policy.proxy_group_id);
  }
  return result;
}

StoreResult<StoredPolicySnapshot> SnapshotError(StoreStatus status,
                                                std::string detail) {
  return {status, std::nullopt, std::move(detail)};
}

StoreResult<PendingMutationRecord> MutationError(StoreStatus status,
                                                 std::string detail) {
  return {status, std::nullopt, std::move(detail)};
}

int64_t NowMicros() {
  return base::Time::Now().ToDeltaSinceWindowsEpoch().InMicroseconds();
}

bool BindAndRunRuleInsert(sql::Database* database,
                          const StoredAccessRule& rule,
                          const std::string& durable_profile_id) {
  const AccessPolicyRule& policy = rule.policy;
  sql::Statement insert(database->GetUniqueStatement(
      "INSERT INTO access_rules(channel,durable_profile_id,"
      "storage_partition_token,rule_id,site_toggle_id,site_toggle_revision,"
      "scope,top_level_site,destination_host,include_subdomains,schemes_mask,"
      "port_scope,explicit_ports,mode,proxy_group_id,protection_override,"
      "source,lifetime,expires_at_micros,created_by_batch_id,row_revision,"
      "last_operation_sequence) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,"
      "?,?,?)"));
  insert.BindInt(0, static_cast<int>(policy.owner.channel));
  insert.BindString(1, durable_profile_id);
  insert.BindString(2, policy.owner.storage_partition_token);
  insert.BindString(3, policy.rule_id);
  insert.BindString(4, rule.site_toggle_id);
  insert.BindInt64(5, rule.site_toggle_revision);
  insert.BindInt(6, static_cast<int>(policy.scope));
  insert.BindString(7, policy.top_level_site);
  insert.BindString(8, policy.destination_host);
  insert.BindBool(9, policy.include_subdomains);
  insert.BindInt(10, SchemeMask(policy.schemes));
  insert.BindInt(11, static_cast<int>(policy.ports.scope));
  insert.BindString(12, SerializePorts(policy.ports.explicit_ports));
  insert.BindInt(13, static_cast<int>(policy.mode));
  insert.BindString(14, policy.proxy_group_id);
  insert.BindInt(15, static_cast<int>(policy.protection_override));
  insert.BindInt(16, static_cast<int>(rule.source));
  insert.BindInt(17, static_cast<int>(rule.lifetime));
  insert.BindInt64(18, rule.expires_at_micros);
  insert.BindString(19, rule.created_by_batch_id);
  insert.BindInt64(20, policy.row_revision);
  insert.BindInt64(21, policy.last_operation_sequence);
  return insert.Run();
}

}  // namespace

AccessStoreBinding::AccessStoreBinding(AccessStoreKind kind,
                                       ChannelNamespace channel,
                                       std::string durable_profile_id,
                                       std::string runtime_profile_token,
                                       base::FilePath profile_path,
                                       base::FilePath database_path)
    : kind_(kind),
      channel_(channel),
      durable_profile_id_(std::move(durable_profile_id)),
      runtime_profile_token_(std::move(runtime_profile_token)),
      profile_path_(std::move(profile_path)),
      database_path_(std::move(database_path)) {}

AccessStoreBinding::AccessStoreBinding(const AccessStoreBinding&) = default;

AccessStoreBinding::AccessStoreBinding(AccessStoreBinding&&) = default;

AccessStoreBinding& AccessStoreBinding::operator=(const AccessStoreBinding&) =
    default;

AccessStoreBinding& AccessStoreBinding::operator=(AccessStoreBinding&&) =
    default;

AccessStoreBinding::~AccessStoreBinding() = default;

AccessRuleStore::AccessRuleStore(AccessStoreBinding binding)
    : binding_(std::move(binding)), database_("AegisAccess") {}

AccessRuleStore::~AccessRuleStore() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
}

bool AccessRuleStore::IsBindingValid() const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!IsKnownChannel(binding_.channel()) ||
      !Bounded(binding_.durable_profile_id()) ||
      !Bounded(binding_.runtime_profile_token())) {
    return false;
  }
  if (binding_.kind() == AccessStoreKind::kSystemProfile) {
    return false;
  }
  if (binding_.kind() == AccessStoreKind::kEphemeralProfile) {
    return binding_.profile_path().empty() && binding_.database_path().empty();
  }
  return binding_.profile_path().IsAbsolute() &&
         !binding_.profile_path().ReferencesParent() &&
         binding_.database_path() ==
             binding_.profile_path().AppendASCII("access.db") &&
         binding_.database_path().DirName() == binding_.profile_path() &&
         binding_.database_path().BaseName() ==
             base::FilePath(FILE_PATH_LITERAL("access.db"));
}

bool AccessRuleStore::ShouldFail(FailurePointForTesting point) const {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return failure_point_for_testing_ == point;
}

StoreStatus AccessRuleStore::Open() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (is_open_) {
    return StoreStatus::kValid;
  }
  if (!IsBindingValid()) {
    terminal_status_ = StoreStatus::kInvalidArgument;
    return terminal_status_;
  }
  const bool opened = binding_.kind() == AccessStoreKind::kEphemeralProfile
                          ? database_.OpenInMemory()
                          : database_.Open(binding_.database_path());
  if (!opened) {
    terminal_status_ = StoreStatus::kIoError;
    return terminal_status_;
  }
  base::ScopedClosureRunner close_on_failure(base::BindOnce(
      [](sql::Database* database) { database->Close(); }, &database_));

  const bool has_meta = database_.DoesTableExist("meta");
  const bool has_identity = database_.DoesTableExist("access_store_identity");
  const bool has_counters = database_.DoesTableExist("access_store_counters");
  const bool has_groups = database_.DoesTableExist("access_site_groups");
  const bool has_rules = database_.DoesTableExist("access_rules");
  const bool has_journal = database_.DoesTableExist("access_mutation_journal");
  const bool has_any = has_meta || has_identity || has_counters || has_groups ||
                       has_rules || has_journal;
  const bool complete =
      has_identity && has_counters && has_groups && has_rules && has_journal;
  const bool initialize_schema = !has_any;
  if (has_meta) {
    sql::Statement version(database_.GetUniqueStatement(
        "SELECT value FROM meta WHERE key='version'"));
    sql::Statement compatible(database_.GetUniqueStatement(
        "SELECT value FROM meta WHERE key='last_compatible_version'"));
    if (!version.Step() || !compatible.Step()) {
      terminal_status_ = StoreStatus::kCorrupt;
      return terminal_status_;
    }
    const int stored_version = version.ColumnInt(0);
    const int stored_compatible = compatible.ColumnInt(0);
    if (stored_version != kSchemaVersion ||
        stored_compatible > kCompatibleVersion) {
      terminal_status_ = StoreStatus::kIncompatible;
      return terminal_status_;
    }
  }
  if (has_any && (!has_meta || !complete)) {
    terminal_status_ = StoreStatus::kCorrupt;
    return terminal_status_;
  }

  sql::Transaction transaction(&database_);
  if (!transaction.Begin() ||
      !meta_table_.Init(&database_, kSchemaVersion, kCompatibleVersion)) {
    terminal_status_ = StoreStatus::kIoError;
    return terminal_status_;
  }
  if (initialize_schema && (!database_.Execute(kCreateIdentitySql) ||
                            !database_.Execute(kCreateCountersSql) ||
                            !database_.Execute(kCreateGroupsSql) ||
                            !database_.Execute(kCreateRulesSql) ||
                            !database_.Execute(kCreateJournalSql))) {
    terminal_status_ = StoreStatus::kIoError;
    return terminal_status_;
  }

  const std::string trusted_path =
      binding_.kind() == AccessStoreKind::kPersistentProfile
          ? binding_.profile_path().AsUTF8Unsafe()
          : "<ephemeral>";
  sql::Statement identity(database_.GetUniqueStatement(
      "SELECT schema_version,channel,durable_profile_id,profile_path FROM "
      "access_store_identity WHERE singleton=1"));
  if (identity.Step()) {
    if (identity.ColumnInt(0) != kSchemaVersion ||
        identity.ColumnInt(1) != static_cast<int>(binding_.channel()) ||
        identity.ColumnString(2) != binding_.durable_profile_id() ||
        identity.ColumnString(3) != trusted_path) {
      terminal_status_ = StoreStatus::kConflict;
      return terminal_status_;
    }
  } else if (!identity.Succeeded()) {
    terminal_status_ = StoreStatus::kIoError;
    return terminal_status_;
  } else {
    sql::Statement insert(database_.GetUniqueStatement(
        "INSERT INTO access_store_identity(singleton,schema_version,channel,"
        "durable_profile_id,profile_path) VALUES(1,?,?,?,?)"));
    insert.BindInt(0, kSchemaVersion);
    insert.BindInt(1, static_cast<int>(binding_.channel()));
    insert.BindString(2, binding_.durable_profile_id());
    insert.BindString(3, trusted_path);
    if (!insert.Run()) {
      terminal_status_ = StoreStatus::kIoError;
      return terminal_status_;
    }
  }
  if (initialize_schema &&
      !database_.Execute("INSERT INTO access_store_counters"
                         "(singleton,operation_sequence) VALUES(1,0)")) {
    terminal_status_ = StoreStatus::kIoError;
    return terminal_status_;
  }
  sql::Statement counter(database_.GetUniqueStatement(
      "SELECT operation_sequence FROM access_store_counters WHERE "
      "singleton=1"));
  if (!counter.Step()) {
    terminal_status_ =
        counter.Succeeded() ? StoreStatus::kCorrupt : StoreStatus::kIoError;
    return terminal_status_;
  }
  const int64_t operation_sequence = counter.ColumnInt64(0);
  sql::Statement persisted_sequences(database_.GetUniqueStatement(
      "SELECT COALESCE(MAX(persisted_sequence),0),"
      "COALESCE(MIN(persisted_sequence),0),COUNT(*) FROM "
      "(SELECT last_operation_sequence AS persisted_sequence FROM "
      "access_site_groups UNION ALL SELECT last_operation_sequence AS "
      "persisted_sequence FROM access_rules UNION ALL SELECT "
      "operation_sequence AS persisted_sequence FROM "
      "access_mutation_journal)"));
  if (!persisted_sequences.Step()) {
    terminal_status_ = StoreStatus::kIoError;
    return terminal_status_;
  }
  const int64_t maximum_persisted_sequence = persisted_sequences.ColumnInt64(0);
  const int64_t minimum_persisted_sequence = persisted_sequences.ColumnInt64(1);
  const int64_t persisted_sequence_count = persisted_sequences.ColumnInt64(2);
  if (operation_sequence < 0 ||
      (persisted_sequence_count > 0 && minimum_persisted_sequence <= 0) ||
      operation_sequence < maximum_persisted_sequence) {
    terminal_status_ = StoreStatus::kCorrupt;
    return terminal_status_;
  }
  if (!transaction.Commit()) {
    terminal_status_ = StoreStatus::kIoError;
    return terminal_status_;
  }
  close_on_failure.ReplaceClosure(base::NullCallback());
  is_open_ = true;
  terminal_status_ = StoreStatus::kValid;
  return terminal_status_;
}

StoreResult<StoredPolicySnapshot> AccessRuleStore::ReadCommittedSnapshot(
    const std::string& partition) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  return ReadCommittedSnapshotInternal(partition, true);
}

StoreResult<StoredPolicySnapshot>
AccessRuleStore::ReadCommittedSnapshotInternal(const std::string& partition,
                                               bool check_recovery) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!is_open_) {
    return SnapshotError(terminal_status_, "store_not_open");
  }
  if (!Bounded(partition)) {
    return SnapshotError(StoreStatus::kInvalidArgument, "invalid_partition");
  }
  if (check_recovery) {
    sql::Statement journal(database_.GetUniqueStatement(
        "SELECT operation_id FROM access_mutation_journal WHERE "
        "storage_partition_token=? ORDER BY operation_sequence"));
    journal.BindString(0, partition);
    bool has_pending = false;
    while (journal.Step()) {
      StoreResult<PendingMutationRecord> loaded =
          LoadMutation(journal.ColumnString(0), false);
      if (!loaded.value.has_value()) {
        return SnapshotError(loaded.status, loaded.detail);
      }
      has_pending |= loaded.value->phase == MutationPhase::kPrepared;
    }
    if (!journal.Succeeded()) {
      return SnapshotError(StoreStatus::kIoError, "journal_read_failed");
    }
    if (has_pending) {
      return SnapshotError(StoreStatus::kRecoveryRequired,
                           "prepared_mutation_present");
    }
  }

  StoredPolicySnapshot snapshot;
  snapshot.owner = OwnerFor(binding_, partition);
  std::set<std::string> group_ids;
  sql::Statement groups(database_.GetUniqueStatement(
      "SELECT channel,durable_profile_id,site_toggle_id,canonical_host,"
      "http_top_level_site,https_top_level_site,http_member_rule_id,"
      "https_member_rule_id,revision,last_operation_sequence,"
      "committed_policy_generation FROM access_site_groups WHERE "
      "storage_partition_token=? ORDER BY site_toggle_id"));
  groups.BindString(0, partition);
  while (groups.Step()) {
    if (groups.ColumnInt(0) != static_cast<int>(binding_.channel()) ||
        groups.ColumnString(1) != binding_.durable_profile_id()) {
      return SnapshotError(StoreStatus::kConflict, "group_owner_mismatch");
    }
    StoredSiteGroup stored;
    stored.group.site_toggle_id = groups.ColumnString(2);
    stored.group.canonical_host = groups.ColumnString(3);
    stored.group.owner = snapshot.owner;
    stored.group.http_top_level_site = groups.ColumnString(4);
    stored.group.https_top_level_site = groups.ColumnString(5);
    stored.group.member_rule_ids = {groups.ColumnString(6),
                                    groups.ColumnString(7)};
    const int64_t revision = groups.ColumnInt64(8);
    const int64_t sequence = groups.ColumnInt64(9);
    const int64_t generation = groups.ColumnInt64(10);
    if (revision <= 0 || sequence <= 0 || generation <= 0 ||
        generation != sequence ||
        !group_ids.insert(stored.group.site_toggle_id).second) {
      return SnapshotError(StoreStatus::kCorrupt, "invalid_group_row");
    }
    stored.group.revision = static_cast<uint64_t>(revision);
    stored.group.last_operation_sequence = static_cast<uint64_t>(sequence);
    stored.policy_generation = static_cast<uint64_t>(generation);

    sql::Statement members(database_.GetUniqueStatement(
        "SELECT channel,durable_profile_id,rule_id,site_toggle_revision,scope,"
        "top_level_site,destination_host,include_subdomains,schemes_mask,"
        "port_scope,explicit_ports,mode,proxy_group_id,protection_override,"
        "source,lifetime,expires_at_micros,created_by_batch_id,row_revision,"
        "last_operation_sequence FROM access_rules WHERE "
        "storage_partition_token=? AND site_toggle_id=? ORDER BY rule_id"));
    members.BindString(0, partition);
    members.BindString(1, stored.group.site_toggle_id);
    while (members.Step()) {
      if (members.ColumnInt(0) != static_cast<int>(binding_.channel()) ||
          members.ColumnString(1) != binding_.durable_profile_id()) {
        return SnapshotError(StoreStatus::kConflict, "member_owner_mismatch");
      }
      const int scheme_mask = members.ColumnInt(8);
      const auto ports = ParsePorts(members.ColumnString(10));
      if ((scheme_mask & ~kCompleteSchemeMask) != 0 || scheme_mask == 0 ||
          !ports.has_value()) {
        return SnapshotError(StoreStatus::kCorrupt, "invalid_rule_encoding");
      }
      StoredAccessRule rule;
      rule.policy.rule_id = members.ColumnString(2);
      rule.policy.owner = snapshot.owner;
      rule.site_toggle_id = stored.group.site_toggle_id;
      const int64_t toggle_revision = members.ColumnInt64(3);
      rule.policy.scope = static_cast<PolicyScope>(members.ColumnInt(4));
      rule.policy.top_level_site = members.ColumnString(5);
      rule.policy.destination_host = members.ColumnString(6);
      rule.policy.include_subdomains = members.ColumnBool(7);
      rule.policy.schemes = SchemesFromMask(scheme_mask);
      rule.policy.ports.scope = static_cast<PortScope>(members.ColumnInt(9));
      rule.policy.ports.explicit_ports = *ports;
      rule.policy.mode = static_cast<AccessMode>(members.ColumnInt(11));
      rule.policy.proxy_group_id = members.ColumnString(12);
      rule.policy.protection_override =
          static_cast<ProtectionOverride>(members.ColumnInt(13));
      rule.source = static_cast<StoredRuleSource>(members.ColumnInt(14));
      rule.lifetime = static_cast<StoredRuleLifetime>(members.ColumnInt(15));
      rule.expires_at_micros = members.ColumnInt64(16);
      rule.created_by_batch_id = members.ColumnString(17);
      const int64_t row_revision = members.ColumnInt64(18);
      const int64_t operation_sequence = members.ColumnInt64(19);
      if (toggle_revision <= 0 || row_revision <= 0 ||
          operation_sequence <= 0) {
        return SnapshotError(StoreStatus::kCorrupt, "invalid_rule_revision");
      }
      rule.site_toggle_revision = static_cast<uint64_t>(toggle_revision);
      rule.policy.row_revision = static_cast<uint64_t>(row_revision);
      rule.policy.last_operation_sequence =
          static_cast<uint64_t>(operation_sequence);
      if (!ValidateStoredRule(rule, snapshot.owner, false)) {
        return SnapshotError(StoreStatus::kCorrupt, "invalid_group_member");
      }
      stored.members.push_back(std::move(rule));
    }
    if (!members.Succeeded()) {
      return SnapshotError(StoreStatus::kIoError, "member_read_failed");
    }
    std::vector<SiteProxyRuleMember> validation_members;
    for (const StoredAccessRule& rule : stored.members) {
      validation_members.push_back({
          rule.policy.rule_id,
          rule.policy.owner,
          rule.site_toggle_id,
          rule.site_toggle_revision,
          rule.policy.top_level_site,
          rule.policy.destination_host,
          rule.policy.schemes,
          rule.policy.ports.scope,
          rule.policy.include_subdomains,
          rule.policy.mode,
          rule.policy.proxy_group_id,
          rule.policy.protection_override,
          rule.policy.last_operation_sequence,
      });
    }
    if (ValidateBoundSiteGroup(snapshot.owner, &stored.group,
                               validation_members)
            .error != GroupValidationError::kNone) {
      return SnapshotError(StoreStatus::kCorrupt, "invalid_site_group");
    }
    snapshot.policy_generation =
        std::max(snapshot.policy_generation, stored.policy_generation);
    snapshot.site_groups.push_back(std::move(stored));
  }
  if (!groups.Succeeded()) {
    return SnapshotError(StoreStatus::kIoError, "group_read_failed");
  }

  sql::Statement rules(database_.GetUniqueStatement(
      "SELECT channel,durable_profile_id,rule_id,site_toggle_id,"
      "site_toggle_revision,scope,top_level_site,destination_host,"
      "include_subdomains,schemes_mask,port_scope,explicit_ports,mode,"
      "proxy_group_id,protection_override,source,lifetime,expires_at_micros,"
      "created_by_batch_id,row_revision,last_operation_sequence FROM "
      "access_rules WHERE storage_partition_token=? ORDER BY rule_id"));
  rules.BindString(0, partition);
  while (rules.Step()) {
    const std::string group_id = rules.ColumnString(3);
    if (!group_id.empty()) {
      if (!group_ids.contains(group_id)) {
        return SnapshotError(StoreStatus::kCorrupt, "orphan_group_member");
      }
      continue;
    }
    if (rules.ColumnInt(0) != static_cast<int>(binding_.channel()) ||
        rules.ColumnString(1) != binding_.durable_profile_id()) {
      return SnapshotError(StoreStatus::kConflict,
                           "independent_owner_mismatch");
    }
    const int scheme_mask = rules.ColumnInt(9);
    const auto ports = ParsePorts(rules.ColumnString(11));
    if ((scheme_mask & ~kCompleteSchemeMask) != 0 || scheme_mask == 0 ||
        !ports.has_value()) {
      return SnapshotError(StoreStatus::kCorrupt,
                           "invalid_independent_encoding");
    }
    StoredAccessRule rule;
    rule.policy.rule_id = rules.ColumnString(2);
    rule.policy.owner = snapshot.owner;
    rule.site_toggle_revision = rules.ColumnInt64(4);
    rule.policy.scope = static_cast<PolicyScope>(rules.ColumnInt(5));
    rule.policy.top_level_site = rules.ColumnString(6);
    rule.policy.destination_host = rules.ColumnString(7);
    rule.policy.include_subdomains = rules.ColumnBool(8);
    rule.policy.schemes = SchemesFromMask(scheme_mask);
    rule.policy.ports.scope = static_cast<PortScope>(rules.ColumnInt(10));
    rule.policy.ports.explicit_ports = *ports;
    rule.policy.mode = static_cast<AccessMode>(rules.ColumnInt(12));
    rule.policy.proxy_group_id = rules.ColumnString(13);
    rule.policy.protection_override =
        static_cast<ProtectionOverride>(rules.ColumnInt(14));
    rule.source = static_cast<StoredRuleSource>(rules.ColumnInt(15));
    rule.lifetime = static_cast<StoredRuleLifetime>(rules.ColumnInt(16));
    rule.expires_at_micros = rules.ColumnInt64(17);
    rule.created_by_batch_id = rules.ColumnString(18);
    const int64_t row_revision = rules.ColumnInt64(19);
    const int64_t operation_sequence = rules.ColumnInt64(20);
    if (row_revision <= 0 || operation_sequence <= 0) {
      return SnapshotError(StoreStatus::kCorrupt,
                           "invalid_independent_revision");
    }
    rule.policy.row_revision = static_cast<uint64_t>(row_revision);
    rule.policy.last_operation_sequence =
        static_cast<uint64_t>(operation_sequence);
    if (!ValidateStoredRule(rule, snapshot.owner, true)) {
      return SnapshotError(StoreStatus::kCorrupt, "invalid_independent_rule");
    }
    snapshot.independent_rules.push_back(std::move(rule));
  }
  if (!rules.Succeeded()) {
    return SnapshotError(StoreStatus::kIoError, "rule_read_failed");
  }

  if (snapshot.site_groups.empty() && snapshot.independent_rules.empty()) {
    return {StoreStatus::kMissing, std::move(snapshot), "empty_partition"};
  }
  return {StoreStatus::kValid, std::move(snapshot), {}};
}

StoreResult<PendingMutationRecord> AccessRuleStore::PrepareSiteGroupMutation(
    const SiteGroupMutationRequest& request) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!is_open_) {
    return MutationError(terminal_status_, "store_not_open");
  }
  if (!Bounded(request.operation_id) || !Bounded(request.request_fingerprint) ||
      !Bounded(request.candidate_group.site_toggle_id) ||
      !IsCanonicalHostLike(request.candidate_group.canonical_host) ||
      request.candidate_group.member_rule_ids.size() != 2 ||
      request.candidate_members.size() != 2 ||
      !FitsSqlInt64(request.expected_revision)) {
    return MutationError(StoreStatus::kInvalidArgument, "invalid_request");
  }
  const OwnershipKey expected_owner = request.candidate_group.owner;
  if (!IsCompleteOwner(expected_owner) ||
      expected_owner.channel != binding_.channel() ||
      expected_owner.profile_token != binding_.runtime_profile_token() ||
      request.candidate_group.revision != 0 ||
      request.candidate_group.last_operation_sequence != 0) {
    return MutationError(StoreStatus::kConflict, "untrusted_owner_or_version");
  }
  for (const SiteProxyRuleMember& member : request.candidate_members) {
    if (member.owner != expected_owner || member.group_revision != 0 ||
        member.last_operation_sequence != 0) {
      return MutationError(StoreStatus::kConflict, "unstamped_member");
    }
  }
  const std::set<std::string> declared_ids(
      request.candidate_group.member_rule_ids.begin(),
      request.candidate_group.member_rule_ids.end());
  const std::set<std::string> member_ids = {
      request.candidate_members[0].rule_id,
      request.candidate_members[1].rule_id};
  if (declared_ids.size() != 2 || declared_ids != member_ids) {
    return MutationError(StoreStatus::kInvalidArgument, "member_id_mismatch");
  }

  sql::Transaction transaction(&database_);
  if (!transaction.Begin()) {
    return MutationError(StoreStatus::kIoError, "prepare_begin_failed");
  }
  const int64_t now_micros = NowMicros();
  const int64_t retention_cutoff =
      now_micros - kMutationRetention.InMicroseconds();
  sql::Statement prune(database_.GetUniqueStatement(
      "DELETE FROM access_mutation_journal WHERE state IN (?,?) AND "
      "completed_at_micros>0 AND completed_at_micros<=?"));
  prune.BindInt(0, kCommitted);
  prune.BindInt(1, kSuperseded);
  prune.BindInt64(2, retention_cutoff);
  if (!prune.Run()) {
    return MutationError(StoreStatus::kIoError, "journal_prune_failed");
  }
  if (ShouldFail(FailurePointForTesting::kPrepareAfterRetentionCleanup)) {
    return MutationError(StoreStatus::kIoError, "injected_prune_failure");
  }
  StoreResult<PendingMutationRecord> existing =
      LoadMutation(request.operation_id, false);
  if (existing.value.has_value()) {
    if (existing.value->request_fingerprint == request.request_fingerprint) {
      return existing;
    }
    return MutationError(StoreStatus::kConflict, "operation_id_reused");
  }
  if (existing.status == StoreStatus::kCorrupt ||
      existing.status == StoreStatus::kIoError) {
    return existing;
  }
  sql::Statement journal_count(database_.GetUniqueStatement(
      "SELECT COUNT(*) FROM access_mutation_journal"));
  if (!journal_count.Step() || journal_count.ColumnInt64(0) < 0) {
    return MutationError(StoreStatus::kIoError, "journal_count_failed");
  }
  if (journal_count.ColumnInt64(0) >=
      static_cast<int64_t>(kMaxMutationJournalRows)) {
    return MutationError(StoreStatus::kCapacity, "journal_capacity");
  }
  StoreResult<StoredPolicySnapshot> current = ReadCommittedSnapshotInternal(
      expected_owner.storage_partition_token, false);
  if (current.status != StoreStatus::kMissing &&
      current.status != StoreStatus::kValid) {
    return MutationError(current.status, current.detail);
  }
  const StoredSiteGroup* before = nullptr;
  if (current.value.has_value()) {
    for (const StoredSiteGroup& group : current.value->site_groups) {
      if (group.group.canonical_host ==
              request.candidate_group.canonical_host ||
          group.group.site_toggle_id ==
              request.candidate_group.site_toggle_id) {
        if (before != nullptr ||
            group.group.canonical_host !=
                request.candidate_group.canonical_host ||
            group.group.site_toggle_id !=
                request.candidate_group.site_toggle_id) {
          return MutationError(StoreStatus::kConflict,
                               "site_identity_conflict");
        }
        before = &group;
      }
    }
  }
  const uint64_t current_revision = before ? before->group.revision : 0;
  if (current_revision != request.expected_revision) {
    return MutationError(StoreStatus::kConflict, "revision_conflict");
  }
  sql::Statement pending(database_.GetUniqueStatement(
      "SELECT 1 FROM access_mutation_journal WHERE state=? AND "
      "storage_partition_token=? AND site_toggle_id=? LIMIT 1"));
  pending.BindInt(0, kPrepared);
  pending.BindString(1, expected_owner.storage_partition_token);
  pending.BindString(2, request.candidate_group.site_toggle_id);
  if (pending.Step()) {
    return MutationError(StoreStatus::kRecoveryRequired,
                         "pending_mutation_exists");
  }
  if (!pending.Succeeded()) {
    return MutationError(StoreStatus::kIoError, "pending_read_failed");
  }

  sql::Statement counters(
      database_.GetUniqueStatement("SELECT operation_sequence FROM "
                                   "access_store_counters WHERE singleton=1"));
  if (!counters.Step()) {
    return MutationError(StoreStatus::kCorrupt, "missing_counters");
  }
  const int64_t sequence = counters.ColumnInt64(0);
  if (sequence < 0) {
    return MutationError(StoreStatus::kCorrupt, "invalid_counters");
  }
  if (sequence == std::numeric_limits<int64_t>::max() ||
      current_revision ==
          static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
    return MutationError(StoreStatus::kConflict, "counter_overflow");
  }

  PendingMutationRecord record;
  record.phase = MutationPhase::kPrepared;
  record.operation_id = request.operation_id;
  record.request_fingerprint = request.request_fingerprint;
  record.owner = expected_owner;
  record.expected_revision = current_revision;
  record.target_revision = current_revision + 1;
  record.operation_sequence = static_cast<uint64_t>(sequence) + 1;
  record.committed_policy_generation = 0;
  record.created_at_micros = now_micros;
  record.completed_at_micros = 0;
  record.candidate.group = request.candidate_group;
  record.candidate.group.revision = record.target_revision;
  record.candidate.group.last_operation_sequence = record.operation_sequence;
  record.candidate.policy_generation = record.operation_sequence;
  const AccessMode mode = request.candidate_members[0].mode;
  std::vector<SiteProxyRuleMember> normalized_members =
      request.candidate_members;
  std::ranges::sort(normalized_members, [&](const SiteProxyRuleMember& left,
                                            const SiteProxyRuleMember& right) {
    const bool left_is_http =
        left.top_level_site == request.candidate_group.http_top_level_site;
    const bool right_is_http =
        right.top_level_site == request.candidate_group.http_top_level_site;
    return left_is_http != right_is_http ? left_is_http
                                         : left.rule_id < right.rule_id;
  });
  record.candidate.group.member_rule_ids = {normalized_members[0].rule_id,
                                            normalized_members[1].rule_id};
  for (SiteProxyRuleMember member : normalized_members) {
    if (SchemeMask(member.schemes) != kCompleteSchemeMask) {
      return MutationError(StoreStatus::kInvalidArgument,
                           "invalid_member_schemes");
    }
    member.schemes = {RequestScheme::kHttp, RequestScheme::kHttps,
                      RequestScheme::kWs, RequestScheme::kWss};
    member.group_revision = record.target_revision;
    member.last_operation_sequence = record.operation_sequence;
    StoredAccessRule stored;
    stored.policy = {
        .rule_id = member.rule_id,
        .owner = member.owner,
        .scope = PolicyScope::kSite,
        .top_level_site = member.top_level_site,
        .destination_host = member.exact_host,
        .include_subdomains = member.include_subdomains,
        .schemes = member.schemes,
        .ports = {member.ports, {}},
        .mode = member.mode,
        .proxy_group_id = member.proxy_group_id,
        .protection_override = member.protection_override,
        .row_revision = record.target_revision,
        .last_operation_sequence = record.operation_sequence,
    };
    stored.site_toggle_id = member.site_toggle_id;
    stored.site_toggle_revision = record.target_revision;
    stored.source = StoredRuleSource::kUserAction;
    stored.lifetime = StoredRuleLifetime::kPersistent;
    record.candidate.members.push_back(std::move(stored));
  }
  std::vector<SiteProxyRuleMember> stamped_members = normalized_members;
  for (SiteProxyRuleMember& member : stamped_members) {
    member.group_revision = record.target_revision;
    member.last_operation_sequence = record.operation_sequence;
  }
  if ((mode != AccessMode::kDirect && mode != AccessMode::kProxy) ||
      ValidateBoundSiteGroup(expected_owner, &record.candidate.group,
                             stamped_members)
              .error != GroupValidationError::kNone) {
    return MutationError(StoreStatus::kInvalidArgument,
                         "invalid_site_group_candidate");
  }
  record.before_image = GroupImage(before);
  record.after_image = GroupImage(&record.candidate);

  sql::Statement update(database_.GetUniqueStatement(
      "UPDATE access_store_counters SET operation_sequence=? WHERE "
      "singleton=1 AND operation_sequence=?"));
  update.BindInt64(0, record.operation_sequence);
  update.BindInt64(1, sequence);
  if (!update.Run() || database_.GetLastChangeCount() != 1) {
    return MutationError(StoreStatus::kConflict, "counter_conflict");
  }
  if (ShouldFail(FailurePointForTesting::kPrepareAfterCounterUpdate) ||
      ShouldFail(FailurePointForTesting::kPrepareBeforeJournalInsert)) {
    return MutationError(StoreStatus::kIoError, "injected_prepare_failure");
  }

  sql::Statement insert(database_.GetUniqueStatement(
      "INSERT INTO access_mutation_journal(operation_id,request_fingerprint,"
      "state,schema_version,channel,durable_profile_id,profile_path,"
      "storage_partition_token,site_toggle_id,canonical_host,"
      "http_top_level_site,https_top_level_site,http_member_rule_id,"
      "https_member_rule_id,target_mode,proxy_group_id,expected_revision,"
      "target_revision,operation_sequence,committed_policy_generation,"
      "created_at_micros,completed_at_micros,before_image,"
      "after_image) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"));
  insert.BindString(0, record.operation_id);
  insert.BindString(1, record.request_fingerprint);
  insert.BindInt(2, kPrepared);
  insert.BindInt(3, kSchemaVersion);
  insert.BindInt(4, static_cast<int>(record.owner.channel));
  insert.BindString(5, binding_.durable_profile_id());
  insert.BindString(6, binding_.kind() == AccessStoreKind::kPersistentProfile
                           ? binding_.profile_path().AsUTF8Unsafe()
                           : "<ephemeral>");
  insert.BindString(7, record.owner.storage_partition_token);
  insert.BindString(8, record.candidate.group.site_toggle_id);
  insert.BindString(9, record.candidate.group.canonical_host);
  insert.BindString(10, record.candidate.group.http_top_level_site);
  insert.BindString(11, record.candidate.group.https_top_level_site);
  insert.BindString(12, record.candidate.group.member_rule_ids[0]);
  insert.BindString(13, record.candidate.group.member_rule_ids[1]);
  insert.BindInt(14, static_cast<int>(mode));
  insert.BindString(15, record.candidate.members[0].policy.proxy_group_id);
  insert.BindInt64(16, record.expected_revision);
  insert.BindInt64(17, record.target_revision);
  insert.BindInt64(18, record.operation_sequence);
  insert.BindInt64(19, 0);
  insert.BindInt64(20, record.created_at_micros);
  insert.BindInt64(21, 0);
  insert.BindString(22, record.before_image);
  insert.BindString(23, record.after_image);
  if (!insert.Run() ||
      ShouldFail(FailurePointForTesting::kPrepareAfterJournalInsert) ||
      !transaction.Commit()) {
    return MutationError(StoreStatus::kIoError, "journal_write_failed");
  }
  return {StoreStatus::kValid, std::move(record), {}};
}

StoreResult<PendingMutationRecord> AccessRuleStore::LoadMutation(
    const std::string& operation_id,
    bool prepared_only) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!is_open_) {
    return MutationError(terminal_status_, "store_not_open");
  }
  sql::Statement row(database_.GetUniqueStatement(
      "SELECT request_fingerprint,state,schema_version,channel,"
      "durable_profile_id,profile_path,storage_partition_token,site_toggle_id,"
      "canonical_host,http_top_level_site,https_top_level_site,"
      "http_member_rule_id,https_member_rule_id,target_mode,proxy_group_id,"
      "expected_revision,target_revision,operation_sequence,"
      "committed_policy_generation,created_at_micros,completed_at_micros,"
      "before_image,after_image FROM access_mutation_journal WHERE "
      "operation_id=?"));
  row.BindString(0, operation_id);
  if (!row.Step()) {
    return row.Succeeded()
               ? MutationError(StoreStatus::kMissing, "mutation_missing")
               : MutationError(StoreStatus::kIoError, "mutation_read_failed");
  }
  const int state = row.ColumnInt(1);
  if ((prepared_only && state != kPrepared) || state < kPrepared ||
      state > kSuperseded) {
    return MutationError(state < kPrepared || state > kSuperseded
                             ? StoreStatus::kCorrupt
                             : StoreStatus::kMissing,
                         "mutation_not_prepared");
  }
  const std::string trusted_path =
      binding_.kind() == AccessStoreKind::kPersistentProfile
          ? binding_.profile_path().AsUTF8Unsafe()
          : "<ephemeral>";
  if (row.ColumnInt(2) != kSchemaVersion ||
      row.ColumnInt(3) != static_cast<int>(binding_.channel()) ||
      row.ColumnString(4) != binding_.durable_profile_id() ||
      row.ColumnString(5) != trusted_path) {
    return MutationError(StoreStatus::kConflict, "journal_owner_mismatch");
  }
  const int64_t expected_revision = row.ColumnInt64(15);
  const int64_t target_revision = row.ColumnInt64(16);
  const int64_t sequence = row.ColumnInt64(17);
  const int64_t committed_generation = row.ColumnInt64(18);
  const int64_t created_at_micros = row.ColumnInt64(19);
  const int64_t completed_at_micros = row.ColumnInt64(20);
  const AccessMode mode = static_cast<AccessMode>(row.ColumnInt(13));
  if (expected_revision < 0 ||
      expected_revision == std::numeric_limits<int64_t>::max() ||
      target_revision <= 0 || sequence <= 0 ||
      committed_generation < 0 || target_revision != expected_revision + 1 ||
      created_at_micros <= 0 ||
      (state == kPrepared &&
       (committed_generation != 0 || completed_at_micros != 0)) ||
      (state == kCommitted &&
       (committed_generation == 0 || committed_generation != sequence)) ||
      (state == kSuperseded && committed_generation != 0) ||
      (state != kPrepared && completed_at_micros < created_at_micros) ||
      (mode != AccessMode::kDirect && mode != AccessMode::kProxy)) {
    return MutationError(StoreStatus::kCorrupt, "invalid_journal_version");
  }
  PendingMutationRecord record;
  record.phase = state == kPrepared    ? MutationPhase::kPrepared
                 : state == kCommitted ? MutationPhase::kCommitted
                                       : MutationPhase::kSuperseded;
  record.operation_id = operation_id;
  record.request_fingerprint = row.ColumnString(0);
  record.owner = OwnerFor(binding_, row.ColumnString(6));
  record.expected_revision = static_cast<uint64_t>(expected_revision);
  record.target_revision = static_cast<uint64_t>(target_revision);
  record.operation_sequence = static_cast<uint64_t>(sequence);
  record.committed_policy_generation =
      static_cast<uint64_t>(committed_generation);
  record.created_at_micros = created_at_micros;
  record.completed_at_micros = completed_at_micros;
  record.before_image = row.ColumnString(21);
  record.after_image = row.ColumnString(22);
  record.candidate.group = {
      .site_toggle_id = row.ColumnString(7),
      .canonical_host = row.ColumnString(8),
      .owner = record.owner,
      .http_top_level_site = row.ColumnString(9),
      .https_top_level_site = row.ColumnString(10),
      .member_rule_ids = {row.ColumnString(11), row.ColumnString(12)},
      .revision = record.target_revision,
      .last_operation_sequence = record.operation_sequence,
  };
  record.candidate.policy_generation = record.operation_sequence;
  const std::string proxy_group_id = row.ColumnString(14);
  const std::vector<RequestScheme> schemes = {
      RequestScheme::kHttp, RequestScheme::kHttps, RequestScheme::kWs,
      RequestScheme::kWss};
  for (size_t i = 0; i < 2; ++i) {
    StoredAccessRule member;
    member.policy = {
        .rule_id = record.candidate.group.member_rule_ids[i],
        .owner = record.owner,
        .scope = PolicyScope::kSite,
        .top_level_site = i == 0 ? record.candidate.group.http_top_level_site
                                 : record.candidate.group.https_top_level_site,
        .destination_host = record.candidate.group.canonical_host,
        .include_subdomains = false,
        .schemes = schemes,
        .ports = {PortScope::kAllBrowserPermitted, {}},
        .mode = mode,
        .proxy_group_id = proxy_group_id,
        .protection_override = ProtectionOverride::kNone,
        .row_revision = record.target_revision,
        .last_operation_sequence = record.operation_sequence,
    };
    member.site_toggle_id = record.candidate.group.site_toggle_id;
    member.site_toggle_revision = record.target_revision;
    member.source = StoredRuleSource::kUserAction;
    member.lifetime = StoredRuleLifetime::kPersistent;
    record.candidate.members.push_back(std::move(member));
  }
  if (!Bounded(record.request_fingerprint) ||
      GroupImage(&record.candidate) != record.after_image) {
    return MutationError(StoreStatus::kCorrupt, "journal_image_mismatch");
  }
  return {
      state == kPrepared ? StoreStatus::kRecoveryRequired : StoreStatus::kValid,
      std::move(record),
      {}};
}

StoreResult<RecoveryState> AccessRuleStore::LoadRecoveryState() {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!is_open_) {
    return {terminal_status_, std::nullopt, "store_not_open"};
  }
  RecoveryState recovery;
  sql::Statement rows(database_.GetUniqueStatement(
      "SELECT operation_id FROM access_mutation_journal ORDER BY "
      "operation_sequence"));
  while (rows.Step()) {
    StoreResult<PendingMutationRecord> loaded =
        LoadMutation(rows.ColumnString(0), false);
    if (!loaded.value.has_value()) {
      return {loaded.status, std::nullopt, loaded.detail};
    }
    if (loaded.value->phase == MutationPhase::kPrepared) {
      recovery.pending.push_back(std::move(*loaded.value));
    }
  }
  if (!rows.Succeeded()) {
    return {StoreStatus::kIoError, std::nullopt, "recovery_read_failed"};
  }
  return {recovery.pending.empty() ? StoreStatus::kValid
                                   : StoreStatus::kRecoveryRequired,
          std::move(recovery),
          {}};
}

StoreStatus AccessRuleStore::SupersedePreparedMutation(
    const std::string& operation_id,
    const std::string& fingerprint) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!is_open_ || !Bounded(operation_id) || !Bounded(fingerprint)) {
    return StoreStatus::kInvalidArgument;
  }
  sql::Statement update(database_.GetUniqueStatement(
      "UPDATE access_mutation_journal SET state=?,completed_at_micros="
      "MAX(created_at_micros,?) WHERE operation_id=? AND "
      "request_fingerprint=? AND state=?"));
  update.BindInt(0, kSuperseded);
  update.BindInt64(1, NowMicros());
  update.BindString(2, operation_id);
  update.BindString(3, fingerprint);
  update.BindInt(4, kPrepared);
  if (!update.Run()) {
    return StoreStatus::kIoError;
  }
  return database_.GetLastChangeCount() == 1 ? StoreStatus::kValid
                                             : StoreStatus::kConflict;
}

StoreResult<PendingMutationRecord> AccessRuleStore::CommitPreparedMutation(
    const PendingMutationRecord& expected) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!is_open_) {
    return MutationError(terminal_status_, "store_not_open");
  }
  sql::Transaction transaction(&database_);
  if (!transaction.Begin()) {
    return MutationError(StoreStatus::kIoError, "commit_begin_failed");
  }
  StoreResult<PendingMutationRecord> loaded =
      LoadMutation(expected.operation_id, true);
  if (!loaded.value.has_value()) {
    return loaded;
  }
  const PendingMutationRecord& record = *loaded.value;
  const uint64_t committed_policy_generation = record.operation_sequence;
  if (expected.phase != MutationPhase::kPrepared ||
      expected.request_fingerprint != record.request_fingerprint ||
      expected.owner != record.owner ||
      expected.expected_revision != record.expected_revision ||
      expected.target_revision != record.target_revision ||
      expected.operation_sequence != record.operation_sequence ||
      expected.committed_policy_generation !=
          record.committed_policy_generation ||
      expected.before_image != record.before_image ||
      expected.after_image != record.after_image ||
      expected.candidate != record.candidate) {
    return MutationError(StoreStatus::kConflict, "prepared_record_mismatch");
  }
  StoreResult<StoredPolicySnapshot> current = ReadCommittedSnapshotInternal(
      record.owner.storage_partition_token, false);
  if (current.status != StoreStatus::kMissing &&
      current.status != StoreStatus::kValid) {
    return MutationError(current.status, current.detail);
  }
  const StoredSiteGroup* before = nullptr;
  if (current.value.has_value()) {
    for (const StoredSiteGroup& group : current.value->site_groups) {
      if (group.group.site_toggle_id == record.candidate.group.site_toggle_id) {
        before = &group;
        break;
      }
    }
  }
  if ((before ? before->group.revision : 0) != record.expected_revision ||
      GroupImage(before) != record.before_image) {
    return MutationError(StoreStatus::kConflict, "committed_base_changed");
  }
  sql::Statement latest_generation(database_.GetUniqueStatement(
      "SELECT COALESCE(MAX(committed_policy_generation),0) FROM "
      "access_site_groups"));
  if (!latest_generation.Step()) {
    return MutationError(StoreStatus::kIoError, "generation_read_failed");
  }
  if (latest_generation.ColumnInt64(0) < 0 ||
      committed_policy_generation <=
          static_cast<uint64_t>(latest_generation.ColumnInt64(0))) {
    return MutationError(StoreStatus::kConflict, "generation_not_monotonic");
  }

  sql::Statement delete_rules(database_.GetUniqueStatement(
      "DELETE FROM access_rules WHERE storage_partition_token=? AND "
      "site_toggle_id=?"));
  delete_rules.BindString(0, record.owner.storage_partition_token);
  delete_rules.BindString(1, record.candidate.group.site_toggle_id);
  if (!delete_rules.Run() ||
      ShouldFail(FailurePointForTesting::kCommitAfterRuleDelete)) {
    return MutationError(StoreStatus::kIoError, "rule_replace_failed");
  }
  sql::Statement delete_group(database_.GetUniqueStatement(
      "DELETE FROM access_site_groups WHERE storage_partition_token=? AND "
      "site_toggle_id=?"));
  delete_group.BindString(0, record.owner.storage_partition_token);
  delete_group.BindString(1, record.candidate.group.site_toggle_id);
  if (!delete_group.Run() ||
      ShouldFail(FailurePointForTesting::kCommitAfterGroupDelete)) {
    return MutationError(StoreStatus::kIoError, "group_replace_failed");
  }

  const SiteProxyRuleGroup& group = record.candidate.group;
  sql::Statement insert_group(database_.GetUniqueStatement(
      "INSERT INTO access_site_groups(channel,durable_profile_id,"
      "storage_partition_token,site_toggle_id,canonical_host,"
      "http_top_level_site,https_top_level_site,http_member_rule_id,"
      "https_member_rule_id,revision,last_operation_sequence,"
      "committed_policy_generation) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)"));
  insert_group.BindInt(0, static_cast<int>(record.owner.channel));
  insert_group.BindString(1, binding_.durable_profile_id());
  insert_group.BindString(2, record.owner.storage_partition_token);
  insert_group.BindString(3, group.site_toggle_id);
  insert_group.BindString(4, group.canonical_host);
  insert_group.BindString(5, group.http_top_level_site);
  insert_group.BindString(6, group.https_top_level_site);
  insert_group.BindString(7, group.member_rule_ids[0]);
  insert_group.BindString(8, group.member_rule_ids[1]);
  insert_group.BindInt64(9, group.revision);
  insert_group.BindInt64(10, group.last_operation_sequence);
  insert_group.BindInt64(11, committed_policy_generation);
  if (!insert_group.Run() ||
      ShouldFail(FailurePointForTesting::kCommitAfterGroupInsert)) {
    return MutationError(StoreStatus::kIoError, "group_insert_failed");
  }
  for (size_t i = 0; i < record.candidate.members.size(); ++i) {
    if (!BindAndRunRuleInsert(&database_, record.candidate.members[i],
                              binding_.durable_profile_id()) ||
        (i == 0 &&
         ShouldFail(FailurePointForTesting::kCommitAfterFirstMemberInsert))) {
      return MutationError(StoreStatus::kIoError, "member_insert_failed");
    }
  }
  if (ShouldFail(FailurePointForTesting::kCommitBeforeJournalUpdate)) {
    return MutationError(StoreStatus::kIoError, "journal_commit_injected");
  }
  sql::Statement mark(database_.GetUniqueStatement(
      "UPDATE access_mutation_journal SET state=?,"
      "committed_policy_generation=?,completed_at_micros=? WHERE "
      "operation_id=? AND "
      "request_fingerprint=? AND state=? AND operation_sequence=? AND "
      "committed_policy_generation=0"));
  mark.BindInt(0, kCommitted);
  mark.BindInt64(1, committed_policy_generation);
  const int64_t completed_at_micros =
      std::max(record.created_at_micros, NowMicros());
  mark.BindInt64(2, completed_at_micros);
  mark.BindString(3, record.operation_id);
  mark.BindString(4, record.request_fingerprint);
  mark.BindInt(5, kPrepared);
  mark.BindInt64(6, record.operation_sequence);
  if (!mark.Run() || database_.GetLastChangeCount() != 1 ||
      ShouldFail(FailurePointForTesting::kCommitAfterJournalUpdate) ||
      !transaction.Commit()) {
    return MutationError(StoreStatus::kIoError, "journal_commit_failed");
  }
  PendingMutationRecord committed = record;
  committed.phase = MutationPhase::kCommitted;
  committed.committed_policy_generation = committed_policy_generation;
  committed.completed_at_micros = completed_at_micros;
  committed.candidate.policy_generation = committed_policy_generation;
  return {StoreStatus::kValid, std::move(committed), {}};
}

StoreResult<MatcherRuleSetCandidate> AccessRuleStore::AdaptMatcherSnapshot(
    const StoredPolicySnapshot& stored) {
  if (!IsCompleteOwner(stored.owner) || stored.policy_generation == 0) {
    return {StoreStatus::kCorrupt, std::nullopt, "invalid_snapshot_header"};
  }
  MatcherRuleSetCandidate matcher;
  matcher.owner = stored.owner;
  matcher.committed_policy_generation = stored.policy_generation;
  std::set<std::string> rule_ids;
  std::set<std::string> normalized_keys;
  uint64_t maximum_group_generation = 0;
  auto append_rule = [&](const StoredAccessRule& rule,
                         bool independent) -> StoreStatus {
    if (!ValidateStoredRule(rule, stored.owner, independent)) {
      return StoreStatus::kCorrupt;
    }
    std::string key =
        std::to_string(static_cast<int>(rule.policy.scope)) + "\n" +
        rule.policy.top_level_site + "\n" + rule.policy.destination_host +
        "\n" + std::to_string(rule.policy.include_subdomains) + "\n" +
        std::to_string(SchemeMask(rule.policy.schemes)) + "\n" +
        std::to_string(static_cast<int>(rule.policy.ports.scope)) + "\n" +
        SerializePorts(rule.policy.ports.explicit_ports);
    if (!rule_ids.insert(rule.policy.rule_id).second ||
        !normalized_keys.insert(std::move(key)).second) {
      return StoreStatus::kConflict;
    }
    matcher.rules.push_back(rule.policy);
    return StoreStatus::kValid;
  };
  for (const StoredSiteGroup& group : stored.site_groups) {
    if (group.group.owner != stored.owner || group.policy_generation == 0 ||
        group.policy_generation > stored.policy_generation ||
        group.members.size() != 2) {
      return {StoreStatus::kCorrupt, std::nullopt, "invalid_group_owner"};
    }
    maximum_group_generation =
        std::max(maximum_group_generation, group.policy_generation);
    std::vector<SiteProxyRuleMember> members;
    members.reserve(group.members.size());
    for (const StoredAccessRule& rule : group.members) {
      if (!ValidateStoredRule(rule, stored.owner, false)) {
        return {StoreStatus::kCorrupt, std::nullopt, "invalid_group_rule"};
      }
      members.push_back({
          .rule_id = rule.policy.rule_id,
          .owner = rule.policy.owner,
          .site_toggle_id = rule.site_toggle_id,
          .group_revision = rule.site_toggle_revision,
          .top_level_site = rule.policy.top_level_site,
          .exact_host = rule.policy.destination_host,
          .schemes = rule.policy.schemes,
          .ports = rule.policy.ports.scope,
          .include_subdomains = rule.policy.include_subdomains,
          .mode = rule.policy.mode,
          .proxy_group_id = rule.policy.proxy_group_id,
          .protection_override = rule.policy.protection_override,
          .last_operation_sequence = rule.policy.last_operation_sequence,
      });
    }
    const aegis_access::GroupValidation validation =
        ValidateBoundSiteGroup(stored.owner, &group.group, members);
    if (validation.error != GroupValidationError::kNone) {
      return {StoreStatus::kCorrupt, std::nullopt, "invalid_site_group"};
    }
    for (const StoredAccessRule& rule : group.members) {
      const StoreStatus status = append_rule(rule, false);
      if (status != StoreStatus::kValid) {
        return {status, std::nullopt, "invalid_group_rule"};
      }
    }
  }
  if (!stored.site_groups.empty() &&
      stored.policy_generation != maximum_group_generation) {
    return {StoreStatus::kCorrupt, std::nullopt,
            "snapshot_generation_mismatch"};
  }
  for (const StoredAccessRule& rule : stored.independent_rules) {
    const StoreStatus status = append_rule(rule, true);
    if (status != StoreStatus::kValid) {
      return {status, std::nullopt, "invalid_independent_rule"};
    }
  }
  return {StoreStatus::kValid, std::move(matcher), {}};
}

StoreStatus AccessRuleStore::ImportIndependentRuleForTesting(
    const StoredAccessRule& rule) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  if (!is_open_ || rule.source != StoredRuleSource::kTestFixture ||
      rule.lifetime != StoredRuleLifetime::kPersistent ||
      !ValidateStoredRule(rule, rule.policy.owner, true) ||
      rule.policy.owner.channel != binding_.channel() ||
      rule.policy.owner.profile_token != binding_.runtime_profile_token()) {
    return StoreStatus::kInvalidArgument;
  }
  sql::Transaction transaction(&database_);
  if (!transaction.Begin()) {
    return StoreStatus::kIoError;
  }
  sql::Statement collision(database_.GetUniqueStatement(
      "SELECT 1 FROM access_rules WHERE storage_partition_token=? AND "
      "rule_id=?"));
  collision.BindString(0, rule.policy.owner.storage_partition_token);
  collision.BindString(1, rule.policy.rule_id);
  if (collision.Step()) {
    return StoreStatus::kConflict;
  }
  sql::Statement advance_counter(database_.GetUniqueStatement(
      "UPDATE access_store_counters SET operation_sequence="
      "MAX(operation_sequence,?) WHERE singleton=1"));
  advance_counter.BindInt64(0, rule.policy.last_operation_sequence);
  if (!collision.Succeeded() || !advance_counter.Run() ||
      database_.GetLastChangeCount() != 1 ||
      !BindAndRunRuleInsert(&database_, rule, binding_.durable_profile_id()) ||
      !transaction.Commit()) {
    return StoreStatus::kIoError;
  }
  return StoreStatus::kValid;
}

}  // namespace aegis::access
