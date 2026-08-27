// Copyright 2026 GCSA

#include "chrome/browser/aegis/threat_feed_updater.h"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/strings/string_split.h"
#include "base/task/sequenced_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/browser/after_startup_task_utils.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "net/base/load_flags.h"
#include "net/base/net_errors.h"
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

constexpr char kCertPlUrl[] = "https://hole.cert.pl/domains/v2/domains.txt";
constexpr char kThreatDir[] = "AegisThreatFeeds";
constexpr char kThreatFile[] = "threat-index.bin";
constexpr size_t kMaxCacheBytes = 40 * 1024 * 1024;
constexpr size_t kMaxFeedBytes = 4 * 1024 * 1024;
constexpr size_t kMaxCertEntries = 250'000;
constexpr size_t kMinimumCertEntries = 1'000;
constexpr base::TimeDelta kCertFreshness = base::Hours(2);
constexpr base::TimeDelta kRetryDelay = base::Hours(1);

constexpr net::NetworkTrafficAnnotationTag kTrafficAnnotation =
    net::DefineNetworkTrafficAnnotation("aegis_cert_pl_threat_feed", R"(
      semantics {
        sender: "GCSA-aegis"
        description:
          "Downloads the public CERT.PL warning-list domains used by the "
          "local Aegis phishing reputation index."
        trigger:
          "After startup when the local threat index is missing or expired."
        data: "None. Only the public feed URL is requested."
        destination: WEBSITE
        internal { contacts { email: "aegis@gcsa.local" } }
        user_data { type: NONE }
        last_reviewed: "2026-08-25"
      }
      policy {
        cookies_allowed: NO
        setting: "Disabled when Aegis phishing protection is disabled."
        policy_exception_justification: "Not yet implemented."
      })");

int64_t NowUnixSeconds() {
  return (base::Time::Now() - base::Time::UnixEpoch()).InSeconds();
}

base::FilePath IndexPath(Profile* profile) {
  return profile->GetPath().AppendASCII(kThreatDir).AppendASCII(kThreatFile);
}

std::optional<ThreatIndex> ReadIndex(base::FilePath path) {
  std::string bytes;
  if (!base::ReadFileToStringWithMaxSize(path, &bytes, kMaxCacheBytes)) {
    return std::nullopt;
  }
  return ParseThreatIndex(base::as_byte_span(bytes));
}

std::optional<ThreatIndex> CompileCertFeed(std::string body,
                                           std::optional<ThreatIndex> current,
                                           int64_t now) {
  std::vector<ThreatEntry> entries;
  if (current && now <= current->expires_at) {
    entries.reserve(current->entries.size());
    for (ThreatEntry entry : current->entries) {
      entry.sources &= ~kThreatSourceCertPl;
      if (entry.sources != 0) {
        entries.push_back(std::move(entry));
      }
    }
  }

  size_t accepted = 0;
  size_t rejected = 0;
  for (std::string_view line : base::SplitStringPiece(
           body, "\n", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY)) {
    if (line.starts_with('#')) {
      continue;
    }
    if (accepted >= kMaxCertEntries) {
      return std::nullopt;
    }
    std::optional<ThreatEntry> entry =
        MakeThreatHostEntry(line, kThreatSourceCertPl);
    if (!entry) {
      ++rejected;
      if (rejected > 10) {
        return std::nullopt;
      }
      continue;
    }
    entries.push_back(std::move(*entry));
    ++accepted;
  }
  if (accepted < kMinimumCertEntries) {
    return std::nullopt;
  }

  int64_t expires_at = now + kCertFreshness.InSeconds();
  if (current && now <= current->expires_at) {
    expires_at = std::min(expires_at, current->expires_at);
  }
  return ThreatIndex{.generated_at = now,
                     .expires_at = expires_at,
                     .entries = MergeThreatEntries(std::move(entries))};
}

}  // namespace

ThreatFeedUpdater::ThreatFeedUpdater(Profile* profile) : profile_(profile) {}

ThreatFeedUpdater::~ThreatFeedUpdater() = default;

void ThreatFeedUpdater::LoadFromDisk() {
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
      base::BindOnce(&ReadIndex, IndexPath(profile_)),
      base::BindOnce(&ThreatFeedUpdater::OnLoadedFromDisk,
                     weak_factory_.GetWeakPtr()));
}

std::optional<ThreatMatch> ThreatFeedUpdater::Match(const GURL& url,
                                                    int64_t now) const {
  return index_ ? index_->Match(url, now) : std::nullopt;
}

