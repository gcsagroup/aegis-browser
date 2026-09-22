// Copyright 2026 GCSA
#ifndef CHROME_BROWSER_UI_WEBUI_HELP_AEGIS_GITHUB_UPDATE_H_
#define CHROME_BROWSER_UI_WEBUI_HELP_AEGIS_GITHUB_UPDATE_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "url/gurl.h"

namespace network {
class SharedURLLoaderFactory;
class SimpleURLLoader;
} // namespace network

namespace aegis {
// 产品版本独立于 Chromium 内核版本；发布 tag 使用 v2.0.0.40。
inline constexpr char kProductVersion[] = "2.0.0.62";
inline constexpr char kProductVersionLabel[] = "Ver 2.0 (062)";
inline constexpr char kReleaseAPI[] =
    "https://api.github.com/repos/gcsagroup/aegis-browser/releases/latest";
inline constexpr char kReleasePage[] =
    "https://github.com/gcsagroup/aegis-browser/releases";

struct ReleaseAsset {
  std::string version;
  std::string name;
  GURL url;
  std::string sha256;
  int64_t size = 0;
};

enum class ReleaseState {
  kAvailable,
  kCurrent,
  kLocalNewer,
  kInvalid,
  kMissingAsset
};
struct ReleaseResult {
  ReleaseState state = ReleaseState::kInvalid;
  ReleaseAsset asset;
};

// 只接受正式产品版本和唯一的本平台安装包，拒绝源码压缩包及降级。
ReleaseResult ParseGitHubRelease(std::string_view json,
                                 std::string_view current_version,
                                 std::string_view platform);
bool IsAllowedReleaseDownloadURL(const GURL &url);
std::string GitHubUpdatePlatform();
// 校验大小和 SHA-256 后写入隐藏暂存目录；此时仍未对用户交付。
// 无论成功失败都接管并清理临时文件；不执行安装包。
base::FilePath StageVerifiedRelease(base::FilePath temporary_file,
                                    const ReleaseAsset &asset,
                                    const base::FilePath &downloads);

class GitHubUpdate {
public:
  enum class State {
    kUnchecked,
    kChecking,
    kVerifying,
    kDownloading,
    kReady,
    kCurrent,
    kLocalNewer,
    kError,
    kEmpty
  };
  using Callback =
      base::RepeatingCallback<void(State, int, const std::string &)>;
  GitHubUpdate(scoped_refptr<network::SharedURLLoaderFactory> factory,
               base::FilePath downloads, std::string platform,
               std::string locale = "en");
  ~GitHubUpdate();
  void Check(Callback callback);
  base::FilePath GetDownloadedUpdatePath() const { return downloaded_file_; }

private:
  void OnRelease(std::optional<std::string> body);
  void OnDownloaded(base::FilePath path);
  void OnSaved(base::FilePath path);
  void Report(State state, std::string message, int progress = 0);
  scoped_refptr<network::SharedURLLoaderFactory> factory_;
  base::FilePath downloads_;
  std::string platform_;
  std::string locale_;
  Callback callback_;
  std::unique_ptr<network::SimpleURLLoader> loader_;
  ReleaseAsset asset_;
  base::FilePath downloaded_file_;
  State state_ = State::kEmpty;
  std::string message_;
  int progress_ = 0;
  bool busy_ = false;
  uint64_t request_id_ = 0;
  base::WeakPtrFactory<GitHubUpdate> weak_factory_{this};
};
// UI 线程中的最近检查结果；仅用于显示，不启动网络请求。
struct ProductUpdateStatus {
  GitHubUpdate::State state = GitHubUpdate::State::kUnchecked;
  std::string message;
  int progress = 0;
};
const ProductUpdateStatus &GetProductUpdateStatus();
} // namespace aegis
#endif // CHROME_BROWSER_UI_WEBUI_HELP_AEGIS_GITHUB_UPDATE_H_
