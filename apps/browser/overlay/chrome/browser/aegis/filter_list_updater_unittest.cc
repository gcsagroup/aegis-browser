// Copyright 2026 GCSA
// Intended path: chrome/browser/aegis/filter_list_updater_unittest.cc

#include "chrome/browser/aegis/filter_list_updater.h"

#include "net/base/net_errors.h"
#include "net/http/http_response_headers.h"
#include "net/http/http_status_code.h"
#include "services/network/public/cpp/resource_request.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace aegis {

TEST(FilterListHttpValidatorsTest, ReadsNonCoalescingLastModifiedHeader) {
  scoped_refptr<net::HttpResponseHeaders> headers =
      net::HttpResponseHeaders::TryToCreate(
          "HTTP/1.1 200 OK\r\n"
          "ETag: \"fixture-v1\"\r\n"
          "Last-Modified: Wed, 21 Oct 2015 07:28:00 GMT\r\n"
          "\r\n");
  ASSERT_TRUE(headers);

  FilterListHttpValidators validators =
      ExtractFilterListHttpValidators(headers.get());
  ASSERT_TRUE(validators.etag);
  EXPECT_EQ("\"fixture-v1\"", *validators.etag);
  ASSERT_TRUE(validators.last_modified);
  EXPECT_EQ("Wed, 21 Oct 2015 07:28:00 GMT", *validators.last_modified);
}

TEST(FilterListHttpValidatorsTest, HandlesMissingHeadersAndNullResponse) {
  scoped_refptr<net::HttpResponseHeaders> headers =
      net::HttpResponseHeaders::TryToCreate(
          "HTTP/1.1 304 Not Modified\r\n\r\n");
  ASSERT_TRUE(headers);

  FilterListHttpValidators empty =
      ExtractFilterListHttpValidators(headers.get());
  EXPECT_FALSE(empty.etag);
  EXPECT_FALSE(empty.last_modified);

  empty = ExtractFilterListHttpValidators(nullptr);
  EXPECT_FALSE(empty.etag);
  EXPECT_FALSE(empty.last_modified);
}

TEST(FilterListRequestSecurityPolicyTest, RejectsRedirectsAndCredentials) {
  network::ResourceRequest request;
  request.redirect_mode = network::mojom::RedirectMode::kFollow;
  request.credentials_mode = network::mojom::CredentialsMode::kInclude;

  ApplyFilterListRequestSecurityPolicy(&request);

  EXPECT_EQ(network::mojom::RedirectMode::kError, request.redirect_mode);
  EXPECT_EQ(network::mojom::CredentialsMode::kOmit,
            request.credentials_mode);
  ApplyFilterListRequestSecurityPolicy(nullptr);
}

TEST(FilterListHttpValidatorsTest, StagesOnlySuccessfulResponses) {
  EXPECT_TRUE(ShouldStageFilterListHttpValidators(
      net::OK, net::HTTP_OK, /*has_response_body=*/true));
  EXPECT_TRUE(ShouldStageFilterListHttpValidators(
      net::OK, net::HTTP_NOT_MODIFIED, /*has_response_body=*/false));

  EXPECT_FALSE(ShouldStageFilterListHttpValidators(
      net::ERR_FAILED, net::HTTP_OK, /*has_response_body=*/true));
  EXPECT_FALSE(ShouldStageFilterListHttpValidators(
      net::OK, net::HTTP_FOUND, /*has_response_body=*/true));
  EXPECT_FALSE(ShouldStageFilterListHttpValidators(
      net::OK, net::HTTP_INTERNAL_SERVER_ERROR,
      /*has_response_body=*/true));
  EXPECT_FALSE(ShouldStageFilterListHttpValidators(
      net::OK, net::HTTP_OK, /*has_response_body=*/false));
}

TEST(FilterListValidationTest, RequiresAtLeastOneBlockingRule) {
  CompiledFilterList empty;
  EXPECT_FALSE(IsUsableCompiledFilterList(empty));

  CompiledFilterList exception_only;
  exception_only.parsed = 1;
  exception_only.exceptions = {"allowed.example"};
  EXPECT_FALSE(IsUsableCompiledFilterList(exception_only));

  CompiledFilterList host_rule;
  host_rule.parsed = 1;
  host_rule.hosts = {"tracker.example"};
  EXPECT_TRUE(IsUsableCompiledFilterList(host_rule));

  CompiledFilterList path_rule;
  path_rule.parsed = 1;
  path_rule.path_rules = {"tracker.example/pixel"};
  EXPECT_TRUE(IsUsableCompiledFilterList(path_rule));
}

}  // namespace aegis
