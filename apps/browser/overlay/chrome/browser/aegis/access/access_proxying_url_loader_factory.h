// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_LOADER_FACTORY_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_LOADER_FACTORY_H_

#include <memory>
#include <set>

#include "base/containers/unique_ptr_adapters.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "components/aegis_access/request_policy_context.h"
#include "content/public/browser/frame_tree_node_id.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"

class Profile;

namespace content {
class RenderFrameHost;
}

namespace aegis::access {

// UI-thread browser-process URLLoaderFactory wrapper for the first real Access
// request vertical slice. It covers primary-page document subresources only.
// Nested-frame, navigation, worker, and WebSocket surfaces are later slices. Each
// request is
// re-evaluated from browser-owned frame state and the latest published Access
// state before it may reach the target Network Service factory.
//
// DIRECT/absent policy is forwarded unchanged. A PROXY decision is forwarded
// only after exact-host endpoint validation and the synchronous dispatch gate.
// Navigation, workers, WebSocket, and redirect re-evaluation are later slices.
class AccessProxyingURLLoaderFactory : public network::mojom::URLLoaderFactory {
 public:
  using DisconnectCallback =
      base::OnceCallback<void(AccessProxyingURLLoaderFactory*)>;

  AccessProxyingURLLoaderFactory(
      Profile* profile,
      content::FrameTreeNodeId frame_tree_node_id,
      aegis_access::BrowserOwnedRequestMetadata factory_metadata,
      network::URLLoaderFactoryBuilder& factory_builder,
      DisconnectCallback on_disconnect);
  AccessProxyingURLLoaderFactory(const AccessProxyingURLLoaderFactory&) =
      delete;
  AccessProxyingURLLoaderFactory& operator=(
      const AccessProxyingURLLoaderFactory&) = delete;
  ~AccessProxyingURLLoaderFactory() override;

  static void MaybeProxyDocumentSubresource(
      Profile* profile,
      content::RenderFrameHost* frame,
      network::URLLoaderFactoryBuilder& factory_builder);

  // network::mojom::URLLoaderFactory:
  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& traffic_annotation)
      override;
  void Clone(mojo::PendingReceiver<network::mojom::URLLoaderFactory>
                 loader_receiver) override;

 private:
  class TrackedRequest;

  enum class RequestDisposition {
    kPreserveNative,
    kDispatchProxy,
    kBlock,
  };

  RequestDisposition EvaluateRequest(
      const network::ResourceRequest& request,
      int* net_error,
      aegis_access::RequestOwnershipRecord* ownership_record);
  void ForwardNative(
      mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& traffic_annotation);
  static void BlockRequest(
      mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      int net_error);
  void RemoveRequest(TrackedRequest* request);
  void OnTargetFactoryError();
  void OnProxyBindingError();
  void MaybeDestroySelf();

  const raw_ptr<Profile> profile_;
  const content::FrameTreeNodeId frame_tree_node_id_;
  const aegis_access::BrowserOwnedRequestMetadata factory_metadata_;

  mojo::ReceiverSet<network::mojom::URLLoaderFactory> proxy_receivers_;
  std::set<std::unique_ptr<TrackedRequest>, base::UniquePtrComparator>
      requests_;
  mojo::Remote<network::mojom::URLLoaderFactory> target_factory_;
  DisconnectCallback on_disconnect_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_LOADER_FACTORY_H_
