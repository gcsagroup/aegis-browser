// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxying_url_tracked_request.h"

#include <memory>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/time/time.h"
#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"
#include "chrome/browser/aegis/access/access_request_dispatch_state.h"
#include "content/public/browser/browser_thread.h"
#include "net/base/net_errors.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/mojom/early_hints.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"

namespace aegis::access {
namespace {

constexpr base::TimeDelta kClientCompletionTimeout = base::Seconds(30);

class TrackedRequestTerminationHandle final
    : public aegis_access::RequestTerminationHandle {
 public:
  explicit TrackedRequestTerminationHandle(base::OnceClosure terminate)
      : terminate_(std::move(terminate)) {}
  ~TrackedRequestTerminationHandle() override = default;

  void Terminate() override {
    if (terminate_) {
      std::move(terminate_).Run();
    }
  }

 private:
  base::OnceClosure terminate_;
};

}  // namespace

AccessProxyingURLTrackedRequest::AccessProxyingURLTrackedRequest(
    AccessProxyingURLLoaderFactory* factory,
    AccessRequestDispatchState* dispatch_state,
    aegis_access::RequestOwnershipRecord ownership_record)
    : factory_(factory),
      dispatch_state_(dispatch_state),
      ownership_record_(std::move(ownership_record)) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

AccessProxyingURLTrackedRequest::~AccessProxyingURLTrackedRequest() = default;

base::WeakPtr<AccessProxyingURLTrackedRequest>
AccessProxyingURLTrackedRequest::GetWeakPtr() {
  return weak_factory_.GetWeakPtr();
}

aegis_access::RequestOwnershipStatus
AccessProxyingURLTrackedRequest::MarkDispatched() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto termination = std::make_unique<TrackedRequestTerminationHandle>(
      base::BindOnce(&AccessProxyingURLTrackedRequest::TerminateFromRegistry,
                     GetWeakPtr()));
  return dispatch_state_->ownership().MarkDispatched(
      ownership_record_.request_id, ownership_record_.owner,
      ownership_record_.generations, std::move(termination));
}

void AccessProxyingURLTrackedRequest::Start(
    mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  loader_receiver_.Bind(std::move(loader_receiver));
  target_client_.Bind(std::move(client));
  mojo::PendingRemote<network::mojom::URLLoaderClient> proxy_client =
      client_receiver_.BindNewPipeAndPassRemote();

  loader_receiver_.set_disconnect_handler(base::BindOnce(
      &AccessProxyingURLTrackedRequest::OnBindingError,
      weak_factory_.GetWeakPtr()));
  client_receiver_.set_disconnect_handler(base::BindOnce(
      &AccessProxyingURLTrackedRequest::OnBindingError,
      weak_factory_.GetWeakPtr()));
  target_client_.set_disconnect_handler(base::BindOnce(
      &AccessProxyingURLTrackedRequest::OnBindingError,
      weak_factory_.GetWeakPtr()));

  factory_->StartTargetRequest(
      target_loader_.BindNewPipeAndPassReceiver(), request_id, options, request,
      std::move(proxy_client), traffic_annotation);
  target_loader_.set_disconnect_handler(base::BindOnce(
      &AccessProxyingURLTrackedRequest::OnTargetLoaderDisconnected,
      weak_factory_.GetWeakPtr()));
}

void AccessProxyingURLTrackedRequest::TerminateFromRegistry() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (finished_) {
    return;
  }
  ownership_registered_ = false;
  FailClosed(/*complete_registry=*/false);
}

void AccessProxyingURLTrackedRequest::FollowRedirect(
    network::HttpRequestHeadersUpdateParams headers,
    const std::optional<GURL>& new_url) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (finished_ || !pending_redirect_url_.has_value() ||
      !target_loader_.is_bound()) {
    FailClosed(/*complete_registry=*/true);
    return;
  }

  const GURL follow_url = new_url.value_or(*pending_redirect_url_);
  if (!RebindOwnershipForRedirect(follow_url)) {
    FailClosed(/*complete_registry=*/ownership_registered_);
    return;
  }

  pending_redirect_url_.reset();
  target_loader_->FollowRedirect(std::move(headers), new_url);
}

void AccessProxyingURLTrackedRequest::SetPriority(net::RequestPriority priority,
                                                 int32_t intra_priority_value) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (target_loader_.is_bound()) {
    target_loader_->SetPriority(priority, intra_priority_value);
  }
}

void AccessProxyingURLTrackedRequest::OnReceiveEarlyHints(
    network::mojom::EarlyHintsPtr early_hints) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (target_client_.is_bound()) {
    target_client_->OnReceiveEarlyHints(std::move(early_hints));
  }
}

