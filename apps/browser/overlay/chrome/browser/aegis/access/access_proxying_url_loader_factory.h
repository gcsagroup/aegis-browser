// Copyright 2026 GCSA

#ifndef CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_LOADER_FACTORY_H_
#define CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_LOADER_FACTORY_H_

#include <cstdint>
#include <memory>
#include <optional>
#include <set>
#include <string>

#include "base/containers/unique_ptr_adapters.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "chrome/browser/aegis/access/access_browser_request_adapter.h"
#include "components/aegis_access/request_policy_context.h"
#include "content/public/browser/frame_tree_node_id.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"

class GURL;
class Profile;

namespace content {
class RenderFrameHost;
class StoragePartition;
}

namespace aegis::access {

class AccessPublishedRequestRuntime;
class AccessProxyingURLTrackedRequest;

// UI-thread browser-process URLLoaderFactory wrapper for real Access request
// dispatch. It covers primary-page document subresources, primary-page
// main-frame/subframe navigation, Worker main-script factories, frame-owned
// Worker subresource factories, frame-less Worker subresource factories,
// process-backed ServiceWorker subresource plus main/imported-script factories,
// frame-backed renderer prefetch factories, and LoadingPredictor browser-process
// prefetch bound to the Profile default StoragePartition. Browser-owned
// Profile-only process/partition attribution and redirect follow re-evaluation
// remain bound to one stable logical request identity. Search/browser-process
// prefetch outside LoadingPredictor, explicit ServiceWorker update-check,
// preconnect,
// WebSocket, BFCache, and prerender remain later slices.
// Each request is re-evaluated from its browser-owned attribution source and the
// latest published Access state
// before it may reach the target Network Service factory.
//
// DIRECT/absent policy is forwarded unchanged. A PROXY decision is forwarded
// only after exact-host endpoint validation and the synchronous dispatch gate.
// Navigation uses a browser-owned pending-navigation token and derives the
// destination top-level site from the request URL rather than borrowing the
// previously committed document identity.
class AccessProxyingURLLoaderFactory : public network::mojom::URLLoaderFactory {
 public:
  using DisconnectCallback =
      base::OnceCallback<void(AccessProxyingURLLoaderFactory*)>;

  AccessProxyingURLLoaderFactory(
      Profile* profile,
      content::FrameTreeNodeId frame_tree_node_id,
      std::optional<int64_t> navigation_id,
      std::optional<int> profile_only_render_process_id,
      content::StoragePartition* profile_only_storage_partition,
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
  static void MaybeProxyWorkerMainResource(
      Profile* profile,
      content::RenderFrameHost* frame,
      network::URLLoaderFactoryBuilder& factory_builder);
  static void MaybeProxyWorkerSubResource(
      Profile* profile,
      content::RenderFrameHost* frame,
      int render_process_id,
      network::URLLoaderFactoryBuilder& factory_builder);
  static void MaybeProxyServiceWorkerSubResource(
      Profile* profile,
      int render_process_id,
      network::URLLoaderFactoryBuilder& factory_builder);
  static void MaybeProxyServiceWorkerScript(
      Profile* profile,
      int render_process_id,
      network::URLLoaderFactoryBuilder& factory_builder);
  static void MaybeProxyPrefetch(
      Profile* profile,
      content::RenderFrameHost* frame,
      network::URLLoaderFactoryBuilder& factory_builder);
  static void MaybeProxyBrowserProcessPrefetch(
      Profile* profile,
      content::StoragePartition* partition,
      network::URLLoaderFactoryBuilder& factory_builder);
  static void MaybeProxyNavigation(
      Profile* profile,
      content::RenderFrameHost* frame,
      int64_t navigation_id,
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
  friend class AccessProxyingURLTrackedRequest;

  enum class RequestDisposition {
    kPreserveNative,
    kDispatchProxy,
    kBlock,
  };

  RequestDisposition EvaluateRequest(
      const network::ResourceRequest& request,
      int* net_error,
      aegis_access::RequestOwnershipRecord* ownership_record);
  RequestDisposition EvaluateRedirect(
      const GURL& redirect_url,
      const std::string& stable_request_id,
      int* net_error,
      aegis_access::RequestOwnershipRecord* ownership_record);
  AccessBrowserRequestMetadataResult CaptureCurrentMetadata();
  RequestDisposition EvaluateUrl(
      const GURL& request_url,
      const std::optional<std::string>& stable_request_id,
      int* net_error,
      aegis_access::RequestOwnershipRecord* ownership_record);
  RequestDisposition EvaluatePreparedMetadata(
      const GURL& request_url,
      AccessPublishedRequestRuntime* runtime,
      aegis_access::BrowserOwnedRequestMetadata metadata,
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
  void StartTargetRequest(
      mojo::PendingReceiver<network::mojom::URLLoader> loader_receiver,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& traffic_annotation);
  void RemoveRequest(AccessProxyingURLTrackedRequest* request);
  void OnTargetFactoryError();
  void OnProxyBindingError();
  void MaybeDestroySelf();

  const raw_ptr<Profile> profile_;
  const content::FrameTreeNodeId frame_tree_node_id_;
  const std::optional<int64_t> navigation_id_;
  const std::optional<int> profile_only_render_process_id_;
  const raw_ptr<content::StoragePartition> profile_only_storage_partition_;
  const aegis_access::BrowserOwnedRequestMetadata factory_metadata_;

  mojo::ReceiverSet<network::mojom::URLLoaderFactory> proxy_receivers_;
  std::set<std::unique_ptr<AccessProxyingURLTrackedRequest>,
           base::UniquePtrComparator>
      requests_;
  mojo::Remote<network::mojom::URLLoaderFactory> target_factory_;
  DisconnectCallback on_disconnect_;
};

}  // namespace aegis::access

#endif  // CHROME_BROWSER_AEGIS_ACCESS_ACCESS_PROXYING_URL_LOADER_FACTORY_H_
