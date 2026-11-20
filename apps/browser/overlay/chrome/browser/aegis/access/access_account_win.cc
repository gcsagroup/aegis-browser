// Copyright 2026 GCSA
#include "chrome/browser/aegis/access/access_account_win.h"

#include <windows.h>
#include <winhttp.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <memory>
#include <string_view>
#include <utility>

#include "base/base64.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "base/win/scoped_handle.h"
#include "chrome/browser/aegis/access/access_private_files_win.h"
#include "url/gurl.h"

namespace aegis::access {
namespace {

constexpr size_t kMaxBody = 64 * 1024;
constexpr DWORD kMaxBinding = 8192;
constexpr int64_t kMaxTime = 9007199254740991LL;
constexpr char kCredentialPath[] = "/v1/me/node-credentials";
constexpr char kAlphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";

struct HttpCloser {
  void operator()(void* handle) const { ::WinHttpCloseHandle(handle); }
};
using HttpHandle = std::unique_ptr<void, HttpCloser>;

struct Binding {
  GURL origin;
  std::string account;
  std::string token;
  base::RepeatingCallback<std::string()> changed;
  base::RepeatingCallback<std::string()> verify_on_worker;
};

base::DictValue State(std::string_view state) {
  return base::DictValue().Set("state", state);
}

bool Token(std::string_view value) {
  return !value.empty() && value.size() <= 256 &&
         value.find_first_not_of(kAlphabet) == value.npos;
}

std::optional<Binding> MakeBinding(std::string_view origin,
                                   std::string account,
                                   std::string token) {
  GURL url(origin);
  const auto host = url.host();
  const bool loopback = host == "127.0.0.1" || host == "[::1]";
  if (!url.is_valid() || !url.has_host() || url.has_username() ||
      url.has_password() || url.has_query() || url.has_ref() ||
      url.path() != "/" || account.empty() || !Token(token) ||
      !(url.SchemeIs("https") || (loopback && url.SchemeIs("http")))) {
    return std::nullopt;
  }
  return Binding{std::move(url), std::move(account), std::move(token), {}, {}};
}

struct FileIdentity {
  FILE_ID_INFO id{};
  FILE_BASIC_INFO basic{};
};

std::optional<FileIdentity> Identity(HANDLE file) {
  FileIdentity info;
  FILE_STANDARD_INFO standard{};
  if (::GetFileType(file) != FILE_TYPE_DISK ||
      !::GetFileInformationByHandleEx(file, FileIdInfo, &info.id, sizeof(info.id)) ||
      !::GetFileInformationByHandleEx(file, FileBasicInfo, &info.basic,
                                      sizeof(info.basic)) ||
      !::GetFileInformationByHandleEx(file, FileStandardInfo, &standard,
                                      sizeof(standard)) ||
      standard.Directory || standard.NumberOfLinks != 1 ||
      (info.basic.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
    return std::nullopt;
  }
  return info;
}

bool SameFile(const FileIdentity& a, const FileIdentity& b) {
  return a.id.VolumeSerialNumber == b.id.VolumeSerialNumber &&
         a.basic.CreationTime.QuadPart == b.basic.CreationTime.QuadPart &&
         a.basic.LastWriteTime.QuadPart == b.basic.LastWriteTime.QuadPart &&
         a.basic.ChangeTime.QuadPart == b.basic.ChangeTime.QuadPart &&
         std::ranges::equal(a.id.FileId.Identifier, b.id.FileId.Identifier);
}

base::win::ScopedHandle OpenBinding(const base::FilePath& path, DWORD access) {
  return base::win::ScopedHandle(::CreateFileW(
      path.value().c_str(), access, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
}

bool Missing(DWORD error) {
  return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND;
}

std::optional<base::DictValue> ReadBindingData(HANDLE file) {
  LARGE_INTEGER length{};
  if (!::GetFileSizeEx(file, &length) || length.QuadPart <= 0 ||
      length.QuadPart > kMaxBinding) {
    return std::nullopt;
  }
  std::string bytes(static_cast<size_t>(length.QuadPart), '\0');
  DWORD count = 0;
  if (!::ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                  &count, nullptr) || count != bytes.size()) {
    return std::nullopt;
  }
  return base::JSONReader::ReadDict(bytes, base::JSON_PARSE_RFC);
}

enum class BindingCheck { kFileIdentity, kContents };

std::string CurrentBindingState(const base::FilePath& path,
                                const FileIdentity& original,
                                const std::string& generation,
                                BindingCheck check) {
  auto file = OpenBinding(path, check == BindingCheck::kFileIdentity
                                    ? FILE_READ_ATTRIBUTES
                                    : GENERIC_READ | READ_CONTROL);
  if (!file.is_valid()) {
    return Missing(::GetLastError()) ? "signed_out" : "unavailable";
  }
  auto identity = Identity(file.get());
  if (!identity || !SameFile(*identity, original)) return "superseded";
  // The UI polls the identity of the atomically provisioned binding. ACL and
  // JSON generation checks belong to the worker handling the account request.
  if (check == BindingCheck::kFileIdentity) return "";
  if (!IsPrivateAccessFile(file.get())) return "superseded";
  auto data = ReadBindingData(file.get());
  const auto* current = data ? data->FindString("generation") : nullptr;
  return current && *current == generation ? "" : "superseded";
}

std::optional<Binding> ReadBinding(
    const base::FilePath& profile,
    std::string& failure,
    base::RepeatingCallback<std::string()>& absent_change) {
  if (!profile.IsAbsolute() || !IsOwnedAccessDirectory(profile)) return std::nullopt;
  const auto path = profile.AppendASCII("AegisAccessAccount.json");
  auto file = OpenBinding(path, GENERIC_READ | READ_CONTROL);
  const auto open_error = ::GetLastError();
  if (!file.is_valid()) {
    if (Missing(open_error)) {
      failure = "signed_out";
      absent_change = base::BindRepeating([](const base::FilePath& path) {
        const auto attrs = ::GetFileAttributesW(path.value().c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES) return std::string("superseded");
        return Missing(::GetLastError()) ? std::string() : std::string("unavailable");
      }, path);
    }
    return std::nullopt;
  }
  const auto original = Identity(file.get());
  if (!original || !IsPrivateAccessFile(file.get())) return std::nullopt;
  auto json = ReadBindingData(file.get());
  if (!json) return std::nullopt;
  const auto* origin = json->FindString("origin");
  const auto* account = json->FindString("accountId");
  const auto* token = json->FindString("token");
  const auto* generation = json->FindString("generation");
  if (!origin || !account || !token || !generation ||
      !base::Uuid::ParseCaseInsensitive(*generation).is_valid()) {
    return std::nullopt;
  }
  auto binding = MakeBinding(*origin, *account, *token);
  if (!binding) return std::nullopt;

  // A live handle would leave the filename delete-pending on sign-out.
  // The persisted generation distinguishes new bindings even if an ID is reused.
  auto validate = base::BindRepeating(&CurrentBindingState, path, *original,
                                      *generation);
  binding->changed = base::BindRepeating(validate, BindingCheck::kFileIdentity);
  binding->verify_on_worker = base::BindRepeating(validate, BindingCheck::kContents);
  auto state = binding->changed.Run();
  if (!state.empty()) {
    failure = std::move(state);
    return std::nullopt;
  }
  return binding;
}

struct Response {
  DWORD status = 0;
  std::string body;
};

Response Request(const Binding& binding, std::wstring_view method,
                 std::string_view path, const base::DictValue* payload = nullptr) {
  HttpHandle session(::WinHttpOpen(L"Aegis Access/1.0",
      WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME,
      WINHTTP_NO_PROXY_BYPASS, 0));
  if (!session || !::WinHttpSetTimeouts(session.get(), 2000, 2000, 3000, 3000)) {
    return {};
  }
  const auto start = base::TimeTicks::Now();
  std::wstring host = base::UTF8ToWide(binding.origin.HostNoBrackets());
  HttpHandle connection(::WinHttpConnect(session.get(), host.c_str(),
      static_cast<INTERNET_PORT>(binding.origin.EffectiveIntPort()), 0));
  if (!connection) return {};
  const std::wstring verb(method);
  const auto target = base::UTF8ToWide(path);
  HttpHandle request(::WinHttpOpenRequest(connection.get(), verb.c_str(),
      target.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
      binding.origin.SchemeIs("https") ? WINHTTP_FLAG_SECURE : 0));
  DWORD disable = WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_REDIRECTS |
                  WINHTTP_DISABLE_AUTHENTICATION;
  if (!request || !::WinHttpSetOption(request.get(), WINHTTP_OPTION_DISABLE_FEATURE,
                                     &disable, sizeof(disable))) {
    return {};
  }
  auto headers = L"Authorization: Bearer " + base::UTF8ToWide(binding.token) + L"\r\n";
  std::string body;
  if (payload) {
    auto json = base::WriteJson(*payload);
    if (!json) return {};
    body = std::move(*json);
    headers += L"Content-Type: application/json\r\n";
  }
  const auto size = static_cast<DWORD>(body.size());
  if (!::WinHttpSendRequest(request.get(), headers.c_str(), static_cast<DWORD>(-1),
                            body.empty() ? WINHTTP_NO_REQUEST_DATA : body.data(),
                            size, size, 0) ||
      !::WinHttpReceiveResponse(request.get(), nullptr)) {
    return {};
  }
  Response response;
  DWORD status_size = sizeof(response.status);
  if (!::WinHttpQueryHeaders(request.get(),
                              WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                              WINHTTP_HEADER_NAME_BY_INDEX, &response.status,
                              &status_size, WINHTTP_NO_HEADER_INDEX)) return {};
  if (response.status != 200 && response.status != 201) return response;
  std::array<char, 4096> bytes;
  while (base::TimeTicks::Now() - start < base::Seconds(8)) {
    DWORD count = 0;
    if (!::WinHttpReadData(request.get(), bytes.data(),
                          static_cast<DWORD>(bytes.size()), &count) ||
        response.body.size() + count > kMaxBody) return {};
    if (!count) return response;
    response.body.append(bytes.data(), count);
  }
  return {};
}

std::optional<int64_t> Milliseconds(const base::DictValue& values,
                                    std::string_view key) {
  const auto number = values.FindDouble(key);
  if (!number || !(*number >= 0 && *number <= kMaxTime &&
                   std::floor(*number) == *number)) return std::nullopt;
  return static_cast<int64_t>(*number);
}

std::optional<uint64_t> Bytes(const base::DictValue& values,
                              std::string_view key) {
  const auto* value = values.FindString(key);
  uint64_t result = 0;
  if (!value || value->empty() ||
      (value->size() > 1 && value->front() == '0') ||
      value->find_first_not_of("0123456789") != value->npos ||
      !base::StringToUint64(*value, &result)) return std::nullopt;
  return result;
}

bool Matches(const base::DictValue& values, std::string_view key,
             std::string_view expected) {
  const auto* value = values.FindString(key);
  return value && *value == expected;
}

bool Nonempty(const base::DictValue& values, std::string_view key) {
  const auto* value = values.FindString(key);
  return value && !value->empty();
}

const char* Freshness(int64_t age) {
  if (age <= 5000) return "current";
  if (age <= 15000) return "delayed";
  return "unavailable";
}

std::optional<base::DictValue> ParseEntitlement(std::string_view bytes,
                                                std::string_view account,
                                                int64_t& evaluated_at) {
  auto data = base::JSONReader::ReadDict(bytes, base::JSON_PARSE_RFC);
  if (!data || !Matches(*data, "entitlementAccountId", account) ||
      !Nonempty(*data, "status")) return std::nullopt;
  const auto& status = *data->FindString("status");
  const bool subscribed = status != "not_subscribed";
  static constexpr std::string_view fields[] = {
      "planId", "periodId", "periodStart", "periodEnd", "expiresAt",
      "uploadedBytes", "downloadedBytes", "usedBytes", "quotaBytes",
      "remainingBytes", "measuredAt", "receivedAt", "snapshotAgeMs",
      "freshness"};
  base::DictValue clean;
  for (auto key : fields) {
    const auto* value = data->Find(key);
    if (!value || (!subscribed && !value->is_none())) return std::nullopt;
    clean.Set(key, value->Clone());
  }
  clean.Set("entitlementAccountId", account);
  clean.Set("status", status);
  const bool panel = data->contains("quotaSource") ||
                     data->contains("panelExpiryMode") ||
                     data->contains("panelExpiresAt");
  if (!subscribed) {
    return panel ? std::nullopt
                 : std::optional<base::DictValue>(std::move(clean));
  }
  const auto start = Milliseconds(clean, "periodStart");
  const auto end = Milliseconds(clean, "periodEnd");
  const auto expiry = Milliseconds(clean, "expiresAt");
  const auto received = Milliseconds(clean, "receivedAt");
  const auto up = Bytes(clean, "uploadedBytes");
  const auto down = Bytes(clean, "downloadedBytes");
  const auto used = Bytes(clean, "usedBytes");
  const auto quota = Bytes(clean, "quotaBytes");
  const auto remaining = Bytes(clean, "remainingBytes");
  constexpr uint64_t max_count = std::numeric_limits<int64_t>::max();
  if (!Nonempty(clean, "planId") || !Nonempty(clean, "periodId") ||
      !start || !end || !expiry || !*expiry || !received ||
      *end <= *start || *received < *start ||
      !up || !down || !used || !quota || !remaining ||
      *up > max_count || *down > max_count || *quota > max_count ||
      *up + *down != *used ||
      *remaining != (*used < *quota ? *quota - *used : 0)) return std::nullopt;
  if (panel) {
    const auto* panel_expiry = data->Find("panelExpiresAt");
    if (!Matches(*data, "quotaSource", "3xui_alpha") || !panel_expiry) {
      return std::nullopt;
    }
    if (Matches(*data, "panelExpiryMode", "none")) {
      if (!panel_expiry->is_none() || *expiry != *end) return std::nullopt;
    } else {
      const auto absolute = Milliseconds(*data, "panelExpiresAt");
      if (!Matches(*data, "panelExpiryMode", "absolute") ||
          !absolute || !*absolute || *expiry != std::min(*end, *absolute)) {
        return std::nullopt;
      }
    }
    clean.Set("quotaSource", "3xui_alpha");
    clean.Set("panelExpiryMode", *data->FindString("panelExpiryMode"));
    clean.Set("panelExpiresAt", panel_expiry->Clone());
  }
  const auto evaluated = Milliseconds(*data, "evaluatedAt");
  if (data->contains("evaluatedAt") && (!evaluated || *evaluated < *received)) {
    return std::nullopt;
  }
  if (clean.Find("measuredAt")->is_none()) {
    if (!clean.Find("snapshotAgeMs")->is_none() || !evaluated ||
        !Matches(clean, "freshness", "unavailable")) return std::nullopt;
    evaluated_at = *evaluated;
  } else {
    const auto measured = Milliseconds(clean, "measuredAt");
    const auto age = Milliseconds(clean, "snapshotAgeMs");
    if (!measured || !age || *measured < *start || *measured > *received ||
        *age < *received - *measured || *age > kMaxTime - *measured ||
        (evaluated && *evaluated != *measured + *age) ||
        !Matches(clean, "freshness", Freshness(*age))) return std::nullopt;
    evaluated_at = *measured + *age;
  }
  const char* expected = evaluated_at >= std::min(*end, *expiry) ? "expired"
                        : *used >= *quota ? "exhausted" : "active";
  if (status != expected) return std::nullopt;
  return clean;
}

AccountSnapshot Query(base::FilePath profile) {
  const auto started = base::TimeTicks::Now();
  std::string failure = "unavailable";
  base::RepeatingCallback<std::string()> changed;
  auto binding = ReadBinding(profile, failure, changed);
  int64_t evaluated = 0;
  auto result = State(failure);
  if (binding) {
    changed = binding->changed;
    auto response = Request(*binding, L"GET", "/v1/me/entitlement");
    auto current = binding->verify_on_worker.Run();
    if (!current.empty()) {
      result = State(current);
    } else if (response.status == 401) {
      result = State("signed_out");
    } else if (response.status == 200) {
      auto entitlement = ParseEntitlement(response.body, binding->account, evaluated);
      if (entitlement) result = State("available").Set("entitlement", std::move(*entitlement));
    }
  }
  return base::BindRepeating(
      [](const base::DictValue& result,
         const base::RepeatingCallback<std::string()>& changed,
         base::TimeTicks started, int64_t evaluated) {
        if (changed) {
          const auto state = changed.Run();
          if (!state.empty()) return State(state);
        }
        auto reply = result.Clone();
        auto* entitlement = reply.FindDict("entitlement");
        if (!entitlement || Matches(*entitlement, "status", "not_subscribed")) {
          return reply;
        }
        const auto elapsed = (base::TimeTicks::Now() - started).InMilliseconds();
        const auto now = std::min(kMaxTime, evaluated + elapsed);
        if (auto age = Milliseconds(*entitlement, "snapshotAgeMs")) {
          const auto measured = *Milliseconds(*entitlement, "measuredAt");
          const auto updated = std::min(kMaxTime - measured, *age + elapsed);
          entitlement->Set("snapshotAgeMs", static_cast<double>(updated));
          entitlement->Set("freshness", Freshness(updated));
        }
        if (now >= std::min(*Milliseconds(*entitlement, "expiresAt"),
                            *Milliseconds(*entitlement, "periodEnd"))) {
          entitlement->Set("status", "expired");
        }
        reply.Set("queryElapsedMs", static_cast<double>(elapsed));
        reply.Set("evaluatedAt", static_cast<double>(now));
        return reply;
      }, std::move(result), std::move(changed), started, evaluated);
}

std::optional<AccountNodeGrant> Issue(
    base::FilePath profile, std::optional<PrivateAccountBinding> private_binding,
    std::string context) {
  const std::string mode = private_binding ? "private" : "regular";
  std::string failure;
  base::RepeatingCallback<std::string()> absent_change;
  auto binding = private_binding
      ? MakeBinding(private_binding->origin, std::move(private_binding->account),
                    std::move(private_binding->token))
      : ReadBinding(profile, failure, absent_change);
  if (!binding || !base::Uuid::ParseLowercase(context).is_valid()) {
    return std::nullopt;
  }
  const auto payload = base::DictValue().Set("mode", mode).Set("contextId", context);
  const auto response = Request(*binding, L"POST", kCredentialPath, &payload);
  if (response.status != 200 && response.status != 201) return std::nullopt;
  const auto data = base::JSONReader::ReadDict(response.body, base::JSON_PARSE_RFC);
  const auto* id = data ? data->FindString("credentialId") : nullptr;
  if (!id || !base::Uuid::ParseLowercase(*id).is_valid()) return std::nullopt;
  const auto resource = std::string(kCredentialPath) + "/" + *id;
  auto revoke = base::BindOnce([](Binding binding, std::string resource) {
    base::ThreadPool::PostTask(
        FROM_HERE, {base::MayBlock(), base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
        base::BindOnce([](Binding binding, std::string resource) {
          Request(binding, L"DELETE", resource);
        }, std::move(binding), std::move(resource)));
  }, *binding, resource);
  const auto* host = data->FindString("host");
  const auto* password = data->FindString("password");
  const auto* period = data->FindString("periodId");
  const auto port = Milliseconds(*data, "port");
  const auto expires = Milliseconds(*data, "expiresAt");
  if (!Matches(*data, "accountId", binding->account) || !period || period->empty() ||
      !Matches(*data, "mode", mode) || !Matches(*data, "contextId", context) ||
      !Matches(*data, "username", *id) || !password || !Token(*password) ||
      !host || host->empty() || host->size() > 253 ||
      host->find_first_not_of(
          "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:") != host->npos ||
      !port || *port < 1 || *port > 65535 || !expires ||
      *expires <= base::Time::Now().InMillisecondsSinceUnixEpoch() ||
      (binding->verify_on_worker && !binding->verify_on_worker.Run().empty())) {
    std::move(revoke).Run();
    return std::nullopt;
  }
  auto renew = base::BindRepeating(
      [](const Binding& binding, const std::string& resource,
         const std::string& credential, const std::string& period,
         const std::string& context, const std::string& mode,
         base::OnceCallback<void(int64_t)> done) {
        base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, {base::MayBlock()},
            base::BindOnce([](const Binding& binding, const std::string& resource,
                              const std::string& credential, const std::string& period,
                              const std::string& context, const std::string& mode) -> int64_t {
              if (binding.verify_on_worker && !binding.verify_on_worker.Run().empty()) return 0;
              auto body = base::DictValue().Set("mode", mode).Set("contextId", context);
              auto res = Request(binding, L"POST", resource + "/renew", &body);
              auto reply = res.status == 200
                  ? base::JSONReader::ReadDict(res.body, base::JSON_PARSE_RFC)
                  : std::nullopt;
              if (!reply || !Matches(*reply, "accountId", binding.account) ||
                  !Matches(*reply, "credentialId", credential) ||
                  !Matches(*reply, "periodId", period) ||
                  !Matches(*reply, "contextId", context) ||
                  !Matches(*reply, "mode", mode) ||
                  (binding.verify_on_worker && !binding.verify_on_worker.Run().empty())) return 0;
              return Milliseconds(*reply, "expiresAt").value_or(0);
            }, binding, resource, credential, period, context, mode),
            std::move(done));
      }, *binding, resource, *id, *period, context, mode);
  return AccountNodeGrant{*host, static_cast<uint16_t>(*port),
                          "Basic " + base::Base64Encode(*id + ":" + *password),
                          *expires, binding->changed, base::ScopedClosureRunner(std::move(revoke)),
                          std::move(renew)};
}

}  // namespace

void QueryWindowsAccessAccount(const base::FilePath& profile,
                               base::OnceCallback<void(AccountSnapshot)> done) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock()}, base::BindOnce(&Query, profile),
      std::move(done));
}

void IssueWindowsAccessNode(
    const base::FilePath& profile,
    std::optional<PrivateAccountBinding> private_binding,
    std::string context,
    base::OnceCallback<void(std::optional<AccountNodeGrant>)> done) {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
      base::BindOnce(&Issue, profile, std::move(private_binding), std::move(context)),
      std::move(done));
}

}  // namespace aegis::access
