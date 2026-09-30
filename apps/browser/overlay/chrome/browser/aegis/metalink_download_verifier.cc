// Copyright 2026 GCSA

#include "chrome/browser/aegis/metalink_download_verifier.h"

#include <algorithm>
#include <array>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/timer/timer.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/download_request_utils.h"
#include "content/public/browser/storage_partition.h"
#include "content/public/browser/web_contents.h"
#include "crypto/secure_hash.h"
#include "net/base/address_list.h"
#include "net/base/host_port_pair.h"
#include "net/base/net_errors.h"
#include "net/base/network_anonymization_key.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "services/network/public/cpp/simple_host_resolver.h"
#include "services/network/public/mojom/fetch_api.mojom-shared.h"
#include "services/network/public/mojom/host_resolver.mojom.h"
#include "services/network/public/mojom/network_context.mojom.h"

namespace aegis {
namespace {

std::optional<std::string> HashFile(const base::FilePath& path,
                                    const std::string& algorithm) {
  base::File file(path, base::File::FLAG_OPEN | base::File::FLAG_READ);
  if (!file.IsValid()) {
    return std::nullopt;
  }
  std::unique_ptr<crypto::SecureHash> hash = crypto::SecureHash::Create(
      algorithm == "sha-512" ? crypto::SecureHash::SHA512
                             : crypto::SecureHash::SHA256);
  std::array<uint8_t, 64 * 1024> buffer;
  while (true) {
    const std::optional<size_t> bytes_read =
        file.ReadAtCurrentPos(base::span(buffer));
    if (!bytes_read) {
      return std::nullopt;
    }
    if (*bytes_read == 0) {
      break;
    }
    hash->Update(base::span(buffer).first(*bytes_read));
  }
  std::vector<uint8_t> digest(hash->GetHashLength());
  hash->Finish(digest);
  return base::ToLowerASCII(base::HexEncode(digest));
}

bool AllAddressesArePublic(const net::AddressList& addresses) {
  return !addresses.empty() &&
         std::ranges::all_of(addresses, [](const net::IPEndPoint& endpoint) {
           return endpoint.address().IsPubliclyRoutable();
         });
}

class MetalinkVerificationData : public base::SupportsUserData::Data {
 public:
  MetalinkVerificationData(download::DownloadItem& item,
                           MetalinkVerificationStatus status)
      : status(status), item_(&item) {
    // 完成通知期间可能开始哈希校验，不能同步嵌套通知观察者。
    // 状态替换或下载项销毁时，旧数据的弱引用会撤销待发通知。
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&MetalinkVerificationData::Notify,
                                  weak_factory_.GetWeakPtr()));
  }

  MetalinkVerificationStatus status;

 private:
  void Notify() { item_->UpdateObservers(); }

  raw_ptr<download::DownloadItem> item_;
  base::WeakPtrFactory<MetalinkVerificationData> weak_factory_{this};
};

const char kMetalinkVerificationDataKey[] =
    "Aegis Metalink verification status";

