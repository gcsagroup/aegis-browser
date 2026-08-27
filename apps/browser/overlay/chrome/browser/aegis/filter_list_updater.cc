// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/filter_list_updater.cc

#include "chrome/browser/aegis/filter_list_updater.h"

#include <optional>
#include <utility>

#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/callback_helpers.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/after_startup_task_utils.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/aegis/filter_list_matcher.h"
#include "chrome/common/aegis/pref_names.h"
#include "components/prefs/pref_service.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/http/http_request_headers.h"
#include "net/http/http_response_headers.h"
#include "net/http/http_status_code.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "url/gurl.h"

namespace aegis {
namespace {

constexpr char kEasyListUrl[] = "https://easylist.to/easylist/easylist.txt";
constexpr char kEasyPrivacyUrl[] =
    "https://easylist.to/easylist/easyprivacy.txt";
constexpr char kCompiledFile[] = "compiled.json";
constexpr char kFilterDir[] = "AegisFilterLists";
constexpr int64_t kAutoUpdateIntervalSeconds = 24 * 60 * 60;
constexpr int64_t kRetryAfterFailureSeconds = 60 * 60;
// SimpleURLLoader::DownloadToString DCHECKs above this bound (5 MiB).
constexpr size_t kMaxBodyBytes =
    network::SimpleURLLoader::kMaxBoundedStringDownloadSize;

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_filter_list_update", R"(
      semantics {
        sender: "GCSA-aegis"
        description:
          "Downloads EasyList and EasyPrivacy to compile tracker/ad host "
          "rules used by AegisNetThrottle."
        trigger:
          "When the local compiled cache is missing or older than one day, "
          "on a 24-hour timer while the browser is running, or when the user "
          "clicks Update on chrome://aegis."
        data: "None. Only the public filter-list URL is requested."
        destination: WEBSITE
        internal {
          contacts {
            email: "aegis@gcsa.local"
          }
        }
        user_data {
          type: NONE
        }
        last_reviewed: "2026-08-14"
      }
      policy {
        cookies_allowed: NO
        setting:
          "Users can disable filter-list auto-update on chrome://aegis."
        policy_exception_justification: "Not yet implemented."
      })");

base::FilePath CompiledPath(Profile* profile) {
  return profile->GetPath().AppendASCII(kFilterDir).AppendASCII(kCompiledFile);
}

int64_t NowUnixSeconds() {
  return (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
}

int64_t TimeToUnixSeconds(base::Time time) {
  if (time.is_null()) {
    return 0;
  }
  return (time - base::Time::UnixEpoch()).InSeconds();
}

bool CacheIsFresh(int64_t last_unix) {
  if (last_unix <= 0) {
    return false;
  }
  const int64_t now = NowUnixSeconds();
  // 时钟回拨时当作仍新鲜，避免每次启动都重新下载。
  if (now < last_unix) {
    return true;
  }
  return now - last_unix < kAutoUpdateIntervalSeconds;
}

}  // namespace

FilterListUpdater::FilterListUpdater(Profile* profile)
    : profile_(profile), prefs_(profile->GetPrefs()) {}

FilterListUpdater::~FilterListUpdater() = default;

void FilterListUpdater::LoadFromDisk() {
  const base::FilePath path = CompiledPath(profile_);
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
      base::BindOnce(
          [](base::FilePath path) -> FilterListUpdater::LoadedCache {
            FilterListUpdater::LoadedCache cache;
            base::File::Info info;
            std::string json;
            if (!base::GetFileInfo(path, &info) ||
                !base::ReadFileToString(path, &json)) {
              return cache;
            }
            CompiledFilterList list;
            if (!CompiledFilterListFromJson(json, &list)) {
              return cache;
            }
            if (list.hosts.empty() && list.path_rules.empty()) {
              return cache;
            }
            cache.list = std::move(list);
            cache.file_mtime_unix = TimeToUnixSeconds(info.last_modified);
            return cache;
          },
          path),
      base::BindOnce(&FilterListUpdater::OnLoadedFromDisk,
                     weak_factory_.GetWeakPtr()));
}

void FilterListUpdater::OnLoadedFromDisk(LoadedCache cache) {
  if (cache.list) {
    ApplyList(std::move(*cache.list));
    if (prefs_) {
      const int64_t last = prefs_->GetInt64(prefs::kFilterListLastUpdated);
      // pref 丢失时用文件 mtime 回填，避免已有缓存仍被当成首次启动。
      if (last <= 0 && cache.file_mtime_unix > 0) {
        prefs_->SetInt64(prefs::kFilterListLastUpdated, cache.file_mtime_unix);
      }
    }
    LOG(INFO) << "Aegis: using cached filter list, hosts="
              << FilterListMatcher::GetInstance()->compiled_host_count();
  }
  MaybeAutoUpdate();
}

void FilterListUpdater::OnAutoUpdateEnabledChanged() {
  refresh_timer_.Stop();
  MaybeAutoUpdate();
}

void FilterListUpdater::MaybeAutoUpdate() {
  refresh_timer_.Stop();
  if (!prefs_ || !prefs_->GetBoolean(prefs::kFilterListAutoUpdateEnabled)) {
    return;
  }
  if (updating_) {
    return;
  }

  const int64_t now = NowUnixSeconds();
  const int64_t last = prefs_->GetInt64(prefs::kFilterListLastUpdated);
  if (CacheIsFresh(last)) {
    const int64_t remaining = kAutoUpdateIntervalSeconds - (now - last);
    VLOG(1) << "Aegis: filter list cache is fresh, skip download";
    ScheduleNextAutoUpdate(base::Seconds(remaining > 0 ? remaining
                                                       : kAutoUpdateIntervalSeconds));
    return;
  }

  const int64_t last_attempt = prefs_->GetInt64(prefs::kFilterListLastAttempt);
  const std::string last_error = prefs_->GetString(prefs::kFilterListLastError);
  if (!last_error.empty() && last_attempt > 0) {
    const int64_t elapsed = now - last_attempt;
    if (elapsed >= 0 && elapsed < kRetryAfterFailureSeconds) {
      LOG(INFO) << "Aegis: filter list update backing off after failure";
      ScheduleNextAutoUpdate(base::Seconds(kRetryAfterFailureSeconds - elapsed));
      return;
    }
  }

  LOG(INFO) << "Aegis: filter list cache missing or stale, "
               "will fetch after startup";
  AfterStartupTaskUtils::PostTask(
      FROM_HERE, base::SequencedTaskRunner::GetCurrentDefault(),
      base::BindOnce(&FilterListUpdater::UpdateNow, weak_factory_.GetWeakPtr(),
                     base::DoNothing()));
}

void FilterListUpdater::ScheduleNextAutoUpdate(base::TimeDelta delay) {
  if (!prefs_ || !prefs_->GetBoolean(prefs::kFilterListAutoUpdateEnabled)) {
    return;
  }
  if (delay < base::Minutes(1)) {
    delay = base::Minutes(1);
  }
  if (delay > base::Hours(24)) {
    delay = base::Hours(24);
  }
  refresh_timer_.Start(
      FROM_HERE, delay,
      base::BindOnce(&FilterListUpdater::OnScheduledRefresh,
                     weak_factory_.GetWeakPtr()));
}

void FilterListUpdater::OnScheduledRefresh() {
  MaybeAutoUpdate();
}

void FilterListUpdater::UpdateNow(UpdateCallback callback) {
  if (updating_) {
    if (callback) {
      std::move(callback).Run(false);
    }
    return;
  }
  if (!g_browser_process || !g_browser_process->shared_url_loader_factory()) {
    if (callback) {
      std::move(callback).Run(false);
    }
    return;
  }
  updating_ = true;
  pending_ = std::move(callback);
  skip_validators_ = false;
  fetch_index_ = 0;
  urls_ = {kEasyListUrl, kEasyPrivacyUrl};
  compiled_by_index_.assign(urls_.size(), std::nullopt);
  FetchNext();
}

void FilterListUpdater::AttachValidators(network::ResourceRequest* request) {
  if (skip_validators_ || !prefs_ || !request) {
    return;
  }
  const base::DictValue* entry =
      prefs_->GetDict(prefs::kFilterListHttpValidators)
          .FindDict(request->url.spec());
  if (!entry) {
    return;
  }
  if (const std::string* etag = entry->FindString("etag")) {
    if (!etag->empty()) {
      request->headers.SetHeader(net::HttpRequestHeaders::kIfNoneMatch, *etag);
    }
  }
  if (const std::string* last_modified = entry->FindString("lastModified")) {
    if (!last_modified->empty()) {
      request->headers.SetHeader(net::HttpRequestHeaders::kIfModifiedSince,
                                 *last_modified);
    }
  }
}

void FilterListUpdater::RememberValidators(
    const std::string& url,
    const net::HttpResponseHeaders* headers) {
  if (!prefs_ || !headers || url.empty()) {
    return;
  }
  base::DictValue entry;
  if (std::optional<std::string> etag = headers->GetNormalizedHeader("etag")) {
    if (!etag->empty()) {
      entry.Set("etag", std::move(*etag));
    }
  }
  // last-modified 是 non-coalescing header，不能用 GetNormalizedHeader（DCHECK 会崩）。
  std::string last_modified;
  if (headers->EnumerateHeader(nullptr, "last-modified", &last_modified) &&
      !last_modified.empty()) {
    entry.Set("lastModified", std::move(last_modified));
  }
  if (entry.empty()) {
    return;
  }
  base::DictValue validators =
      prefs_->GetDict(prefs::kFilterListHttpValidators).Clone();
  validators.Set(url, std::move(entry));
  prefs_->SetDict(prefs::kFilterListHttpValidators, std::move(validators));
}

void FilterListUpdater::FetchNext() {
  while (fetch_index_ < urls_.size() && compiled_by_index_[fetch_index_]) {
    fetch_index_++;
  }
  if (fetch_index_ >= urls_.size()) {
    BeginMergeOrRefetchMissing();
    return;
  }

  auto request = std::make_unique<network::ResourceRequest>();
  request->url = GURL(urls_[fetch_index_]);
  request->load_flags = net::LOAD_DISABLE_CACHE;
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->priority = net::IDLE;
  AttachValidators(request.get());

  loader_ = network::SimpleURLLoader::Create(std::move(request),
                                             kTrafficAnnotation);
  loader_->SetAllowHttpErrorResults(true);
  loader_->SetRetryOptions(
      2, network::SimpleURLLoader::RetryMode::RETRY_ON_NETWORK_CHANGE);
  loader_->DownloadToString(
      g_browser_process->shared_url_loader_factory().get(),
      base::BindOnce(&FilterListUpdater::OnFetched, weak_factory_.GetWeakPtr()),
      kMaxBodyBytes);
}

void FilterListUpdater::OnFetched(std::optional<std::string> body) {
  const int net_error = loader_ ? loader_->NetError() : net::ERR_FAILED;
  const net::HttpResponseHeaders* headers = nullptr;
  if (loader_ && loader_->ResponseInfo()) {
    headers = loader_->ResponseInfo()->headers.get();
  }
  const int status = headers ? headers->response_code() : 0;
  const std::string source = urls_[fetch_index_];
  RememberValidators(source, headers);
  loader_.reset();

  if (net_error != net::OK) {
    Finish(false, "fetch failed (" + base::NumberToString(net_error) + ")");
    return;
  }
  if (status == net::HTTP_NOT_MODIFIED) {
    fetch_index_++;
    FetchNext();
    return;
  }
  if (status != net::HTTP_OK || !body) {
    Finish(false, "fetch failed (HTTP " + base::NumberToString(status) + ")");
    return;
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::TaskPriority::BEST_EFFORT},
      base::BindOnce(
          [](std::string text, std::string source) {
            return CompileEasyList(text, source);
          },
          std::move(*body), source),
      base::BindOnce(&FilterListUpdater::OnCompiled,
                     weak_factory_.GetWeakPtr()));
}

