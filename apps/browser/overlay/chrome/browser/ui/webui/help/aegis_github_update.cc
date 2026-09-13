// Copyright 2026 GCSA
#include "chrome/browser/ui/webui/help/aegis_github_update.h"

#include <algorithm>
#include <array>
#include <utility>

#include "base/files/file.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/task/bind_post_task.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/values.h"
#include "base/version.h"
#include "build/build_config.h"
#include "components/services/quarantine/quarantine.h"
#include "crypto/hash.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "net/url_request/redirect_info.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/shared_url_loader_factory.h"
#include "services/network/public/cpp/simple_url_loader.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

#if BUILDFLAG(IS_WIN)
#include <windows.h>
#endif

namespace aegis {
namespace {
ProductUpdateStatus& MutableProductUpdateStatus() {
  static base::NoDestructor<ProductUpdateStatus> status;
  return *status;
}
uint64_t& LatestRequestId() {
  static uint64_t id = 0;
  return id;
}
std::string Text(std::string_view locale,
                 std::string_view en,
                 std::string_view cn,
                 std::string_view tw) {
  return std::string(locale.starts_with("zh-TW") || locale.starts_with("zh-HK")
                         ? tw
                     : locale.starts_with("zh") ? cn
                                                : en);
}
constexpr int64_t kMaxPackageBytes = 2LL * 1024 * 1024 * 1024;
constexpr net::NetworkTrafficAnnotationTag kAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_github_product_update", R"(
      semantics {
        sender: "GCSA Aegis"
        description: "Checks the official GitHub release and downloads a newer platform installer with SHA-256 verification. Does not execute installers."
        trigger: "Opening About or pressing Check again."
        data: "Public release URL. No cookies, credentials or browsing history."
        destination: WEBSITE
        internal { contacts { email: "aegis@gcsa.local" } }
        user_data { type: NONE }
        last_reviewed: "2026-09-13"
      }
      policy {
        cookies_allowed: NO
        setting: "Only runs while the user has opened the About page."
        policy_exception_justification: "Not implemented."
      })");

std::unique_ptr<network::SimpleURLLoader> MakeLoader(const GURL& url) {
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = url;
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->load_flags = net::LOAD_DISABLE_CACHE;
  request->headers.SetHeader("Accept", url == GURL(kReleaseAPI)
                                           ? "application/vnd.github+json"
                                           : "application/octet-stream");
  request->headers.SetHeader("User-Agent", "GCSA-aegis-Updater");
  auto loader =
      network::SimpleURLLoader::Create(std::move(request), kAnnotation);
  return loader;
}

bool ValidProductVersion(std::string_view text) {
  const base::Version version(text);
  return version.IsValid() && version.components().size() == 4 &&
         version.GetString() == text;
}
}  // namespace

ReleaseResult ParseGitHubRelease(std::string_view json,
                                 std::string_view current_version,
                                 std::string_view platform) {
  ReleaseResult result;
  auto release = base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!release || !ValidProductVersion(current_version) ||
      release->FindBool("draft") != false ||
      release->FindBool("prerelease") != false) {
    return result;
  }
  const auto* tag = release->FindString("tag_name");
  if (!tag || !base::StartsWith(*tag, "v") ||
      !ValidProductVersion(std::string_view(*tag).substr(1))) {
    return result;
  }
  const std::string version = tag->substr(1);
  const int comparison =
      base::Version(version).CompareTo(base::Version(current_version));
  if (comparison <= 0) {
    result.state =
        comparison == 0 ? ReleaseState::kCurrent : ReleaseState::kLocalNewer;
    return result;
  }
  const auto* assets = release->FindList("assets");
  if (!assets || platform.empty()) {
    result.state = ReleaseState::kMissingAsset;
    return result;
  }
  const std::string name =
      "GCSA-aegis-" + version + "-" + std::string(platform);
  const std::string url =
      "https://github.com/gcsagroup/aegis-browser/releases/download/" + *tag +
      "/" + name;
  result.state = ReleaseState::kMissingAsset;
  for (const auto& item : *assets) {
    const auto* asset = item.GetIfDict();
    if (!asset || !asset->FindString("name") ||
        *asset->FindString("name") != name) {
      continue;
    }
    // 同名重复资产或元数据缺失时失败，不猜测下载目标。
    if (result.state == ReleaseState::kAvailable) {
      return {};
    }
    const auto* download = asset->FindString("browser_download_url");
    const auto* digest = asset->FindString("digest");
    const auto size = asset->FindDouble("size");
    const auto* state = asset->FindString("state");
    if (!download || *download != url || !digest || digest->size() != 71 ||
        !base::StartsWith(*digest, "sha256:") || !size || *size <= 0 ||
        *size > kMaxPackageBytes || *size != static_cast<int64_t>(*size) ||
        !state || *state != "uploaded") {
      return {};
    }
    const std::string hash = digest->substr(7);
    for (char c : hash) {
      if (!base::IsHexDigit(c)) {
        return {};
      }
    }
    result.state = ReleaseState::kAvailable;
    result.asset = {version, name, GURL(url), base::ToLowerASCII(hash),
                    static_cast<int64_t>(*size)};
  }
  return result;
}