class MetalinkDownloadVerifier : public download::DownloadItem::Observer,
                                 public ProfileObserver {
 public:
  MetalinkDownloadVerifier(Profile* profile,
                           content::WebContents* source,
                           MetalinkParseResult result,
                           base::OnceCallback<void(bool, std::string)> callback)
      : profile_(profile),
        source_(source->GetWeakPtr()),
        started_callback_(std::move(callback)),
        result_(std::move(result)),
        host_resolver_(network::SimpleHostResolver::Create(base::BindRepeating(
            [](Profile* profile) {
              return profile->GetDefaultStoragePartition()->GetNetworkContext();
            },
            profile))) {
    profile_->AddObserver(this);
  }

  void Start() { StartNextMirror(); }

  void OnProfileWillBeDestroyed(Profile* profile) override {
    CompleteStart(false, "Metalink profile closed before download started");
    delete this;
  }

  void OnDownloadUpdated(download::DownloadItem* item) override {
    if (item != current_item_) {
      return;
    }
    switch (item->GetState()) {
      case download::DownloadItem::IN_PROGRESS:
        return;
      case download::DownloadItem::COMPLETE: {
        if (hashing_) {
          return;
        }
        hashing_ = true;
        SetMetalinkVerificationStatus(*item,
                                      MetalinkVerificationStatus::kVerifying);
        const base::FilePath path = item->GetTargetFilePath();
        base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
            base::BindOnce(&HashFile, path, result_.hash_algorithm),
            base::BindOnce(&MetalinkDownloadVerifier::OnHashReady,
                           weak_factory_.GetWeakPtr()));
        return;
      }
      case download::DownloadItem::CANCELLED:
        StopObserving();
        delete this;
        return;
      case download::DownloadItem::INTERRUPTED:
        RetryAfterDeleting();
        return;
      case download::DownloadItem::MAX_DOWNLOAD_STATE:
        return;
    }
  }

  void OnDownloadDestroyed(download::DownloadItem* item) override {
    if (item == current_item_) {
      current_item_ = nullptr;
      delete this;
    }
  }

 private:
  ~MetalinkDownloadVerifier() override {
    StopObserving();
    profile_->RemoveObserver(this);
    CompleteStart(false, "Metalink download stopped before task creation");
  }

  void CompleteStart(bool ok, std::string error) {
    if (started_callback_) {
      start_timeout_.Stop();
      std::move(started_callback_).Run(ok, std::move(error));
    }
  }

  void OnStartTimeout() {
    CompleteStart(false, "Metalink download start timed out");
    delete this;
  }

  void StartNextMirror() {
    if (next_mirror_ >= result_.mirrors.size()) {
      CompleteStart(false, "Metalink download has no available public mirror");
      delete this;
      return;
    }
    if (started_callback_ && !start_timeout_.IsRunning()) {
      start_timeout_.Start(
          FROM_HERE, base::Seconds(30),
          base::BindOnce(&MetalinkDownloadVerifier::OnStartTimeout,
                         weak_factory_.GetWeakPtr()));
    }
    const GURL url = result_.mirrors[next_mirror_++].url;
    host_resolver_->ResolveHost(
        network::mojom::HostResolverHost::NewHostPortPair(
            net::HostPortPair::FromURL(url)),
        net::NetworkAnonymizationKey::CreateTransient(), nullptr,
        base::BindOnce(&MetalinkDownloadVerifier::OnHostResolved,
                       weak_factory_.GetWeakPtr(), url));
  }

  void OnHostResolved(
      GURL url,
      int result,
      const net::ResolveErrorInfo& /*resolve_error_info*/,
      const net::AddressList& resolved_addresses,
      const net::HostResolverEndpointResults& /*alternative_endpoints*/) {
    if (!source_) {
      CompleteStart(false,
                    "Metalink source page closed before download started");
      delete this;
      return;
    }
    if (result != net::OK || !AllAddressesArePublic(resolved_addresses)) {
      StartNextMirror();
      return;
    }
    net::NetworkTrafficAnnotationTag annotation =
        net::DefineNetworkTrafficAnnotation("aegis_metalink_download", R"(
          semantics {
            sender: "Aegis Metalink download"
            description:
              "Downloads a user-imported Metalink file from one of its "
              "hash-bound mirrors without site credentials."
            trigger:
              "The user validates a Metalink document and presses Download."
            data: "No cookies, authorization, referrer, or URL userinfo."
            destination: WEBSITE
          }
          policy {
            cookies_allowed: NO
            setting:
              "Only runs after an explicit user action in chrome://aegis."
            policy_exception_justification: "Not implemented."
          })");
    auto parameters =
        content::DownloadRequestUtils::CreateDownloadForWebContentsMainFrame(
            source_.get(), url, annotation);
    parameters->set_has_user_gesture(true);
    parameters->set_credentials_mode(network::mojom::CredentialsMode::kOmit);
    parameters->set_cross_origin_redirects(
        network::mojom::RedirectMode::kError);
    parameters->set_do_not_prompt_for_login(true);
    parameters->set_require_safety_checks(true);
    parameters->set_suggested_name(base::UTF8ToUTF16(result_.file_name));
    parameters->set_callback(
        base::BindOnce(&MetalinkDownloadVerifier::OnDownloadStarted,
                       weak_factory_.GetWeakPtr()));
    // 下载管理器接手后以它的实际回调为准，不能超时销毁校验器后留下无人校验的任务。
    start_timeout_.Stop();
    profile_->GetDownloadManager()->DownloadUrl(std::move(parameters));
  }

  void OnDownloadStarted(download::DownloadItem* item,
                         download::DownloadInterruptReason reason) {
    if (!item || reason != download::DOWNLOAD_INTERRUPT_REASON_NONE) {
      StartNextMirror();
      return;
    }
    current_item_ = item;
    SetMetalinkVerificationStatus(*current_item_,
                                  MetalinkVerificationStatus::kPending);
    current_item_->AddObserver(this);
    CompleteStart(true, "");
    OnDownloadUpdated(current_item_);
  }

  void StopObserving() {
    if (current_item_) {
      current_item_->RemoveObserver(this);
      current_item_ = nullptr;
    }
  }

  void RetryAfterDeleting() {
    download::DownloadItem* failed = current_item_;
    StopObserving();
    // HTTP 错误可能发生在创建临时文件之前，此时没有文件需要清理。
    // DownloadItem::DeleteFile 会返回 false，不能因此阻止备用镜像。
    if (failed->GetFullPath().empty()) {
      StartNextMirror();
      return;
    }
    failed->DeleteFile(base::BindOnce(
        [](base::WeakPtr<MetalinkDownloadVerifier> self, bool deleted) {
          if (!self) {
            return;
          }
          if (deleted) {
            self->StartNextMirror();
          } else {
            delete self.get();
          }
        },
        weak_factory_.GetWeakPtr()));
  }

  void OnHashReady(std::optional<std::string> actual_hash) {
    if (actual_hash && *actual_hash == result_.hash_hex) {
      if (current_item_) {
        SetMetalinkVerificationStatus(*current_item_,
                                      MetalinkVerificationStatus::kVerified);
      }
      delete this;
      return;
    }
    if (!current_item_) {
      delete this;
      return;
    }
    SetMetalinkVerificationStatus(*current_item_,
                                  MetalinkVerificationStatus::kFailed);
    download::DownloadItem* failed = current_item_;
    StopObserving();
    // 原生删除接口同时标记文件已移除，避免下载列表继续显示为可用文件。
    failed->DeleteFile(
        base::BindOnce(&MetalinkDownloadVerifier::OnHashMismatchFileDeleted,
                       weak_factory_.GetWeakPtr()));
  }

  void OnHashMismatchFileDeleted(bool deleted) {
    if (!deleted) {
      delete this;
      return;
    }
    hashing_ = false;
    StartNextMirror();
  }

  raw_ptr<Profile> profile_;
  base::WeakPtr<content::WebContents> source_;
  base::OnceCallback<void(bool, std::string)> started_callback_;
  base::OneShotTimer start_timeout_;
  MetalinkParseResult result_;
  std::unique_ptr<network::SimpleHostResolver> host_resolver_;
  size_t next_mirror_ = 0;
  raw_ptr<download::DownloadItem> current_item_ = nullptr;
  bool hashing_ = false;
  base::WeakPtrFactory<MetalinkDownloadVerifier> weak_factory_{this};
};

}  // namespace

MetalinkVerificationStatus GetMetalinkVerificationStatus(
    const download::DownloadItem& item) {
  const auto* data = static_cast<const MetalinkVerificationData*>(
      item.GetUserData(kMetalinkVerificationDataKey));
  return data ? data->status : MetalinkVerificationStatus::kNone;
}

void SetMetalinkVerificationStatus(download::DownloadItem& item,
                                   MetalinkVerificationStatus status) {
  item.SetUserData(kMetalinkVerificationDataKey,
                   std::make_unique<MetalinkVerificationData>(item, status));
}

void StartVerifiedMetalinkDownload(
    Profile* profile,
    content::WebContents* source,
    MetalinkParseResult result,
    base::OnceCallback<void(bool, std::string)> started_callback) {
  if (!profile || !source || source->GetBrowserContext() != profile ||
      !result.ok || result.mirrors.empty()) {
    std::move(started_callback).Run(false, "invalid Metalink download request");
    return;
  }
  (new MetalinkDownloadVerifier(profile, source, std::move(result),
                                std::move(started_callback)))
      ->Start();
}

}  // namespace aegis