void FilterListUpdater::OnCompiled(CompiledFilterList list) {
  compiled_by_index_[fetch_index_] = std::move(list);
  fetch_index_++;
  FetchNext();
}

void FilterListUpdater::BeginMergeOrRefetchMissing() {
  size_t have_body = 0;
  for (const auto& compiled : compiled_by_index_) {
    if (compiled) {
      have_body++;
    }
  }
  if (have_body == urls_.size()) {
    std::vector<CompiledFilterList> fetched;
    fetched.reserve(compiled_by_index_.size());
    for (auto& compiled : compiled_by_index_) {
      fetched.push_back(std::move(*compiled));
    }
    compiled_by_index_.clear();
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::TaskPriority::BEST_EFFORT},
        base::BindOnce(
            [](std::vector<CompiledFilterList> fetched,
               int64_t now) -> CompiledFilterList {
              CompiledFilterList merged =
                  MergeCompiledFilterLists(fetched, "easylist+easyprivacy");
              merged.generated_at = base::NumberToString(now);
              return merged;
            },
            std::move(fetched), NowUnixSeconds()),
        base::BindOnce(&FilterListUpdater::OnMerged,
                       weak_factory_.GetWeakPtr()));
    return;
  }
  if (have_body == 0) {
    if (FilterListMatcher::GetInstance()->compiled_host_count() > 0) {
      OnNotModified();
      return;
    }
    if (!skip_validators_) {
      skip_validators_ = true;
      fetch_index_ = 0;
      FetchNext();
      return;
    }
    Finish(false, "empty 304 without cache");
    return;
  }
  if (!skip_validators_) {
    skip_validators_ = true;
    fetch_index_ = 0;
    FetchNext();
    return;
  }
  Finish(false, "incomplete fetch");
}