bool IsAllowedReleaseDownloadURL(const GURL& url) {
  return url.is_valid() && url.SchemeIs("https") && !url.has_username() &&
         !url.has_password() && url.EffectiveIntPort() == 443 &&
         (url.host() == "github.com" ||
          url.host() == "release-assets.githubusercontent.com" ||
          url.host() == "objects.githubusercontent.com");
}

std::string GitHubUpdatePlatform() {
#if defined(ARCH_CPU_ARM64)
  const std::string cpu = "arm64";
#elif defined(ARCH_CPU_X86_64)
  const std::string cpu = "x64";
#else
  const std::string cpu;
  return {};
#endif
#if BUILDFLAG(IS_MAC)
  return "mac-" + cpu + ".dmg";
#elif BUILDFLAG(IS_WIN)
  return "win-" + cpu + ".exe";
#elif BUILDFLAG(IS_LINUX)
  return "linux-" + cpu + ".tar.xz";
#else
  return {};
#endif
}

base::FilePath StageVerifiedRelease(base::FilePath temporary_file,
                                    const ReleaseAsset& asset,
                                    const base::FilePath& downloads) {
  // 文件名来自固定匹配的 Release；此处仍独立拒绝路径穿越。
  base::FilePath name = base::FilePath::FromUTF8Unsafe(asset.name);
  base::File file(temporary_file,
                  base::File::FLAG_OPEN | base::File::FLAG_READ);
  std::array<uint8_t, crypto::hash::kSha256Size> digest;
  bool valid = file.IsValid() && !name.empty() && !name.IsAbsolute() &&
               !name.ReferencesParent() && name.BaseName() == name &&
               asset.size > 0 && asset.size <= kMaxPackageBytes &&
               file.GetLength() == asset.size &&
               crypto::hash::HashFile(crypto::hash::kSha256, &file, digest) &&
               base::ToLowerASCII(base::HexEncode(digest)) == asset.sha256;
  file.Close();
  base::ScopedTempDir directory;
  base::FilePath saved;
  if (valid && !downloads.empty() &&
      directory.CreateUniqueTempDirUnderPath(
          downloads, FILE_PATH_LITERAL(".GCSA-update-"))) {
    bool hidden = true;
#if BUILDFLAG(IS_WIN)
    const DWORD attributes =
        ::GetFileAttributesW(directory.GetPath().value().c_str());
    hidden = attributes != INVALID_FILE_ATTRIBUTES &&
             ::SetFileAttributesW(directory.GetPath().value().c_str(),
                                  attributes | FILE_ATTRIBUTE_HIDDEN);
#endif
    auto target = directory.GetPath().Append(name);
    if (hidden && base::Move(temporary_file, target)) {
      saved = target;
      // 将暂存目录的所有权交给后续系统检查；失败时目录自动回收。
      (void)directory.Take();
    }
  }
  if (saved.empty()) {
    base::DeleteFile(temporary_file);
  }
  return saved;
}

