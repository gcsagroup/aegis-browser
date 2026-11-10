// Copyright 2026 GCSA

#ifndef COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_ISOLATION_KEY_CONTRACT_TEST_H_
#define COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_ISOLATION_KEY_CONTRACT_TEST_H_

#include <optional>
#include <set>
#include <string>

#include "net/base/access_route_isolation_key.h"

namespace aegis_access::test {

template <typename Observer>
void RunAccessRouteIsolationKeyContract(Observer& observer) {
  const net::AccessRouteIsolationKey key{
      .channel = 0,
      .profile = "profile-a",
      .partition = "partition-a",
      .group = "group-a",
      .registration = "registration-a",
      .incarnation = "context-a",
      .policy_generation = 11,
      .identity_generation = 12,
      .selection_generation = 13,
      .network_epoch = 14,
      .base_proxy_config_generation = 15};
  observer.Expect(key.IsComplete(), "complete route key is usable");
  observer.Expect(!net::AccessRouteIsolationKey().IsComplete(),
                  "empty route key is not proxy authority");
  std::set<net::AccessRouteIsolationKey> keys{key};
  observer.Expect(!keys.insert(key).second, "equal route identity reuses key");
  auto other = key;
  other.channel = 1;
  observer.Expect(other != key && keys.insert(other).second,
                  "channel changes isolate connections");
  other.channel = 255;
  observer.Expect(!other.IsComplete(), "unknown channel cannot form route key");
  for (auto member : {&net::AccessRouteIsolationKey::profile,
                      &net::AccessRouteIsolationKey::partition,
                      &net::AccessRouteIsolationKey::group,
                      &net::AccessRouteIsolationKey::registration,
                      &net::AccessRouteIsolationKey::incarnation}) {
    other = key;
    other.*member += "-new";
    observer.Expect(other != key && keys.insert(other).second,
                    "each owner/registration/incarnation field isolates reuse");
    (other.*member).clear();
    observer.Expect(!other.IsComplete(), "missing identity is not usable");
  }
  for (auto member : {&net::AccessRouteIsolationKey::policy_generation,
                      &net::AccessRouteIsolationKey::identity_generation,
                      &net::AccessRouteIsolationKey::selection_generation,
                      &net::AccessRouteIsolationKey::network_epoch,
                      &net::AccessRouteIsolationKey::base_proxy_config_generation}) {
    other = key;
    ++(other.*member);
    observer.Expect(other != key && keys.insert(other).second,
                    "every generation independently isolates reuse");
    other.*member = 0;
    observer.Expect(!other.IsComplete(), "zero generation is not usable");
  }
  observer.Expect(keys.size() == 12, "all eleven independent changes stay distinct");
  auto left = key;
  auto right = key;
  left.profile = "a:b";
  left.partition = "c";
  right.profile = "a";
  right.partition = "b:c";
  observer.Expect(left != right, "identity cannot collide through delimiters");
  const std::optional<net::AccessRouteIsolationKey> native;
  observer.Expect(native != std::optional(key),
                  "native pooling is separate from constrained pooling");
}

}  // namespace aegis_access::test

#endif  // COMPONENTS_AEGIS_ACCESS_ACCESS_ROUTE_ISOLATION_KEY_CONTRACT_TEST_H_
