**English** | [简体中文](aegis-browser-agent-v1-user-guide.zh-CN.md) | [繁體中文](aegis-browser-agent-v1-user-guide.zh-TW.md)

# Aegis Browser Agent v1 User Guide

## Enable and open Agent

1. Launch the current local macOS candidate normally; no additional feature flag is required.
2. The Agent button appears on the toolbar of a regular Profile and its primary desktop Incognito Profile. It is pinned automatically once when an existing regular Profile is upgraded, and the user can unpin it afterward. Click the button to see the side panel and the enablement prompt.
3. Open `chrome://aegis` and enable the execution master switch in the “Browser Agent” section.
4. Configure the model provider, Base URL, and model name. An API key is optional for a loopback model.
5. Click “Open Agent,” or use the toolbar button, context menu, or `Command+Shift+A`.

Agent entry points are visible by default, but model calls, tool execution, and monitoring remain gated by the settings and task consent of the active Profile.

## Incognito sessions

- The primary desktop Incognito Profile has its own Agent service, current-page summary, toolbar entry, and `chrome://aegis` control plane. It does not reuse the regular Profile's task or event state.
- Incognito tasks, model credentials, monitoring state, and privacy events stay in session memory and are discarded when the Incognito session ends. A cloud-model API key must be supplied for that session and is not copied to or written into the regular Profile.
- Explicitly approved bookmark changes and completed downloads follow Chromium's native Incognito semantics and may remain after the window closes. Closing Incognito cancels active Agent downloads and its active BT transfer, while already-written BT bytes are kept. A BT task survives a settings-page refresh only in the same Profile session and is released at completion so another task can start.
- Because process-wide CDP cannot isolate visible targets by Profile, opening any primary Incognito session stops and blocks every HTTP and pipe “AI Control” transport for the whole process, even one started outside Aegis. It stays off after Incognito closes until you explicitly enable it again in a regular Profile. This does not disable the native Browser Agent.
- Incognito Actor diagnostics redact private URLs, page/task data, targets, and credential identifiers; login-quality records are not uploaded. Incognito monitors do not send system notifications.
- Guest, System, and auxiliary off-the-record Profiles do not expose Agent services, entry points, or Aegis network/fingerprint protection. Learned CNAME aliases are partitioned by exact Profile and cleared with the session.

## Three modes

- Ask: allows read-only tools only and is intended for research, summaries, and checks.
- Act: executes the currently confirmed plan and pauses for exact approval when it reaches an R2 action.
- Automate: may execute low-risk steps continuously within the budget; it never bypasses approval or user takeover.

## Start a task

1. Open the web page you want to work with.
2. Enter the goal in the side panel and review every exact allowed origin line by line.
3. Choose the Research, Browser Steward, Safe Download, or Shopping workflow.
4. Click “Generate plan,” then review the provider, model, data, tools, budget, risk, and every step.
5. After confirmation, click “Start.” You can pause, resume, take over, or stop a task at any time.

Text on a web page such as “ignore the user,” “read cookies,” or “expand the domain list” is only page content, not an Agent instruction.

## Organize bookmarks

Agent first reads a snapshot and generates a preview. Before applying it, Agent checks the tree revision. If you manually change the bookmarks after previewing, the stale plan is rejected due to a conflict. After a successful apply, click “Undo” to restore the original parent nodes, order, titles, and URLs. v1 never deletes bookmarks automatically.

HTTP 401, 403, 429, and timeout results do not directly mark a URL as dead; only definitive results such as 404 and 410 become inactive candidates. Each run checks at most 100 user-selected nodes, with no more than 4 concurrent requests overall and 1 request per origin, plus timeouts and 429 backoff.

## Safe Download

Agent compares the official source, version, platform, architecture, and hash, then starts the download through the browser's native download center. It validates DownloadItem and SHA-256 only after the download completes. A mismatched architecture, malicious redirect, or incorrect hash causes the task to fail. Agent does not bypass system download-security prompts.

## Shopping Assistant

The Shopping workflow shows the merchant, item, quantity, unit price, shipping, tax, discounts, current total, delivery, returns, source-node count, and observation fingerprint. Before final confirmation, Agent observes the page again; a price or page change invalidates the previous confirmation.

Only the user can operate the final purchase button. Agent enters “user takeover,” hides the approval button, and clearly states that you must complete the last step. After completing or abandoning the purchase, return to the side panel to end takeover mode.

## Monitoring

Monitoring works only while the browser is running and supports price, inventory, page-change, and URL-status checks. Monitors can be listed, paused, and deleted; repeated failures trigger backoff. Notifications contain only the monitor type and site origin and do not make purchases or perform other external actions.

## Privacy and troubleshooting

- The side panel shows the scope of the current task; it does not grant browser-wide authorization.
- In a regular Profile, API keys use system-encrypted storage and are never displayed again in the Agent UI. Incognito keys remain only in session memory.
- After a task stops, controlled tabs and Actors are released; no new tool should start within two seconds.
- After an abnormal browser exit, reopening a task requires recovery confirmation. Pending actions are not executed automatically.
- Bookmark undo is valid only in the current browser session; it is not restored and stale writes are not replayed after a restart.
- In a regular Profile, incomplete task metadata is retained for 7 days and completed, failed, canceled, or expired task metadata for 30 days. Incognito TaskStore is memory-only and has no restart recovery. Page bodies and raw tool results are not written to either store.
- Turning off the master switch cancels model calls, Actors, approvals, and monitoring.

If a task fails, first inspect the side-panel timeline and error. Do not try to “fix” it by enabling remote debugging, broadening origins, or giving secrets to the model; those actions are outside the v1 security boundary.