namespace {
// 系统检查和发布只依赖已捕获的文件、元数据，不依赖关于页对象存活。
void PublishQuarantinedRelease(base::FilePath staged,
                               base::FilePath downloads,
                               base::OnceCallback<void(base::FilePath)> reply,
                               quarantine::mojom::QuarantineFileResult result) {
  base::ScopedTempDir staging;
  base::ScopedTempDir destination;
  base::FilePath saved;
  if (staging.Set(staged.DirName()) &&
      result == quarantine::mojom::QuarantineFileResult::OK &&
      destination.CreateUniqueTempDirUnderPath(
          downloads, FILE_PATH_LITERAL("GCSA-update-"))) {
    const auto target = destination.GetPath().Append(staged.BaseName());
    // 暂存与交付目录在同一父目录下，移动保留系统来源属性。
    if (base::Move(staged, target)) {
      saved = target;
      (void)destination.Take();
    }
  }
  std::move(reply).Run(saved);
}

void VerifyQuarantineAndPublish(
    base::FilePath temporary_file,
    ReleaseAsset asset,
    base::FilePath downloads,
    base::OnceCallback<void(base::FilePath)> reply) {
  auto staged = StageVerifiedRelease(temporary_file, asset, downloads);
  if (staged.empty()) {
    std::move(reply).Run({});
    return;
  }
  quarantine::QuarantineFile(staged, asset.url, GURL(kReleasePage),
                             std::nullopt, std::string(),
                             base::BindOnce(&PublishQuarantinedRelease, staged,
                                            downloads, std::move(reply)));
}
}  // namespace

GitHubUpdate::GitHubUpdate(
    scoped_refptr<network::SharedURLLoaderFactory> factory,
    base::FilePath downloads,
    std::string platform,
    std::string locale)
    : factory_(std::move(factory)),
      downloads_(std::move(downloads)),
      platform_(std::move(platform)),
      locale_(std::move(locale)) {}
GitHubUpdate::~GitHubUpdate() {
  // 检查与传输随页面销毁取消，不能让概览永久停留在进行中。
  if (request_id_ == LatestRequestId() &&
      (state_ == State::kChecking || state_ == State::kDownloading)) {
    MutableProductUpdateStatus() = {};
  }
}
const ProductUpdateStatus& GetProductUpdateStatus() {
  return MutableProductUpdateStatus();
}

void GitHubUpdate::Report(State state, std::string message, int progress) {
  state_ = state;
  message_ = std::move(message);
  progress_ = progress;
  if (request_id_ == LatestRequestId()) {
    MutableProductUpdateStatus() = {state_, message_, progress_};
  }
  callback_.Run(state_, progress_, message_);
}

void GitHubUpdate::Check(Callback callback) {
  callback_ = std::move(callback);
  if (busy_ || state_ == State::kReady) {
    callback_.Run(state_, progress_, message_);
    return;
  }
  request_id_ = ++LatestRequestId();
  if (platform_.empty() || downloads_.empty()) {
    Report(State::kError,
           Text(locale_,
                "The platform or download folder is unavailable. See versions "
                "and installation instructions.",
                "当前平台或下载目录不可用，请查看版本与安装说明。",
                "目前平台或下載資料夾無法使用，請查看版本與安裝說明。"));
    return;
  }
  busy_ = true;
  Report(State::kChecking, Text(locale_, "Checking for updates…",
                                "正在检查更新…", "正在檢查更新…"));
  loader_ = MakeLoader(GURL(kReleaseAPI));
  loader_->SetTimeoutDuration(base::Seconds(30));
  loader_->SetOnRedirectCallback(base::BindRepeating(
      [](base::WeakPtr<GitHubUpdate> self, const GURL&,
         const net::RedirectInfo&, const network::mojom::URLResponseHead&,
         std::vector<std::string>*) {
        if (self) {
          self->loader_.reset();
          self->busy_ = false;
          self->Report(
              State::kError,
              Text(self->locale_,
                   "The update address redirected unexpectedly. Check stopped.",
                   "更新地址发生意外跳转，已停止检查。",
                   "更新位址發生非預期重新導向，已停止檢查。"));
        }
      },
      weak_factory_.GetWeakPtr()));
  loader_->DownloadToString(
      factory_.get(),
      base::BindOnce(&GitHubUpdate::OnRelease, weak_factory_.GetWeakPtr()),
      1024 * 1024);
}

