**English** | [简体中文](aegis-browser-agent-v2-user-guide.zh-CN.md) | [繁體中文](aegis-browser-agent-v2-user-guide.zh-TW.md)

# Aegis Browser Agent v2 user guide

## The shortest path

1. Click **Agent** in the browser toolbar or main menu. On Android, use the new-tab page or main menu.
2. Describe the outcome directly, for example: “summarize this page,” “find and compare three 32 GB
   memory kits on JD,” or “organize my bookmarks and check dead links.” You do not need to open a page
   first or select a workflow.
3. Click **Start task**. Aegis understands the goal, plans, opens or searches pages, acts, and verifies the
   result. The side panel explains progress in plain language.
4. It pauses only when a risky action—such as a purchase, form submission, or bulk data change—needs
   confirmation. The user always performs the final purchase.

Current-page requests automatically use the active tab. When a request names JD, GitHub, Amazon, or
another supported site, Aegis opens that site's HTTPS destination instead of sending the whole request to
a general search engine.

## Desktop Incognito

- The primary desktop Incognito Profile exposes Agent, current-page summary, the toolbar entry, and the
  `chrome://aegis` control plane through a service isolated from the regular Profile.
- Tasks, model credentials, automation state, and privacy events stay in memory for that Incognito session.
  They are not copied to the regular Profile and cannot be recovered after the Incognito session ends.
- A cloud-model API key must be supplied for the Incognito session. It is never read from or written to the
  regular Profile.
- Explicitly approved bookmark changes and completed downloads follow Chromium's native Incognito semantics
  and may remain after the window closes. Closing Incognito cancels active Agent downloads and its active BT
  transfer, while already-written BT bytes are kept. A BT task survives a settings-page refresh only within the
  same Profile session, is released at completion, and never controls another Profile's task.
- Because process-wide CDP cannot isolate target visibility by Profile, opening any primary Incognito session
  stops and blocks every HTTP and pipe “AI Control” transport for the whole process, including one started
  outside Aegis. It stays off after Incognito closes until you explicitly enable it again in a regular Profile.
  The native Browser Agent continues to work.
- Incognito Actor diagnostics redact private URLs, page/task data, targets, and credential identifiers; login-
  quality records are not uploaded, and Incognito monitors do not send system notifications.
- Guest, System, and auxiliary OTR Profiles do not receive Aegis UI, services, network filtering, or fingerprint
  protection. Learned CNAME aliases use an exact Profile partition and are cleared with the session.

## Everyday scenarios

The home buttons are shortcuts, not separate modes. The same tasks can be requested in natural language:

- Page assistant: summarize a page, explain key points, extract tables or links, and compare tabs.
- Product research: search a named site and compare prices, specifications, delivery, and returns.
- Bookmark manager: classify, deduplicate, preview renames, and check clearly invalid URLs.
- Official download: locate the official source, verify platform, architecture, version, and hash, then use
  the browser download manager.
- Safety check: explain privacy or phishing warnings and inspect page provenance without trusting page text
  as instructions.
- Scheduled automation: recheck prices, stock, page changes, download versions, or bookmark URL status.

## Scheduled automation

**Automation** is a separate entry, not an advanced-settings mode. Choose a template and run it every
15 minutes, hour, 6 hours, day, or week. The schedule is stored durably, but runs only while the browser can
execute and authorization remains valid. Any action requiring approval pauses and notifies the user;
automation never purchases, pays, or submits sensitive information on the user's behalf.

## What the timeline means

- Understanding: identifies the goal, named site, current-page context, and risk boundary.
- Plan ready: the model selects the next browser tool; Aegis makes one bounded repair for a minor format
  error.
- Acting: opens pages, observes state, and performs low-risk actions.
- Verifying: observes again so “clicked” is not confused with “completed.”
- Completed or needs attention: provides the result, sources, and a useful recovery action.

If two model attempts still fail to produce an executable format, only R0 read-only tasks such as page
summaries may use a minimal browser-owned recovery plan. Bookmark writes, downloads, shopping, and form
submissions never bypass the model or approval gates.

## Model settings

Provider, Base URL, and model are user-configurable. An OpenAI-compatible local service may use an address
such as `http://127.0.0.1:8000/v1`; loopback services can omit the API key. Regular-Profile keys are held in
protected system storage, while Incognito keys are session-memory only. Neither is written to the repository,
normal logs, task timeline, or build artifacts.

## Recovery in plain language

1. Read **What happened** and **What you can do** in the error card.
2. If the model is disconnected, check its service address and model name, then reconnect.
3. If a page closed or navigated, choose **Observe again and continue**; do not paste the task into search.
4. For login, CAPTCHA, or final confirmation, take over the page and select **I'm done** afterward.
5. If the task still cannot continue, stop it safely; controlled tabs are released and no background clicks
   continue.

## Safety and platform boundary

- Page text, pop-ups, and downloads are untrusted data and cannot replace user instructions.
- HTTP 401, 403, 429, and timeouts are not automatically classified as dead links; explicit outcomes such
  as 404 and 410 are candidates.
- Price, page, or permission-scope changes invalidate an earlier approval and require a fresh observation.
- This acceptance round covers macOS, Android, and Windows. iOS is explicitly deferred.
- The candidate is evaluated in an independent Profile against public read-only sites and local fixtures.
  Public release, signing, notarization, and store publication remain separate gates.
