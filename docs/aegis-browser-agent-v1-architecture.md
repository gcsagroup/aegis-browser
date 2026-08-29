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

Each regular Profile has one instance that owns tasks, plans, model requests, Actors, browser tools, pending approvals, undo credentials, and monitors. OTR, Guest, and System Profiles do not create the service. When Agent is turned off, the service stops model requests, Actors, pending approvals, and scheduled tasks.

### TaskScope and ToolRegistry

TaskScope is the maximum authorization established when a task is created, including exact origins, tabs, tools, data categories, model destinations, and budgets. A model plan can only narrow the scope; it cannot add origins, tools, data, or budget. ToolRegistry uses compile-time schemas, and v1 does not allow the model to register tools.

### Structured model transport

Separate adapters support OpenAI-compatible Responses, Anthropic Messages, and Gemini GenerateContent. Only native structured tool calls are accepted; JSON in natural-language text is not executed. Redirects and cookies are prohibited. Loopback destinations may use HTTP, while cloud destinations must use supported HTTPS endpoints.

### AegisActorBridge

Actor Bridge maps approved page tools to Chromium Actor actions. Every observation is bound to the current DocumentToken and carries an observation fingerprint. The page must be observed again after navigation, recovery, manual page changes, or user takeover. The model cannot see passwords, OTPs, cookies, card numbers, or protected form values.

### Browser-native tools

Native tools cover tabs, windows, workspaces, bookmarks, history, permissions, downloads, and monitoring. Bookmark changes use a preview, revision conflict checks, grouped writes, and one-click undo. URL checks use bounded HEAD and Range GET requests. Downloads are managed through DownloadItem and verified against the source, architecture, and SHA-256.

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

TaskStore uses SQLite within the Profile. Persisted data includes task goals that pass secret marking and length checks, task contracts, redacted event summaries, plan steps and progress, and encrypted monitor targets. Raw tool results, page bodies, screenshots, undo credentials, passwords, OTPs, cookies, card numbers, API keys, and complete local paths must not be persisted. Incomplete tasks are retained for 7 days and terminal tasks for 30 days. The service deletes expired records on startup; if deletion fails, Agent fails closed.

After a crash, a read-only task can be recovered only after user confirmation. Pending actions expire, and external side effects are not replayed automatically. Every recovery requires a new page observation; old nodes and old DocumentTokens are invalid.

Bookmark undo credentials are valid only within the current browser session. The browser does not attempt to replay undo or write operations after a restart.

## Explicitly unsupported

- Automatic payment, final checkout, money transfer, posting, messaging, or acceptance of legal terms.
- Arbitrary JavaScript, shell commands, browser remote debugging, or general-purpose local-file access.
- Unprompted access to passwords, cookies, OTPs, payment cards, or cross-Profile data.
- System-level monitoring that remains resident after the browser closes.
- Treating local test success as proof of public release, production signing, or notarization.
