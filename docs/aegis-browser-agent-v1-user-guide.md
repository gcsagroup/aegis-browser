**English** | [简体中文](aegis-browser-agent-v1-user-guide.zh-CN.md) | [繁體中文](aegis-browser-agent-v1-user-guide.zh-TW.md)

# Aegis Browser Agent v1 User Guide

## Enable and open Agent

1. Launch the current local macOS candidate normally; no additional feature flag is required.
2. The Agent button appears on the toolbar of a regular Profile. It is pinned automatically once when an existing Profile is upgraded, and the user can unpin it afterward. Click the button to see the side panel and the enablement prompt.
3. Open `chrome://aegis` and enable the execution master switch in the “Browser Agent” section.
4. Configure the model provider, Base URL, and model name. An API key is optional for a loopback model.
5. Click “Open Agent,” or use the toolbar button, context menu, or `Command+Shift+A`.

Agent entry points are visible by default, but model calls, tool execution, and monitoring remain disabled by default for each Profile and must be enabled explicitly by the user. Incognito, Guest, and System Profiles do not expose usable entry points.

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
- API keys use system-encrypted storage and are never displayed again in the Agent UI.
- After a task stops, controlled tabs and Actors are released; no new tool should start within two seconds.
- After an abnormal browser exit, reopening a task requires recovery confirmation. Pending actions are not executed automatically.
- Bookmark undo is valid only in the current browser session; it is not restored and stale writes are not replayed after a restart.
- Incomplete task metadata is retained for 7 days. Completed, failed, canceled, or expired task metadata is retained for 30 days. Page bodies and raw tool results are not written to TaskStore.
- Turning off the master switch cancels model calls, Actors, approvals, and monitoring.

If a task fails, first inspect the side-panel timeline and error. Do not try to “fix” it by enabling remote debugging, broadening origins, or giving secrets to the model; those actions are outside the v1 security boundary.
