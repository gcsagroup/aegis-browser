[**English**](aegis-browser-agent-v2-architecture.md) | [简体中文](aegis-browser-agent-v2-architecture.zh-CN.md) | [繁體中文](aegis-browser-agent-v2-architecture.zh-TW.md)

# Aegis Browser Agent v2 architecture and prototype decision

## Decision

Browser Agent v2 stops extending the v1 execution path. It preserves the
profile isolation, policy broker, fixed native tools, approvals, audit trail,
and privacy/phishing assets, while replacing planning and execution with a
browser-owned runtime loop. The selected prototype is **P4, native hybrid**:
the model understands and proposes; Chromium scopes, executes, observes, and
verifies.

The current candidate source is Chromium commit
`383d157c6f3601101038aef6ff964e61b6af7b4f` (tree
`2c509e07ec25fa8811adae17f9826e967c9bcee1`), reconstructed by 106 top-level
patches plus 2 nested V8 patches. This identity describes source, not public
release qualification.

## Product goal

An ordinary user should be able to describe an outcome without opening the
right page, selecting a workflow, or learning browser automation. Aegis must:

1. understand the goal and any named site;
2. decide whether a current page, a direct URL, a site search, or browser-only
   data is needed;
3. create a visible bounded plan;
4. execute one browser-approved tool at a time;
5. observe the resulting browser state and replan when necessary; and
6. report only outcomes verified by the browser.

The model never receives general browser authority and cannot declare a task
successful by itself.

## Runtime flow

```text
Desktop side panel / Android Agent surface
  -> Goal router (native agent.route_goal function)
  -> Browser-owned target resolver and scope builder
  -> Planner (native agent.submit_plan function)
  -> Policy broker (tool, origin, tab, data, budget, risk)
  -> Native browser tool or document-bound Actor action
  -> Observation and postcondition verifier
  -> Next model call, user takeover, or verified completion
  -> Task store, timeline, and readable result
```

### Goal routing

The first model call classifies the goal as research, browser stewardship,
safe download, or shopping, and proposes an entry kind. Chromium then applies
deterministic constraints:

- explicit URLs remain HTTPS targets;
- named sites such as JD, Amazon, GitHub, and YouTube use that site's own HTTPS
  homepage or search URL instead of a generic search engine;
- “this page” resolves to the active public document;
- bookmarks, tabs, and other browser-only tasks do not open a web search; and
- discovery and comparison remain read-only research unless the user clearly
  asks for shopping authority.

### Planning and execution

The planner receives the goal, resolved target, data classes, budgets, and only
the tools already approved by the browser. It must return one strict native
`agent.submit_plan` call. Each execution turn can use only a registered tool
whose schema, risk, tab, origin, document token, and budget all pass policy.
After every action, the runtime feeds a bounded result back to the model and
requires a fresh observation after navigation or user takeover.

### Format recovery

Local and cloud models can produce nearly correct but invalid native function
arguments. v2 permits one browser-authored repair call containing the rejected
schema error. The repair may only correct format; it cannot widen tools,
origins, data, risk, or budgets. If both planning calls fail, Chromium may
construct a minimal fallback only for an allowlisted R0 read-only goal:
page observe/extract, bookmark list/check/preview, download source discovery,
or tab/window metadata. Shopping, writes, forms, and external side effects
never use this fallback.

## Browser-owned guarantees

- One service per regular Profile and a distinct service for its primary desktop
  Incognito Profile; no Agent in Guest, System, or auxiliary OTR Profiles.
- Fixed compile-time tool registry; no model-created tools, arbitrary
  JavaScript, shell, generic CDP, or local-file access.
- Exact tab/origin/document binding. Navigation invalidates stale observations
  and action references.
- Secrets, cookies, OTPs, payment data, protected form values, and API keys are
  excluded from model context, task storage, and build artifacts. Aegis Actor
  journals, diagnostics, and traces suppress private data, while default NetLog
  captures redact `x-api-key` and `x-goog-api-key`. A NetLog capture explicitly
  requested with `kIncludeSensitive` retains Chromium's sensitive-data semantics
  and can contain secrets.
- Regular-Profile model credentials are stored by the browser's credential
  mechanism and scoped to the configured endpoint. Incognito credentials stay
  in session memory. Loopback HTTP is allowed; remote model endpoints require
  supported HTTPS.