void FilterListUpdater::OnMerged(CompiledFilterList merged) {
  Persist(merged);
  ApplyList(std::move(merged));
  BumpGeneration();
  LOG(INFO) << "Aegis: filter list compiled and saved, hosts="
            << FilterListMatcher::GetInstance()->compiled_host_count();
  Finish(true, std::string());
}

void FilterListUpdater::OnNotModified() {
  LOG(INFO) << "Aegis: filter list not modified, keep cache, hosts="
            << FilterListMatcher::GetInstance()->compiled_host_count();
  Finish(true, std::string());
}

void FilterListUpdater::Finish(bool ok, const std::string& error) {
  updating_ = false;
  loader_.reset();
  if (prefs_) {
    prefs_->SetInt64(prefs::kFilterListLastAttempt, NowUnixSeconds());
    prefs_->SetString(prefs::kFilterListLastError, error);
    if (ok) {
      prefs_->SetInt64(prefs::kFilterListLastUpdated, NowUnixSeconds());
    }
  }
  if (!ok) {
    LOG(WARNING) << "Aegis: filter list update failed: " << error;
  }
  if (pending_) {
    std::move(pending_).Run(ok);
  }
  if (ok) {
    ScheduleNextAutoUpdate(base::Seconds(kAutoUpdateIntervalSeconds));
  } else {
    ScheduleNextAutoUpdate(base::Seconds(kRetryAfterFailureSeconds));
  }
}

void FilterListUpdater::ApplyList(CompiledFilterList list) {
  if (prefs_) {
    prefs_->SetInteger(
        prefs::kFilterListHostCount,
        static_cast<int>(list.hosts.size() + list.path_rules.size()));
  }
  FilterListMatcher::GetInstance()->ReplaceCompiledList(std::move(list));
}

void FilterListUpdater::Persist(const CompiledFilterList& list) {
  const base::FilePath path = CompiledPath(profile_);
  base::ThreadPool::PostTask(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
      base::BindOnce(
          [](base::FilePath path, CompiledFilterList list) {
            if (!base::CreateDirectory(path.DirName())) {
              return;
            }
            base::ImportantFileWriter::WriteFileAtomically(
                path, CompiledFilterListToJson(list));
          },
          path, list));
}

void FilterListUpdater::BumpGeneration() {
  if (!prefs_) {
    return;
  }
  prefs_->SetInteger(prefs::kFilterListGeneration,
                     prefs_->GetInteger(prefs::kFilterListGeneration) + 1);
}

}  // namespace aegis
