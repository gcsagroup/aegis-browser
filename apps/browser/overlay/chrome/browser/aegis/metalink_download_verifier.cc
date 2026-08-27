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
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/thread_pool.h"
#include "chrome/browser/profiles/profile.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/storage_partition.h"
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

bool DeleteDownloadedFile(const base::FilePath& path) {
  return base::DeleteFile(path);
}

bool AllAddressesArePublic(const net::AddressList& addresses) {
  return !addresses.empty() &&
         std::ranges::all_of(addresses, [](const net::IPEndPoint& endpoint) {
           return endpoint.address().IsPubliclyRoutable();
         });
}

class MetalinkVerificationData : public base::SupportsUserData::Data {
 public:
  explicit MetalinkVerificationData(MetalinkVerificationStatus status)
      : status(status) {}

  MetalinkVerificationStatus status;
};

const char kMetalinkVerificationDataKey[] =
    "Aegis Metalink verification status";

class MetalinkDownloadVerifier : public download::DownloadItem::Observer {
 public:
  MetalinkDownloadVerifier(Profile* profile, MetalinkParseResult result)
      : profile_(profile),
        result_(std::move(result)),
        host_resolver_(network::SimpleHostResolver::Create(base::BindRepeating(
            [](Profile* profile) {
              return profile->GetDefaultStoragePartition()->GetNetworkContext();
            },
            profile))) {}

  void Start() { StartNextMirror(); }

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
                           weak_factory_.GetWeakPtr(), path));
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
  ~MetalinkDownloadVerifier() override { StopObserving(); }

  void StartNextMirror() {
    if (next_mirror_ >= result_.mirrors.size()) {
      delete this;
      return;
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
        std::make_unique<download::DownloadUrlParameters>(url, annotation);
    parameters->set_credentials_mode(network::mojom::CredentialsMode::kOmit);
    parameters->set_cross_origin_redirects(
        network::mojom::RedirectMode::kError);
    parameters->set_do_not_prompt_for_login(true);
    parameters->set_require_safety_checks(true);
    parameters->set_suggested_name(base::UTF8ToUTF16(result_.file_name));
    parameters->set_callback(
        base::BindOnce(&MetalinkDownloadVerifier::OnDownloadStarted,
                       weak_factory_.GetWeakPtr()));
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

  void OnHashReady(const base::FilePath& path,
                   std::optional<std::string> actual_hash) {
    if (actual_hash && *actual_hash == result_.hash_hex) {
      if (current_item_) {
        SetMetalinkVerificationStatus(*current_item_,
                                      MetalinkVerificationStatus::kVerified);
      }
      delete this;
      return;
    }
    if (current_item_) {
      SetMetalinkVerificationStatus(*current_item_,
                                    MetalinkVerificationStatus::kFailed);
    }
    StopObserving();
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
        base::BindOnce(&DeleteDownloadedFile, path),
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
                   std::make_unique<MetalinkVerificationData>(status));
  item.UpdateObservers();
}

void StartVerifiedMetalinkDownload(Profile* profile,
                                   MetalinkParseResult result) {
  if (!profile || !result.ok || result.mirrors.empty()) {
    return;
  }
  (new MetalinkDownloadVerifier(profile, std::move(result)))->Start();
}

}  // namespace aegis
