# macOS SOCKS5 inbound (no authentication)

## Scope

- Admit `RegisteredProxyTransport::kSocks5` for numeric-loopback ProxyInfo
- SOCKS5 no-auth greeting + CONNECT parser (RFC 1928 subset)
- Reject username/password-only greetings, BIND, and UDP ASSOCIATE

## Non-goals

- Username/password auth
- Full managed proxy runtime process lifecycle
- Upstream merge (opened later as a promotion PR without merging)

## Relation to iOS

Mirrors the iOS AccessKit no-auth SOCKS5 inbound contract so both ends share
the same admission rules before an upstream promotion PR.
