**English** | [简体中文](aegis-browser-agent-v1-architecture.zh-CN.md) | [繁體中文](aegis-browser-agent-v1-architecture.zh-TW.md)

# Aegis Browser Agent v1 Architecture and Permission Boundaries

## Product role

Aegis Browser Agent is an in-browser task executor, not a chat box with unrestricted browser permissions. After the user provides a goal, Agent first creates a reviewable plan, which the browser then executes and verifies under deterministic policy. The model can propose only structured tool calls. The browser decides whether a tool exists, whether its arguments are valid, whether approval is required, and whether the task has actually completed.

v1 supports macOS desktop. iOS is currently excluded and Android is deferred. v1 does not automatically complete payments, send messages, publish content, or bypass login protections.

## Data flow

```text
User goal
  → Agent Side Panel (Ask / Act / Automate)
  → Profile-scoped AegisAgentService
  → Planner (fixed system contract + minimal tool set)
  → PolicyBroker (scope / risk / budget / approval)
  → Browser Tools or AegisActorBridge
  → ResultVerifier (browser-side postconditions)
  → TaskStore / Timeline / user result
```

Model responses, web-page text, WebMCP results, and tool results are all untrusted inputs. Task state can be changed only by the browser state machine; the model cannot mark a task as successful directly.

## Main components

### AegisAgentService

Each regular Profile and its primary desktop Incognito Profile has a distinct instance that owns tasks, plans, model requests, Actors, browser tools, pending approvals, undo credentials, and monitors. The Incognito instance also supplies its own current-page summary and `chrome://aegis` control plane, so requests and events are routed to the exact owning Profile. Guest, System, and auxiliary OTR Profiles do not create the service. When Agent is turned off, the service stops model requests, Actors, pending approvals, and scheduled tasks.

### TaskScope and ToolRegistry

TaskScope is the maximum authorization established when a task is created, including exact origins, tabs, tools, data categories, model destinations, and budgets. A model plan can only narrow the scope; it cannot add origins, tools, data, or budget. ToolRegistry uses compile-time schemas, and v1 does not allow the model to register tools.

### Structured model transport

Separate adapters support OpenAI-compatible Responses, Anthropic Messages, and Gemini GenerateContent. Only native structured tool calls are accepted; JSON in natural-language text is not executed. Redirects and cookies are prohibited. Loopback destinations may use HTTP, while cloud destinations must use supported HTTPS endpoints.

### AegisActorBridge

Actor Bridge maps approved page tools to Chromium Actor actions. Every observation is bound to the current DocumentToken and carries an observation fingerprint. The page must be observed again after navigation, recovery, manual page changes, or user takeover. The model cannot see passwords, OTPs, cookies, card numbers, or protected form values.

### Browser-native tools

Native tools cover tabs, windows, workspaces, bookmarks, history, permissions, downloads, and monitoring. Incognito history search is limited to navigation entries in the current Incognito session and never redirects to the regular Profile's HistoryService. Bookmark changes use a preview, revision conflict checks, grouped writes, and one-click undo. URL checks use bounded HEAD and Range GET requests. Downloads are managed through DownloadItem and verified against the source, architecture, and SHA-256.

### PolicyBroker and ResultVerifier

Risk levels are:

- R0: read-only; may execute automatically within the approved scope.
- R1: low-risk, locally reversible operations, such as adjusting tabs, workspaces, or monitoring state; constrained by task confirmation.
- R2: persistent browser writes or external side effects, such as applying bookmark organization, downloading a file, or clicking a web page; requires separate approval for the exact action ID.
- R3: user-takeover actions such as a transaction or final submission; Agent cannot complete them on the user's behalf.
- Blocked: attempts to read secrets, execute arbitrary code, use general-purpose CDP, or act outside the scope are rejected directly.

ResultVerifier checks actual browser state. If a postcondition such as download existence, bookmark-tree revision, current DocumentToken, page-observation fingerprint, or checkout amount is not satisfied, the task fails or requires another observation rather than trusting the model's claim of “success.”

## Four built-in workflows

1. Deep Research: multi-source browsing, conflict flags, citations, and unverified items; read-only.
2. Browser Steward: tab and bookmark organization, URL-status checks, and preview/apply/undo.
3. Safe Download: find an official source, match platform and architecture, use the native download path, and verify the hash.
4. Shopping Assistant: compare total price, shipping, tax, delivery, and returns; it may add an item to the cart, but the user completes the final purchase.

Monitoring is scheduled only while the browser is running, with at most 3 concurrent jobs plus backoff and a missed-run cap. It does not open new tabs automatically for background monitoring. Notifications show only the monitor type and origin; they do not contain page text or secrets and provide no button that directly executes an action.

## Persistence and recovery

For a regular Profile, TaskStore uses SQLite within that Profile. Persisted data includes task goals that pass secret marking and length checks, task contracts, redacted event summaries, plan steps and progress, and encrypted monitor targets. Raw tool results, page bodies, screenshots, undo credentials, passwords, OTPs, cookies, card numbers, API keys, and complete local paths must not be persisted. Incomplete tasks are retained for 7 days and terminal tasks for 30 days. The service deletes expired records on startup; if deletion fails, Agent fails closed.

The primary desktop Incognito Profile instead uses a memory-only TaskStore and session-only model credentials, monitor state, privacy events, advanced-download ownership, and learned CNAME aliases. Nothing from that state is written into or recovered through the regular Profile, and closing the Incognito session removes it. Actor journals, diagnostic logs, and traces suppress private URLs, page data, task text, targets, and credential identifiers; Incognito login-quality records are not uploaded. Incognito monitors stay in the in-browser timeline and never post system notifications.

Because process-wide CDP target visibility cannot be isolated by Profile, creating any primary Incognito session immediately stops and blocks every HTTP and pipe remote-debugging transport for the whole process, including a transport started outside Aegis. It stays off after the last Incognito window closes and can be restored only by an explicit enable action in a regular Profile; the native document-bound Agent remains available. Each regular Profile installs this guard during Profile initialization, before its first Browser or renderer exists.

After a crash, a read-only task can be recovered only after user confirmation. Pending actions expire, and external side effects are not replayed automatically. Every recovery requires a new page observation; old nodes and old DocumentTokens are invalid.

Bookmark undo credentials are valid only within the current browser session. The browser does not attempt to replay undo or write operations after a restart.

Explicitly approved bookmark changes and completed downloads retain Chromium's native Incognito persistence semantics and may outlive the Incognito window. They are intentional user-visible effects rather than hidden Agent state. Closing Incognito cancels its active Agent downloads and torrent transfer and revokes all control; already-written torrent bytes are retained. Torrent ownership survives a `chrome://aegis` page refresh only within the same Profile session and can never restore or control another Profile's task.

Guest, System, and auxiliary OTR Profiles receive neither Aegis UI/services nor its network throttle, fingerprint guard, or filter-list configuration. Regular and primary Incognito Profiles use distinct network partition identifiers, so learned CNAME aliases never cross Profile boundaries and are cleared with their owning Profile session.

## Explicitly unsupported

- Automatic payment, final checkout, money transfer, posting, messaging, or acceptance of legal terms.
- Arbitrary JavaScript, shell commands, browser remote debugging, or general-purpose local-file access.
- Process-wide CDP AI Control in Incognito, and all Agent access in Guest, System, or auxiliary OTR Profiles.
- Unprompted access to passwords, cookies, OTPs, payment cards, or cross-Profile data.
- System-level monitoring that remains resident after the browser closes.
- Treating local test success as proof of public release, production signing, or notarization.
