// Copyright 2026 GCSA

#include "chrome/browser/aegis/access/access_proxying_url_tracked_request.h"

#include <utility>

#include "chrome/browser/aegis/access/access_proxying_url_loader_factory.h"
#include "chrome/browser/aegis/access/access_request_dispatch_state.h"
#include "content/public/browser/browser_thread.h"
#include "net/base/net_errors.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/url_loader_completion_status.h"

namespace aegis::access {

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
      &AccessProxyingURLTrackedRequest::OnBindingError,
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
    network::HttpRequestHeadersUpdateParams,
    const std::optional<GURL>&) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  FailClosed(/*complete_registry=*/true);
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
    const net::RedirectInfo&,
    network::mojom::URLResponseHeadPtr) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  FailClosed(/*complete_registry=*/true);
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

void AccessProxyingURLTrackedRequest::OnBindingError() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!finished_) {
    target_loader_.reset();
    Finish(/*complete_registry=*/true);
  }
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
  if (complete_registry && ownership_registered_) {
    dispatch_state_->ownership().Complete(
        ownership_record_.request_id, ownership_record_.owner,
        ownership_record_.generations);
  }
  ownership_registered_ = false;
  factory_->RemoveRequest(this);
}

}  // namespace aegis::access
