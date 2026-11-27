# Physical iPhone paired probes

These opt-in XCTest cases compare direct and embedded Reality Vision requests on Wi-Fi. The fixed fixture contains 2,051 URL targets from the November 2026 paired campaign. The directed test correlates five diagnostic hosts separately from two content checks. The relay observer records the first visible TLS alert and the first observed EOF independently.

## Prepare the test host

Use a disposable source checkout on a Mac with Xcode, a paired iPhone and the repository's private Alpha device build prerequisites. From the repository root, apply `git apply apps/ios/scripts/paired-probe/device-trace.patch` in that checkout before building the `Aegis-Release` scheme for testing with the embedded core. The patch adds CONNECT instrumentation and the diagnostic LAN usage description to the test host. Use the normal Alpha signing and Firebase inputs for the test device. Grant the test host Local Network access when prompted.

Set `AEGIS_PROBE_XCTESTRUN` to the resulting physical-device `.xctestrun`, `AEGIS_PROBE_DEVICE` to the paired device identifier, and `AEGIS_PROBE_OUTPUT` to a private output directory. For an existing node, set `AEGIS_PROBE_NODE_FILE` to a private file containing one matching Reality Vision share URI. For a temporary comparison node, set `AEGIS_PROBE_XRAY` to the local Xray executable. The comparison runner generates temporary credentials for each invocation.

## Run and inspect

From this directory on the Mac, run `python3 run-device.py` for the full corpus, then `python3 analyze-paired.py <paired-run-directory>` to generate the report and failure inventory. `python3 run-targeted.py --assets-only` runs the Google and GitHub WKWebView resource checks with the configured node.

`python3 run-targeted.py --search-only` requires a completed proxied Google search with the query present, visible external results and a completed navigation after clicking a visible Aegis repository result. It writes the observations even when acceptance fails. The ordinary directed TLS run uses `api.githubcopilot.com` as an HTTPS control. Its HTTP status measures transport reachability. Copilot feature acceptance requires a separate authenticated operation.

Run `python3 local-relay.py` for the five diagnostic hosts on the default US exit. Run `python3 local-relay.py --lan-origin` for a CN IPv4 exit pinned to `en0`. Both expect the iPhone direct control to report CN. The latter queries the LAN resolver for both A and AAAA and dials IPv4. Run `python3 acceptance.py <comparison-run-directory>` to check the recovered phone result against the relay logs. `--mac-only` on the relay script exercises the host-side controls independently. A preflight block contributes zero unexecuted hosts to the failure inventory. Each successful attribution requires a matching client tunnel, Xray inbound and relay target flow.

Keep raw run directories local. The November comparison on upstream `354ba4e1` correlated all ten device observations. The default exit loaded the CSS and decoded the thumbnail. On the physical Ethernet exit the thumbnail connection timed out. Follow-ups are tracked in fork issues #445 through #450.
