// Copyright 2026 GCSA
#include "services/network/aegis/access_private_url_loader_factory.h"

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "services/network/cors/cors_url_loader_factory.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/mojom/aegis_access_route_types.mojom.h"
#include "services/network/public/mojom/early_hints.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "services/network/resource_scheduler/resource_scheduler_client.h"

namespace network {
namespace {
AccessRouteRegistry::Expectation Expected(
    const mojom::AegisAccessRequestEnvelope& envelope) {
  CHECK(envelope.generations);
  const auto& g = *envelope.generations;
  return {envelope.incarnation,
          {g.policy_generation, g.identity_generation, g.selection_generation,
           g.network_epoch, g.base_proxy_config_generation},
          envelope.registration_id};
}
void Reject(mojo::PendingRemote<mojom::URLLoaderClient> pending,
            int error = net::ERR_BLOCKED_BY_CLIENT) {
  if (!pending.is_valid()) return;
  mojo::Remote<mojom::URLLoaderClient> client(std::move(pending));
  client->OnComplete(URLLoaderCompletionStatus(error));
}
}  // namespace

// The standard loader and private control share a lifetime. Only the latter
// can approve a hop; all header and CORS validation still runs in the child.
class AccessPrivateURLLoaderFactory::Request final
    : public mojom::URLLoader,
      public mojom::AegisAccessURLLoaderControl,
      public mojom::URLLoaderClient {
 public:
  Request(std::string token, std::string incarnation,
      scoped_refptr<AccessRequestRouteState> state,
      mojo::PendingReceiver<mojom::URLLoader> loader,
      mojo::PendingReceiver<mojom::AegisAccessURLLoaderControl> control,
      mojo::PendingRemote<mojom::URLLoaderClient> client,
      base::OnceClosure remove)
      : token_(std::move(token)), incarnation_(std::move(incarnation)),
        state_(std::move(state)), client_(std::move(client)),
        loader_receiver_(this, std::move(loader)),
        control_receiver_(this, std::move(control)), remove_(std::move(remove)) {
    auto disconnect = base::BindRepeating(&Request::Cancel, base::Unretained(this));
    loader_receiver_.set_disconnect_handler(disconnect);
    control_receiver_.set_disconnect_handler(disconnect);
    client_.set_disconnect_handler(disconnect);
  }
  mojo::PendingReceiver<mojom::URLLoader> BindInner() {
    auto receiver = inner_.BindNewPipeAndPassReceiver();
    inner_.set_disconnect_handler(
        base::BindOnce(&Request::OnInnerDisconnected, base::Unretained(this)));
    return receiver;
  }
  mojo::PendingRemote<mojom::URLLoaderClient> BindClient() {
    auto client = client_receiver_.BindNewPipeAndPassRemote();
    client_receiver_.set_disconnect_handler(
        base::BindOnce(&Request::Cancel, base::Unretained(this)));
    return client;
  }
  void FollowRedirect(HttpRequestHeadersUpdateParams,
                      const std::optional<GURL>&) override {
    Finish(URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
  }
  void FollowRedirectWithRoute(HttpRequestHeadersUpdateParams headers,
      const std::optional<GURL>& new_url,
      mojom::AegisAccessRequestEnvelopePtr envelope) override {
    if (!inner_.is_bound() || !pending_redirect_ || !envelope || !envelope->generations ||
        envelope->request_token != token_ ||
        envelope->incarnation != incarnation_ ||
        envelope->target != new_url.value_or(pending_redirect_->new_url) ||
        envelope->method != pending_redirect_->new_method ||
        !state_->ApproveRedirect(envelope->hop, envelope->target,
                                 envelope->method, Expected(*envelope))) {
      Finish(URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
      return;
    }
    pending_redirect_.reset();
    inner_->FollowRedirect(std::move(headers), new_url);
  }
  void SetPriority(net::RequestPriority priority, int32_t value) override {
    if (inner_.is_bound()) inner_->SetPriority(priority, value);
  }
  void OnReceiveEarlyHints(mojom::EarlyHintsPtr hints) override {
    client_->OnReceiveEarlyHints(std::move(hints));
  }
  void OnReceiveResponse(mojom::URLResponseHeadPtr head,
      mojo::ScopedDataPipeConsumerHandle body,
      std::optional<mojo_base::BigBuffer> metadata) override {
    client_->OnReceiveResponse(std::move(head), std::move(body), std::move(metadata));
  }
  void OnReceiveRedirect(const net::RedirectInfo& info,
                         mojom::URLResponseHeadPtr head) override {
    if (pending_redirect_) {
      Finish(URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
      return;
    }
    pending_redirect_ = info;
    client_->OnReceiveRedirect(info, std::move(head));
  }
  void OnUploadProgress(int64_t current, int64_t total,
                         OnUploadProgressCallback callback) override {
    client_->OnUploadProgress(current, total, std::move(callback));
  }
  void OnTransferSizeUpdated(int32_t difference) override {
    client_->OnTransferSizeUpdated(difference);
  }
  void OnComplete(const URLLoaderCompletionStatus& status) override {
    Finish(status);
  }
 private:
  void OnInnerDisconnected() {
    // The control pipe can close before a queued OnComplete on the separate
    // client pipe. Preserve that terminal status instead of synthesizing an
    // abort. A broken producer that leaves its client pipe open is bounded.
    inner_.reset();
    completion_watchdog_.Start(FROM_HERE, base::Seconds(5),
        base::BindOnce(&Request::Cancel, base::Unretained(this)));
  }
  void Cancel() { Finish(URLLoaderCompletionStatus(net::ERR_ABORTED)); }
  void Finish(const URLLoaderCompletionStatus& status) {
    client_->OnComplete(status);
    // The owner erases this object; no fields may be touched after Run().
    std::move(remove_).Run();
  }
  const std::string token_;
  const std::string incarnation_;
  const scoped_refptr<AccessRequestRouteState> state_;
  mojo::Remote<mojom::URLLoader> inner_;
  mojo::Remote<mojom::URLLoaderClient> client_;
  mojo::Receiver<mojom::URLLoader> loader_receiver_;
  mojo::Receiver<mojom::AegisAccessURLLoaderControl> control_receiver_;
  mojo::Receiver<mojom::URLLoaderClient> client_receiver_{this};
  std::optional<net::RedirectInfo> pending_redirect_;
  base::OneShotTimer completion_watchdog_;
  base::OnceClosure remove_;
};

AccessPrivateURLLoaderFactory::AccessPrivateURLLoaderFactory(
    NetworkContext* context, mojom::URLLoaderFactoryParamsPtr params,
    scoped_refptr<ResourceSchedulerClient> scheduler,
    const cors::OriginAccessList* origin_access_list,
    base::WeakPtr<AccessRouteRegistry> registry,
    aegis_access::BrowserOwnedRequestMetadata binding, std::string incarnation,
    mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver,
    base::OnceCallback<void(AccessPrivateURLLoaderFactory*)> on_destroy)
    : registry_(std::move(registry)), binding_(std::move(binding)),
      ignore_factory_reset_(params->ignore_factory_reset),
      incarnation_(std::move(incarnation)), on_destroy_(std::move(on_destroy)),
      cors_factory_(std::make_unique<cors::CorsURLLoaderFactory>(context,
          std::move(params), std::move(scheduler), origin_access_list, this)) {
  CHECK(aegis_access::IsCompleteOwner(binding_.owner));
  CHECK(!incarnation_.empty());
  receivers_.Add(this, std::move(receiver));
  receivers_.set_disconnect_handler(base::BindRepeating(
      &AccessPrivateURLLoaderFactory::OnDisconnect, base::Unretained(this)));
}
AccessPrivateURLLoaderFactory::~AccessPrivateURLLoaderFactory() = default;
void AccessPrivateURLLoaderFactory::CreateLoaderAndStartWithRoute(
    mojo::PendingReceiver<mojom::URLLoader> loader,
    mojo::PendingReceiver<mojom::AegisAccessURLLoaderControl> control,
    int32_t request_id, uint32_t options,
    mojom::AegisAccessRoutedRequestPtr request,
    mojo::PendingRemote<mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& annotation) {
  if (!request || !request->envelope || !request->envelope->generations ||
      !loader.is_valid() || !control.is_valid() ||
      request->envelope->request_token.empty() ||
      request->envelope->incarnation != incarnation_ ||
      request->envelope->hop != 0 ||
      request->envelope->target != request->request.url ||
      request->envelope->method != request->request.method ||
      used_tokens_.contains(request->envelope->request_token)) {
    Reject(std::move(client));
    return;
  }
  const std::string token = request->envelope->request_token;
  auto metadata = binding_;
  metadata.request_id = token;
  int route_error = net::ERR_BLOCKED_BY_CLIENT;
  auto state = AccessRequestRouteState::Create(registry_, std::move(metadata),
      request->request.url, request->request.method, Expected(*request->envelope),
      &route_error);
  if (!state) {
    Reject(std::move(client), route_error);
    return;
  }
  used_tokens_.insert(token);
  auto facade = std::make_unique<Request>(token, incarnation_, state,
      std::move(loader), std::move(control), std::move(client),
      base::BindOnce(&AccessPrivateURLLoaderFactory::RemoveRequest,
                     weak_factory_.GetWeakPtr(), token));
  auto inner_receiver = facade->BindInner();
  auto inner_client = facade->BindClient();
  requests_.emplace(token, std::move(facade));
  cors_factory_->CreateLoaderAndStartWithAccessRoute(std::move(inner_receiver),
      request_id, options, request->request, std::move(inner_client), annotation,
      std::move(state));
}
void AccessPrivateURLLoaderFactory::Clone(
    mojo::PendingReceiver<mojom::AegisAccessURLLoaderFactory> receiver) {
  receivers_.Add(this, std::move(receiver));
}
void AccessPrivateURLLoaderFactory::ClearBindings() {
  receivers_.Clear();
  // Active facades and CORS loaders retain this factory until their normal
  // completion/cancellation path; only admission through old receivers ends.
  cors_factory_->DeleteIfNeeded();
}
bool AccessPrivateURLLoaderFactory::HasAdditionalReferences() const {
  return !receivers_.empty() || !requests_.empty();
}
void AccessPrivateURLLoaderFactory::DestroyURLLoaderFactory(
    cors::CorsURLLoaderFactory* factory) {
  CHECK_EQ(factory, cors_factory_.get());
  if (on_destroy_) std::move(on_destroy_).Run(this);
}
void AccessPrivateURLLoaderFactory::RemoveRequest(const std::string& token) {
  requests_.erase(token);
  cors_factory_->DeleteIfNeeded();
}
void AccessPrivateURLLoaderFactory::OnDisconnect() {
  cors_factory_->DeleteIfNeeded();
}
}  // namespace network