- R0 reads can run inside task consent; R1 reversible actions remain bounded;
  R2 writes or external effects require exact action approval; R3 checkout,
  payment, and final submission require user takeover.
- Completion is based on browser postconditions, not model prose.

## Desktop Incognito isolation

The primary desktop Incognito service owns its Agent runtime, current-page
summary, `chrome://aegis` control plane, task state, Actors, and privacy events.
Routing uses the exact owning Profile; the Incognito service neither falls back
to the regular service nor writes into the regular Profile.

Incognito TaskStore, model credentials, automation state, undo credentials,
advanced-download ownership, event history, and learned CNAME aliases are
memory-only and disappear when the Incognito session ends. History search is
limited to navigation entries in that Incognito session. Actor journals,
diagnostic logs, and traces suppress private URLs, page/task data, targets, and
credential identifiers; Incognito login-quality records are not uploaded and
Incognito monitors never post system notifications.

Explicitly approved bookmark changes and completed downloads are the exception:
they retain Chromium's native user-visible persistence semantics and may
outlive the Incognito window. Closing Incognito cancels active Agent downloads
and its torrent transfer, revokes task control, and retains already-written
torrent bytes. Torrent ownership survives a settings-page refresh only within
the same Profile session, is released at terminal status, and never crosses
Profiles.

Because a process-wide CDP endpoint cannot isolate target visibility by
Profile, creating any primary Incognito session immediately stops and blocks
every HTTP and pipe remote-debugging transport for the whole process, including
one started outside Aegis. It remains off after the last Incognito window closes
and can be restored only by an explicit enable action in a regular Profile.
Every regular Profile installs the guard during Profile initialization, before
its first Browser or renderer. This deliberate boundary does not disable the
native, document-bound Agent.

Guest, System, and auxiliary OTR Profiles receive neither Aegis UI/services nor
its network throttle, fingerprint guard, or filter-list configuration. Regular
and primary Incognito Profiles have opaque, distinct network partition IDs, so
learned CNAME aliases never cross a Profile boundary and are removed at Profile
shutdown.

## User surfaces

Desktop regular and primary Incognito Profiles use a visible pinned Agent action
and side panel. Android uses a visible browser entry, a lightweight bottom sheet
for common goals, and the full Agent task surface. Both expose the same goal
model, task timeline, provider/model status, readable recovery messages, and
common scenarios:

- summarize the current page;
- compare products;
- organize bookmarks with a preview and undo;
- check bookmark URLs;
- find an official safe download; and
- research a topic or a named site.

Automations are a separate surface rather than an advanced-mode setting.
Presets cover price, inventory, page changes, and URL health, with explicit
15-minute, hourly, 6-hour, daily, or weekly schedules. They run only while the
browser is available, use bounded retry/backoff, and can be paused or deleted.

## Prototype comparison

| Prototype | Shape | Strength | Blocking limitation | Decision |
|---|---|---|---|---|
| P0 | Prompt-only chat/search | Fastest mock-up | Treats every goal as text/search; no trustworthy execution loop | Reject |
| P1 | External agent over extension/CDP | Easy iteration | Broad authority, weak Profile/document lifetime, poor product integration | Research only |
| P2 | WebMCP/DOM-only agent | Structured page tools | Cannot manage native bookmarks, downloads, tabs, privacy, or phishing state | Component only |
| P3 | Chromium Actor-only agent | Strong page action binding | Does not cover browser-native data and lifecycle by itself | Component only |
| P4 | Native hybrid runtime | Combines model reasoning, Actor actions, and native browser tools under one policy/verifier | Highest integration and cross-platform test cost | **Selected** |

P4 is the smallest design that satisfies “understand, plan, execute, observe,
verify” without turning the model into a privileged remote controller.

## Platform and acceptance boundary

macOS, Windows, and Android must be built from the same candidate source and
recorded with artifact hashes. Android must be installed on the named physical
Pixel device; Windows must be built and exercised on the named Windows host.
iOS is deliberately outside this v2 implementation round.

Acceptance requires real checks for entry discoverability, no-preopened-page
tasks, model planning and one bounded repair, page summary, named-site routing,
bookmarks, downloads, schedules, privacy protection, phishing blocking,
beginner-readable errors, regular/Incognito isolation, credential/data
non-leakage, and exact source/artifact identity. A source build or unit-test
result alone does not satisfy the cross-platform product gate.
