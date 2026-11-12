// Copyright 2026 GCSA
#include "services/network/public/cpp/url_loader_factory_builder.h"

#include "base/functional/bind.h"
#include "base/test/gtest_util.h"
#include "base/test/bind.h"
#include "base/test/task_environment.h"
#include "mojo/core/embedder/embedder.h"
#include "services/network/test/test_network_context.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace network {
namespace {
class AccessTerminalFactoryTest : public testing::Test {
 protected:
  AccessTerminalFactoryTest() { mojo::core::Init(); }
  base::test::SingleThreadTaskEnvironment environment_;
  TestNetworkContext context_;
};

TEST_F(AccessTerminalFactoryTest, PrivateTerminalRequiresFreshFactory) {
  URLLoaderFactoryBuilder builder;
  EXPECT_FALSE(builder.RequiresFreshFactory());
  builder.SetTerminalFactoryInterceptor(base::BindOnce(
      [](mojo::PendingReceiver<mojom::URLLoaderFactory>, mojom::NetworkContext*,
         mojom::URLLoaderFactoryParamsPtr) {}));
  EXPECT_TRUE(builder.RequiresFreshFactory());
  builder.SetTargetNetwork(net::handles::kInvalidNetworkHandle);
  EXPECT_TRUE(builder.RequiresFreshFactory());
}

TEST_F(AccessTerminalFactoryTest, EmptyBuilderPreservesExactSecurityParameters) {
  URLLoaderFactoryBuilder builder;
  auto params = mojom::URLLoaderFactoryParams::New();
  params->is_trusted = false;
  params->request_initiator_origin_lock = url::Origin::Create(GURL("https://a.test"));
  auto* original_params = params.get();
  int calls = 0;
  builder.SetTerminalFactoryInterceptor(base::BindLambdaForTesting(
      [&](mojo::PendingReceiver<mojom::URLLoaderFactory> receiver,
          mojom::NetworkContext* context, mojom::URLLoaderFactoryParamsPtr passed) {
        ++calls;
        EXPECT_TRUE(receiver.is_valid());
        EXPECT_EQ(context, &context_);
        EXPECT_EQ(passed.get(), original_params);
        EXPECT_FALSE(passed->is_trusted);
        EXPECT_EQ(passed->request_initiator_origin_lock,
                  url::Origin::Create(GURL("https://a.test")));
      }));
  auto result = std::move(builder).Finish<mojo::PendingRemote<mojom::URLLoaderFactory>>(
      &context_, std::move(params));
  EXPECT_TRUE(result.is_valid());
  EXPECT_EQ(calls, 1);
}

TEST_F(AccessTerminalFactoryTest, ReceiverFinishPreservesTargetNetwork) {
  URLLoaderFactoryBuilder builder;
  builder.SetTargetNetwork(37);
  int calls = 0;
  builder.SetTerminalFactoryInterceptor(base::BindLambdaForTesting(
      [&](mojo::PendingReceiver<mojom::URLLoaderFactory> receiver,
          mojom::NetworkContext*, mojom::URLLoaderFactoryParamsPtr params) {
        EXPECT_TRUE(receiver.is_valid());
        EXPECT_EQ(params->target_network, 37);
        ++calls;
      }));
  mojo::PendingRemote<mojom::URLLoaderFactory> remote;
  std::move(builder).Finish(remote.InitWithNewPipeAndPassReceiver(), &context_,
                            mojom::URLLoaderFactoryParams::New());
  EXPECT_EQ(calls, 1);
}

TEST_F(AccessTerminalFactoryTest, InterceptorChainRetainsTerminalOverrideAfterMove) {
  URLLoaderFactoryBuilder builder;
  auto [receiver, tail] = builder.Append();
  int calls = 0;
  builder.SetTerminalFactoryInterceptor(base::BindLambdaForTesting(
      [&](mojo::PendingReceiver<mojom::URLLoaderFactory> terminal_receiver,
          mojom::NetworkContext*, mojom::URLLoaderFactoryParamsPtr) {
        EXPECT_TRUE(terminal_receiver.is_valid());
        ++calls;
      }));
  URLLoaderFactoryBuilder moved = std::move(builder);
  EXPECT_EQ(moved.num_interceptors(), 1u);
  EXPECT_TRUE(moved.RequiresFreshFactory());
  auto result = std::move(moved).Finish<mojo::PendingRemote<mojom::URLLoaderFactory>>(
      &context_, mojom::URLLoaderFactoryParams::New());
  EXPECT_TRUE(result.is_valid());
  EXPECT_TRUE(receiver.is_valid());
  EXPECT_TRUE(tail.is_valid());
  EXPECT_EQ(calls, 1);
}

TEST_F(AccessTerminalFactoryTest, RejectsAlreadyCreatedTerminal) {
  EXPECT_CHECK_DEATH({
    URLLoaderFactoryBuilder builder;
    builder.SetTerminalFactoryInterceptor(base::BindOnce(
        [](mojo::PendingReceiver<mojom::URLLoaderFactory>, mojom::NetworkContext*,
           mojom::URLLoaderFactoryParamsPtr) {}));
    mojo::PendingRemote<mojom::URLLoaderFactory> terminal;
    auto receiver = terminal.InitWithNewPipeAndPassReceiver();
    auto result = std::move(builder).Finish(std::move(terminal));
  });
}
}  // namespace
}  // namespace network