void GitHubUpdate::OnRelease(std::optional<std::string> body) {
  const int status = loader_->ResponseInfo() && loader_->ResponseInfo()->headers
                         ? loader_->ResponseInfo()->headers->response_code()
                         : 0;
  const int error = loader_->NetError();
  loader_.reset();
  if (status == 404) {
    busy_ = false;
    Report(State::kEmpty,
           Text(locale_, "No official release update is available.",
                "暂无可用的正式版更新。", "暫無可用的正式版更新。"));
    return;
  }
  if (status != 200 || error != net::OK || !body) {
    busy_ = false;
    Report(
        State::kError,
        status == 403 || status == 429
            ? Text(locale_,
                   "Update requests are rate limited. Try again later.",
                   "更新请求受限，请稍后重试。", "更新請求受限，請稍後重試。")
            : Text(locale_,
                   "Could not check for updates. Check your connection and "
                   "retry.",
                   "无法检查更新，请检查网络后重试。",
                   "無法檢查更新，請檢查網路後重試。"));
    return;
  }
  auto result = ParseGitHubRelease(*body, kProductVersion, platform_);
  if (result.state != ReleaseState::kAvailable) {
    busy_ = false;
    if (result.state == ReleaseState::kCurrent) {
      Report(State::kCurrent,
             Text(locale_, "You have the latest official release.",
                  "当前已是最新正式版本。", "目前已是最新正式版本。"));
    } else if (result.state == ReleaseState::kLocalNewer) {
      Report(State::kLocalNewer,
             Text(locale_, "This version is newer than the published release.",
                  "当前版本高于已发布的正式版本。",
                  "目前版本高於已發佈的正式版本。"));
    } else {
      Report(
          State::kError,
          result.state == ReleaseState::kMissingAsset
              ? Text(locale_,
                     "A new version is available, but there is no installer "
                     "for this platform.",
                     "发现新版本，但尚未提供当前平台的安装包。",
                     "發現新版本，但尚未提供目前平台的安裝套件。")
              : Text(
                    locale_,
                    "Invalid release or integrity information. Update stopped.",
                    "发布信息或完整性校验信息无效，已停止更新。",
                    "發佈資訊或完整性驗證資訊無效，已停止更新。"));
    }
    return;
  }
  asset_ = std::move(result.asset);
  Report(State::kDownloading, Text(locale_, "Downloading update…",
                                   "正在下载更新…", "正在下載更新…"));
  loader_ = MakeLoader(asset_.url);
  loader_->SetTimeoutDuration(base::Minutes(30));
  loader_->SetOnRedirectCallback(base::BindRepeating(
      [](base::WeakPtr<GitHubUpdate> self, const GURL&,
         const net::RedirectInfo& redirect,
         const network::mojom::URLResponseHead&, std::vector<std::string>*) {
        if (self && !IsAllowedReleaseDownloadURL(redirect.new_url)) {
          self->loader_.reset();
          self->busy_ = false;
          self->Report(State::kError,
                       Text(self->locale_,
                            "The installer redirected to an untrusted address. "
                            "Download stopped.",
                            "安装包跳转到不受信任的地址，已停止下载。",
                            "安裝套件重新導向至不受信任的位址，已停止下載。"));
        }
      },
      weak_factory_.GetWeakPtr()));
  loader_->SetOnDownloadProgressCallback(base::BindRepeating(
      [](base::WeakPtr<GitHubUpdate> self, uint64_t bytes) {
        if (self) {
          self->Report(State::kDownloading,
                       Text(self->locale_, "Downloading update…",
                            "正在下载更新…", "正在下載更新…"),
                       static_cast<int>(std::min<uint64_t>(
                           99, bytes * 100 / self->asset_.size)));
        }
      },
      weak_factory_.GetWeakPtr()));
  loader_->DownloadToTempFile(
      factory_.get(),
      base::BindOnce(&GitHubUpdate::OnDownloaded, weak_factory_.GetWeakPtr()),
      asset_.size);
}

