# iOS SOCKS5 inbound (no authentication)

## Scope

- Admit `AccessInboundTransport.socks5` (wire value `3`)
- Loopback SOCKS5 listener with method `0x00` only
- CONNECT command; hold tunnel endpoint without direct dial
- Reject username/password-only greetings
- WebKit `ProxyConfiguration` for SOCKS5 stays fail-closed

## Non-goals

- Username/password auth
- BIND / UDP ASSOCIATE
- macOS browser wiring (follow-up after iOS)

## PBX IDs

`0090`–`0095`
