// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_TRACKED_REQUEST_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_TRACKED_REQUEST_H_

#include <cstdint>
#include <optional>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/timer/timer.h"
#include "components/aegis_access/request_ownership_registry.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "url/gurl.h"

namespace net {
struct MutableNetworkTrafficAnnotationTag;
}

namespace network {
struct ResourceRequest;
}

namespace aegis::access {

class AccessProxyingURLLoaderFactory;
class AccessRequestDispatchState;

// One in-flight proxied URLLoader request. The ownership registry holds a
// one-shot termination callback to this object, allowing a newly installed
// BLOCK barrier to terminate the real Network Service request after dispatch.
class AccessProxyingURLTrackedRequest final
    : public network::mojom::URLLoader,
      public network::mojom::URLLoaderClient {
 public:
  AccessProxyingURLTrackedRequest(
      AccessProxyingURLLoaderFactory* factory,
      AccessRequestDispatchState* dispatch_state,
      aegis_access::RequestOwnershipRecord ownership_record);
  AccessProxyingURLTrackedRequest(const AccessProxyingURLTrackedRequest&) =
      delete;
  AccessProxyingURLTrackedRequest& operator=(
      const AccessProxyingURLTrackedRequest&) = delete;
  ~AccessProxyingURLTrackedRequest() override;

  base::WeakPtr<AccessProxyingURLTrackedRequest> GetWeakPtr();
  aegis_access::RequestOwnershipStatus MarkDispatched();

  void Start(
      mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& traffic_annotation);

  void TerminateFromRegistry();

  // network::mojom::URLLoader:
  void FollowRedirect(network::HttpRequestHeadersUpdateParams,
                      const std::optional<GURL>&) override;
  void SetPriority(net::RequestPriority priority,
                   int32_t intra_priority_value) override;

  // network::mojom::URLLoaderClient:
  void OnReceiveEarlyHints(network::mojom::EarlyHintsPtr early_hints) override;
  void OnReceiveResponse(
      network::mojom::URLResponseHeadPtr head,
      mojo::ScopedDataPipeConsumerHandle body,
      std::optional<mojo_base::BigBuffer> cached_metadata) override;
  void OnReceiveRedirect(const net::RedirectInfo& redirect_info,
                         network::mojom::URLResponseHeadPtr head) override;
  void OnUploadProgress(int64_t current_position,
                        int64_t total_size,
                        OnUploadProgressCallback callback) override;
  void OnTransferSizeUpdated(int32_t transfer_size_diff) override;
  void OnComplete(const network::URLLoaderCompletionStatus& status) override;

 private:
  bool RebindOwnershipForRedirect(const GURL& follow_url);
  void OnBindingError();
  void OnTargetLoaderDisconnected();
  void FailClosed(bool complete_registry);
  void Finish(bool complete_registry);

  const raw_ptr<AccessProxyingURLLoaderFactory> factory_;
  const raw_ptr<AccessRequestDispatchState> dispatch_state_;
  aegis_access::RequestOwnershipRecord ownership_record_;
  std::optional<GURL> pending_redirect_url_;
  bool ownership_registered_ = true;
  bool finished_ = false;

  mojo::Receiver<network::mojom::URLLoader> loader_receiver_{this};
  mojo::Remote<network::mojom::URLLoader> target_loader_;
  mojo::Receiver<network::mojom::URLLoaderClient> client_receiver_{this};
  mojo::Remote<network::mojom::URLLoaderClient> target_client_;
  base::OneShotTimer client_completion_watchdog_;
  base::WeakPtrFactory<AccessProxyingURLTrackedRequest> weak_factory_{this};
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_TRACKED_REQUEST_H_