void ThreatFeedUpdater::OnLoadedFromDisk(std::optional<ThreatIndex> index) {
  if (index) {
    LOG(INFO) << "Aegis: loaded threat reputation index, entries="
              << index->entries.size();
    index_ = std::move(index);
  }
  MaybeUpdate();
}

void ThreatFeedUpdater::MaybeUpdate() {
  timer_.Stop();
  if (updating_) {
    return;
  }
  const int64_t now = NowUnixSeconds();
  if (index_ && now <= index_->expires_at) {
    Schedule(base::Seconds(std::max<int64_t>(60, index_->expires_at - now)));
    return;
  }
  AfterStartupTaskUtils::PostTask(
      FROM_HERE, base::SequencedTaskRunner::GetCurrentDefault(),
      base::BindOnce(&ThreatFeedUpdater::UpdateNow,
                     weak_factory_.GetWeakPtr()));
}

void ThreatFeedUpdater::UpdateNow() {
  if (updating_ || !g_browser_process ||
      !g_browser_process->shared_url_loader_factory()) {
    Schedule(kRetryDelay);
    return;
  }
  updating_ = true;
  auto request = std::make_unique<network::ResourceRequest>();
  request->url = GURL(kCertPlUrl);
  request->credentials_mode = network::mojom::CredentialsMode::kOmit;
  request->redirect_mode = network::mojom::RedirectMode::kError;
  request->load_flags = net::LOAD_BYPASS_CACHE | net::LOAD_DISABLE_CACHE;
  request->priority = net::IDLE;
  loader_ =
      network::SimpleURLLoader::Create(std::move(request), kTrafficAnnotation);
  loader_->SetAllowHttpErrorResults(true);
  loader_->SetRetryOptions(
      2, network::SimpleURLLoader::RetryMode::RETRY_ON_NETWORK_CHANGE);
  loader_->DownloadToString(
      g_browser_process->shared_url_loader_factory().get(),
      base::BindOnce(&ThreatFeedUpdater::OnFetched, weak_factory_.GetWeakPtr()),
      kMaxFeedBytes);
}

void ThreatFeedUpdater::OnFetched(std::optional<std::string> body) {
  const int net_error = loader_ ? loader_->NetError() : net::ERR_FAILED;
  const net::HttpResponseHeaders* headers =
      loader_ && loader_->ResponseInfo()
          ? loader_->ResponseInfo()->headers.get()
          : nullptr;
  const int status = headers ? headers->response_code() : 0;
  loader_.reset();
  if (net_error != net::OK || status != net::HTTP_OK || !body) {
    updating_ = false;
    LOG(WARNING) << "Aegis: CERT.PL threat feed update failed, net="
                 << net_error << " http=" << status;
    Schedule(kRetryDelay);
    return;
  }

  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::TaskPriority::BEST_EFFORT},
      base::BindOnce(&CompileCertFeed, std::move(*body), index_,
                     NowUnixSeconds()),
      base::BindOnce(&ThreatFeedUpdater::OnCompiled,
                     weak_factory_.GetWeakPtr()));
}

void ThreatFeedUpdater::OnCompiled(std::optional<ThreatIndex> index) {
  updating_ = false;
  if (!index) {
    LOG(WARNING) << "Aegis: rejected malformed or undersized CERT.PL feed";
    Schedule(kRetryDelay);
    return;
  }
  Persist(*index);
  LOG(INFO) << "Aegis: updated threat reputation index, entries="
            << index->entries.size();
  index_ = std::move(index);
  MaybeUpdate();
}

void ThreatFeedUpdater::Persist(const ThreatIndex& index) {
  const base::FilePath path = IndexPath(profile_);
  const std::string bytes = SerializeThreatIndex(index);
  if (bytes.empty()) {
    return;
  }
  base::ThreadPool::PostTask(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
      base::BindOnce(
          [](base::FilePath path, std::string bytes) {
            if (base::CreateDirectory(path.DirName())) {
              base::ImportantFileWriter::WriteFileAtomically(path, bytes);
            }
          },
          path, bytes));
}

void ThreatFeedUpdater::Schedule(base::TimeDelta delay) {
  if (delay < base::Minutes(1)) {
    delay = base::Minutes(1);
  }
  if (delay > base::Hours(24)) {
    delay = base::Hours(24);
  }
  timer_.Start(FROM_HERE, delay,
               base::BindOnce(&ThreatFeedUpdater::MaybeUpdate,
                              weak_factory_.GetWeakPtr()));
}

}  // namespace aegis