void AccessProxyingURLTrackedRequest::OnReceiveResponse(
    network::mojom::URLResponseHeadPtr head,
    mojo::ScopedDataPipeConsumerHandle body,
    std::optional<mojo_base::BigBuffer> cached_metadata) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (dispatch_state_->ownership().MarkStreaming(
          ownership_record_.request_id, ownership_record_.owner,
          ownership_record_.generations) !=
      aegis_access::RequestOwnershipStatus::kOk) {
    FailClosed(/*complete_registry=*/true);
    return;
  }
  if (target_client_.is_bound()) {
    target_client_->OnReceiveResponse(std::move(head), std::move(body),
                                      std::move(cached_metadata));
  }
}

void AccessProxyingURLTrackedRequest::OnReceiveRedirect(
    const net::RedirectInfo& redirect_info,
    network::mojom::URLResponseHeadPtr head) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (finished_ || pending_redirect_url_.has_value() ||
      !redirect_info.new_url.is_valid() || !target_client_.is_bound()) {
    FailClosed(/*complete_registry=*/true);
    return;
  }

  pending_redirect_url_ = redirect_info.new_url;
  target_client_->OnReceiveRedirect(redirect_info, std::move(head));
}

void AccessProxyingURLTrackedRequest::OnUploadProgress(
    int64_t current_position,
    int64_t total_size,
    OnUploadProgressCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (target_client_.is_bound()) {
    target_client_->OnUploadProgress(current_position, total_size,
                                     std::move(callback));
  }
}

void AccessProxyingURLTrackedRequest::OnTransferSizeUpdated(
    int32_t transfer_size_diff) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (target_client_.is_bound()) {
    target_client_->OnTransferSizeUpdated(transfer_size_diff);
  }
}

void AccessProxyingURLTrackedRequest::OnComplete(
    const network::URLLoaderCompletionStatus& status) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (target_client_.is_bound()) {
    target_client_->OnComplete(status);
  }
  Finish(/*complete_registry=*/true);
}

bool AccessProxyingURLTrackedRequest::RebindOwnershipForRedirect(
    const GURL& follow_url) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!ownership_registered_) {
    return false;
  }

  const std::string stable_request_id = ownership_record_.request_id;
  const aegis_access::RequestOwnershipTerminalResult completed =
      dispatch_state_->ownership().Complete(
          ownership_record_.request_id, ownership_record_.owner,
          ownership_record_.generations);
  if (completed.status != aegis_access::RequestOwnershipStatus::kOk) {
    return false;
  }
  ownership_registered_ = false;

  int net_error = net::ERR_BLOCKED_BY_CLIENT;
  aegis_access::RequestOwnershipRecord redirected_record;
  const auto disposition = factory_->EvaluateRedirect(
      follow_url, stable_request_id, &net_error, &redirected_record);
  if (disposition !=
      AccessProxyingURLLoaderFactory::RequestDisposition::kDispatchProxy) {
    return false;
  }
  if (redirected_record.request_id != stable_request_id) {
    dispatch_state_->ownership().Complete(
        redirected_record.request_id, redirected_record.owner,
        redirected_record.generations);
    return false;
  }

  ownership_record_ = std::move(redirected_record);
  ownership_registered_ = true;
  if (MarkDispatched() == aegis_access::RequestOwnershipStatus::kOk) {
    return true;
  }

  dispatch_state_->ownership().Complete(
      ownership_record_.request_id, ownership_record_.owner,
      ownership_record_.generations);
  ownership_registered_ = false;
  return false;
}

void AccessProxyingURLTrackedRequest::OnBindingError() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!finished_) {
    target_loader_.reset();
    Finish(/*complete_registry=*/true);
  }
}

void AccessProxyingURLTrackedRequest::OnTargetLoaderDisconnected() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (finished_) {
    return;
  }
  // URLLoader and URLLoaderClient use separate Mojo pipes. The target can
  // close its control pipe after HTTP 200 but before OnComplete is delivered.
  // Keep the relay alive for the client terminal event, with a bound for a
  // target that leaves the client pipe open indefinitely.
  target_loader_.reset();
  client_completion_watchdog_.Start(
      FROM_HERE, kClientCompletionTimeout,
      base::BindOnce(&AccessProxyingURLTrackedRequest::FailClosed,
                     weak_factory_.GetWeakPtr(), /*complete_registry=*/true));
}

void AccessProxyingURLTrackedRequest::FailClosed(bool complete_registry) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (finished_) {
    return;
  }
  target_loader_.reset();
  if (target_client_.is_bound()) {
    target_client_->OnComplete(
        network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
  }
  Finish(complete_registry);
}

void AccessProxyingURLTrackedRequest::Finish(bool complete_registry) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (finished_) {
    return;
  }
  finished_ = true;
  client_completion_watchdog_.Stop();
  if (complete_registry && ownership_registered_) {
    dispatch_state_->ownership().Complete(
        ownership_record_.request_id, ownership_record_.owner,
        ownership_record_.generations);
  }
  ownership_registered_ = false;
  factory_->RemoveRequest(this);
}

}  // namespace aegis::access