void GitHubUpdate::OnDownloaded(base::FilePath path) {
  const bool ok = loader_->NetError() == net::OK && loader_->ResponseInfo() &&
                  loader_->ResponseInfo()->headers &&
                  loader_->ResponseInfo()->headers->response_code() == 200;
  loader_.reset();
  if (!ok || path.empty()) {
    busy_ = false;
    if (!path.empty()) {
      base::ThreadPool::PostTask(
          FROM_HERE, {base::MayBlock()},
          base::BindOnce(base::IgnoreResult(&base::DeleteFile), path));
    }
    Report(State::kError,
           Text(locale_,
                "The update download failed or is incomplete. Please retry.",
                "更新包下载失败或不完整，请重试。",
                "更新套件下載失敗或不完整，請重試。"));
    return;
  }
  Report(State::kVerifying,
         Text(locale_, "Verifying the installer…", "正在校验安装包…",
              "正在驗證安裝套件…"),
         99);
  // 完整收尾任务在页面关闭后继续，关机时也先完成文件的安全处理。
  auto task = base::BindOnce(
      &VerifyQuarantineAndPublish, std::move(path), asset_, downloads_,
      base::BindPostTaskToCurrentDefault(base::BindOnce(
          [](base::WeakPtr<GitHubUpdate> self, std::string locale,
             uint64_t request_id, base::FilePath saved) {
            if (self) {
              self->OnSaved(std::move(saved));
              return;
            }
            if (request_id != LatestRequestId()) {
              return;
            }
            MutableProductUpdateStatus() = {
                saved.empty() ? State::kError : State::kReady,
                saved.empty()
                    ? Text(locale, "Installer verification or saving failed.",
                           "安装包校验或保存失败。", "安裝套件驗證或儲存失敗。")
                    : Text(locale,
                           "The installer is ready. Find it in your Downloads "
                           "folder and install it manually.",
                           "安装包已就绪，请到下载文件夹手动安装。",
                           "安裝套件已就緒，請至下載資料夾手動安裝。"),
                100};
          },
          weak_factory_.GetWeakPtr(), locale_, request_id_)));
#if BUILDFLAG(IS_WIN)
  base::ThreadPool::CreateCOMSTATaskRunner(
      {base::MayBlock(), base::TaskShutdownBehavior::BLOCK_SHUTDOWN})
      ->PostTask(FROM_HERE, std::move(task));
#else
  base::ThreadPool::PostTask(
      FROM_HERE, {base::MayBlock(), base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
      std::move(task));
#endif
}

void GitHubUpdate::OnSaved(base::FilePath path) {
  busy_ = false;
  downloaded_file_ = path;
  Report(
      path.empty() ? State::kError : State::kReady,
      path.empty()
          ? Text(locale_,
                 "Installer verification or saving failed. The package was not "
                 "kept.",
                 "安装包校验、系统安全检查或保存失败，未保留更新包。",
                 "安裝套件驗證、系統安全檢查或儲存失敗，未保留更新套件。")
          : Text(locale_, "The installer is ready. Install it manually.",
                 "安装包已就绪，请手动安装。", "安裝套件已就緒，請手動安裝。"));
}
}  // namespace aegis
