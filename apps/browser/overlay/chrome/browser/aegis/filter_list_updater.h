// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/filter_list_updater.h

#ifndef CHROME_BROWSER_AEGIS_FILTER_LIST_UPDATER_H_
#define CHROME_BROWSER_AEGIS_FILTER_LIST_UPDATER_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "chrome/common/aegis/filter_list.h"

class PrefService;
class Profile;

namespace net {
class HttpResponseHeaders;
}

namespace network {
class SimpleURLLoader;
struct ResourceRequest;
}

namespace aegis {

// Downloads EasyList/EasyPrivacy, compiles host tables, persists them under
// the profile dir, and publishes them to FilterListMatcher.
//
// 更新策略：
// - 启动先读 compiled.json，立刻用于拦截。
// - 缓存未满 24h：不联网，到点再后台检查。
// - 缓存过期或缺失：窗口起来后条件请求（ETag / Last-Modified）。
// - 远端 304：只刷新时间戳，不重新编译。
// - 失败：继续用旧缓存，1 小时后再试；不删盘上的 compiled.json。
class FilterListUpdater {
 public:
  using UpdateCallback = base::OnceCallback<void(bool ok)>;

  explicit FilterListUpdater(Profile* profile);
  FilterListUpdater(const FilterListUpdater&) = delete;
  FilterListUpdater& operator=(const FilterListUpdater&) = delete;
  ~FilterListUpdater();

  // 读盘后自动调用 MaybeAutoUpdate，避免在缓存尚未加载时误判过期。
  void LoadFromDisk();
  void MaybeAutoUpdate();
  void OnAutoUpdateEnabledChanged();
  void UpdateNow(UpdateCallback callback);

  bool updating() const { return updating_; }

 private:
  struct LoadedCache {
    std::optional<CompiledFilterList> list;
    int64_t file_mtime_unix = 0;
  };

  void FetchNext();
  void OnFetched(std::optional<std::string> body);
  void OnCompiled(CompiledFilterList list);
  void OnLoadedFromDisk(LoadedCache cache);
  void BeginMergeOrRefetchMissing();
  void OnMerged(CompiledFilterList merged);
  void OnNotModified();
  void Finish(bool ok, const std::string& error);
  void ApplyList(CompiledFilterList list);
  void Persist(const CompiledFilterList& list);
  void BumpGeneration();
  void RememberValidators(const std::string& url,
                          const net::HttpResponseHeaders* headers);
  void AttachValidators(network::ResourceRequest* request);
  void ScheduleNextAutoUpdate(base::TimeDelta delay);
  void OnScheduledRefresh();

  raw_ptr<Profile> profile_;
  raw_ptr<PrefService> prefs_;
  bool updating_ = false;
  bool skip_validators_ = false;
  size_t fetch_index_ = 0;
  std::vector<std::string> urls_;
  std::vector<std::optional<CompiledFilterList>> compiled_by_index_;
  UpdateCallback pending_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  base::OneShotTimer refresh_timer_;
  base::WeakPtrFactory<FilterListUpdater> weak_factory_{this};
};

}  // namespace aegis

#endif  // CHROME_BROWSER_AEGIS_FILTER_LIST_UPDATER_H_
