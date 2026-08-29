const extensionInstanceID = crypto.randomUUID();
const navigationByTab = new Map();
const openLeases = new Map();

function ensureDocumentIdentity(minimumNavigationEpoch) {
  if (
    !Number.isSafeInteger(minimumNavigationEpoch) ||
    minimumNavigationEpoch <= 0
  ) {
    throw new Error("invalid_navigation_epoch");
  }
  const identityKey = Symbol.for("com.gcsa.aegis.read-only-document-identity.v1");
  let state = globalThis[identityKey];

  const hasValidState =
    state !== null &&
    typeof state === "object" &&
    typeof state.documentToken === "string" &&
    Number.isSafeInteger(state.navigationEpoch) &&
    state.navigationEpoch > 0 &&
    typeof state.listenersInstalled === "boolean";

  if (state !== undefined && !hasValidState) {
    throw new Error("invalid_document_identity_state");
  }

  if (state === undefined) {
    state = Object.seal({
      documentToken: crypto.randomUUID(),
      navigationEpoch: minimumNavigationEpoch,
      listenersInstalled: false,
    });
    Object.defineProperty(globalThis, identityKey, {
      value: state,
      configurable: false,
      enumerable: false,
      writable: false,
    });
  }

  if (state.navigationEpoch < minimumNavigationEpoch) {
    state.navigationEpoch = minimumNavigationEpoch;
  }

  const advanceNavigation = () => {
    if (state.navigationEpoch === Number.MAX_SAFE_INTEGER) {
      state.documentToken = crypto.randomUUID();
      state.navigationEpoch = 1;
    } else {
      state.navigationEpoch += 1;
    }
  };

  if (!state.listenersInstalled) {
    state.listenersInstalled = true;
    globalThis.addEventListener("pagehide", advanceNavigation, {capture: true});
    globalThis.addEventListener("hashchange", advanceNavigation, {capture: true});
    globalThis.addEventListener("popstate", advanceNavigation, {capture: true});
    if (typeof globalThis.navigation?.addEventListener === "function") {
      globalThis.navigation.addEventListener("navigate", advanceNavigation);
    }
  }

  return Object.freeze({
    documentToken: state.documentToken,
    navigationEpoch: state.navigationEpoch,
  });
}

function readAuthorizedSnapshot(
  expectedDocumentToken,
  expectedNavigationEpoch,
  expectedURL,
  minimumNavigationEpoch,
) {
  if (
    typeof expectedDocumentToken !== "string" ||
    !Number.isSafeInteger(expectedNavigationEpoch) ||
    expectedNavigationEpoch <= 0 ||
    typeof expectedURL !== "string" ||
    !Number.isSafeInteger(minimumNavigationEpoch) ||
    minimumNavigationEpoch <= 0
  ) {
    throw new Error("invalid_authorized_snapshot_request");
  }

  const identityKey = Symbol.for("com.gcsa.aegis.read-only-document-identity.v1");
  const state = globalThis[identityKey];
  const hasValidState =
    state !== null &&
    typeof state === "object" &&
    typeof state.documentToken === "string" &&
    Number.isSafeInteger(state.navigationEpoch) &&
    state.navigationEpoch > 0 &&
    typeof state.listenersInstalled === "boolean";
  if (!hasValidState) {
    throw new Error("missing_document_identity");
  }

  if (state.navigationEpoch < minimumNavigationEpoch) {
    state.navigationEpoch = minimumNavigationEpoch;
  }
  if (
    state.documentToken !== expectedDocumentToken ||
    state.navigationEpoch !== expectedNavigationEpoch
  ) {
    throw new Error("stale_document_identity");
  }

  // This is the first page-state access, and it runs only after native authorization.
  if (window.location.href !== expectedURL) {
    throw new Error("navigation_url_mismatch");
  }

  const normalize = (value, maximumLength) =>
    value.replace(/\s+/gu, " ").trim().slice(0, maximumLength);
  const headings = Array.from(document.querySelectorAll("h1, h2"), (heading) =>
    normalize(heading.textContent ?? "", 160),
  )
    .filter(Boolean)
    .slice(0, 12);

  return Object.freeze({
    schemaVersion: 1,
    route: "page.observe.result",
    origin: window.location.origin,
    documentToken: state.documentToken,
    navigationEpoch: state.navigationEpoch,
    title: normalize(document.title, 240),
    language: document.documentElement.lang || "",
    headings,
  });
}

function isUUID(value) {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu.test(
      value,
    )
  );
}

function isDocumentIdentity(value) {
  return (
    value !== null &&
    typeof value === "object" &&
    isUUID(value.documentToken) &&
    Number.isSafeInteger(value.navigationEpoch) &&
    value.navigationEpoch > 0
  );
}

function isReadOnlySnapshot(value) {
  if (value === null || typeof value !== "object") {
    return false;
  }
  const expectedKeys = new Set([
    "schemaVersion",
    "route",
    "origin",
    "documentToken",
    "navigationEpoch",
    "title",
    "language",
    "headings",
  ]);
  const keys = Object.keys(value);
  return (
    keys.length === expectedKeys.size &&
    keys.every((key) => expectedKeys.has(key)) &&
    value.schemaVersion === 1 &&
    value.route === "page.observe.result" &&
    typeof value.origin === "string" &&
    isUUID(value.documentToken) &&
    Number.isSafeInteger(value.navigationEpoch) &&
    value.navigationEpoch > 0 &&
    typeof value.title === "string" &&
    typeof value.language === "string" &&
    Array.isArray(value.headings) &&
    value.headings.every((heading) => typeof heading === "string")
  );
}

function originFromTabMetadata(tab) {
  if (typeof tab?.url !== "string") {
    return null;
  }
  const pageURL = new URL(tab.url);
  if (pageURL.protocol !== "https:" && pageURL.protocol !== "http:") {
    return null;
  }
  return pageURL.origin;
}

function advanceTabNavigation(tabID, url) {
  const current = navigationByTab.get(tabID);
  if (current === undefined) {
    const created = {epoch: 1, url, exhausted: false};
    navigationByTab.set(tabID, created);
    return created.epoch;
  }
  if (current.epoch === Number.MAX_SAFE_INTEGER) {
    current.exhausted = true;
  } else {
    current.epoch += 1;
  }
  current.url = url;
  burnOpenLeasesForTab(tabID);
  return current.epoch;
}

function burnOpenLeasesForTab(tabID) {
  for (const [leaseID, pending] of openLeases) {
    if (pending.tabID !== tabID) {
      continue;
    }
    openLeases.delete(leaseID);
    void burnLease(pending.common, leaseID);
  }
}

function observeTabMetadata(tabID, tab) {
  const url = typeof tab?.url === "string" ? tab.url : "";
  const current = navigationByTab.get(tabID);
  if (current === undefined) {
    return advanceTabNavigation(tabID, url);
  }
  if (current.exhausted) {
    throw new Error("navigation_state_exceeded");
  }
  if (current.url !== url) {
    const epoch = advanceTabNavigation(tabID, url);
    if (current.exhausted) {
      throw new Error("navigation_state_exceeded");
    }
    return epoch;
  }
  return current.epoch;
}

browser.tabs.onUpdated.addListener((tabID, changeInfo, tab) => {
  const current = navigationByTab.get(tabID);
  if (current === undefined) {
    return;
  }
  if (typeof changeInfo.url === "string") {
    if (changeInfo.url !== current.url) {
      advanceTabNavigation(tabID, changeInfo.url);
    }
    return;
  }
  if (changeInfo.status === "loading") {
    const url = typeof tab?.url === "string" ? tab.url : current.url;
    advanceTabNavigation(tabID, url);
  }
});

if (
  typeof browser.webNavigation?.onHistoryStateUpdated?.addListener ===
  "function"
) {
  browser.webNavigation.onHistoryStateUpdated.addListener((details) => {
    if (
      details?.frameId !== 0 ||
      !Number.isInteger(details.tabId) ||
      !navigationByTab.has(details.tabId)
    ) {
      return;
    }
    const current = navigationByTab.get(details.tabId);
    const url = typeof details.url === "string" ? details.url : current.url;
    // History state changes are navigation identity changes even when URL is identical.
    advanceTabNavigation(details.tabId, url);
  });
}

browser.tabs.onRemoved.addListener((tabID) => {
  burnOpenLeasesForTab(tabID);
  navigationByTab.delete(tabID);
});

async function readCurrentDocumentIdentity(tabID, minimumNavigationEpoch) {
  const [injection] = await browser.scripting.executeScript({
    target: {tabId: tabID, frameIds: [0]},
    func: ensureDocumentIdentity,
    args: [minimumNavigationEpoch],
    world: "ISOLATED",
  });
  if (
    !isDocumentIdentity(injection?.result) ||
    (injection.frameId !== undefined && injection.frameId !== 0)
  ) {
    throw new Error("invalid_document_identity");
  }
  return injection.result;
}

async function burnLease(common, leaseID) {
  const documentToken = crypto.randomUUID();
  const navigationEpoch =
    common.navigationEpoch === Number.MAX_SAFE_INTEGER
      ? 1
      : common.navigationEpoch + 1;
  try {
    await browser.runtime.sendNativeMessage({
      ...common,
      phase: "consume",
      documentToken,
      navigationEpoch,
      leaseID,
      snapshot: {
        schemaVersion: 1,
        route: `${common.route}.result`,
        origin: common.origin,
        documentToken,
        navigationEpoch,
        title: "",
        language: "",
        headings: [],
      },
    });
  } catch {
    // Native messaging failure is already fail-closed; the 15-second lease remains bounded.
  }
}

browser.action.onClicked.addListener(async (tab) => {
  if (!Number.isInteger(tab.id)) {
    return;
  }

  let common;
  let leaseID;
  try {
    const currentTab = await browser.tabs.get(tab.id);
    const origin = originFromTabMetadata(currentTab);
    if (origin === null) {
      throw new Error("unsupported_origin");
    }
    const initialNavigationEpoch = observeTabMetadata(tab.id, currentTab);
    const documentIdentity = await readCurrentDocumentIdentity(
      tab.id,
      initialNavigationEpoch,
    );

    common = Object.freeze({
      schemaVersion: 1,
      route: "page.observe",
      extensionID: browser.runtime.id,
      extensionInstanceID,
      gestureNonce: crypto.randomUUID(),
      documentToken: documentIdentity.documentToken,
      navigationEpoch: documentIdentity.navigationEpoch,
      isPrivate: Boolean(browser.extension?.inIncognitoContext),
      tabID: tab.id,
      frameID: 0,
      origin,
    });
    const authorization = await browser.runtime.sendNativeMessage({
      ...common,
      phase: "authorize",
    });
    if (authorization?.ok === true && isUUID(authorization.leaseID)) {
      leaseID = authorization.leaseID;
    }
    if (
      leaseID === undefined ||
      authorization.documentToken !== common.documentToken ||
      authorization.navigationEpoch !== common.navigationEpoch
    ) {
      throw new Error("authorization_denied");
    }
    openLeases.set(leaseID, {tabID: tab.id, common});

    const tabForSnapshot = await browser.tabs.get(tab.id);
    const snapshotOrigin = originFromTabMetadata(tabForSnapshot);
    if (
      typeof tabForSnapshot.url !== "string" ||
      snapshotOrigin !== common.origin
    ) {
      throw new Error("navigation_origin_mismatch");
    }
    const snapshotNavigationEpoch = observeTabMetadata(tab.id, tabForSnapshot);
    const [injection] = await browser.scripting.executeScript({
      target: {tabId: tab.id, frameIds: [0]},
      func: readAuthorizedSnapshot,
      args: [
        common.documentToken,
        common.navigationEpoch,
        tabForSnapshot.url,
        snapshotNavigationEpoch,
      ],
      world: "ISOLATED",
    });
    const snapshot = injection?.result;
    if (
      !isReadOnlySnapshot(snapshot) ||
      (injection.frameId !== undefined && injection.frameId !== 0) ||
      snapshot.documentToken !== common.documentToken ||
      snapshot.navigationEpoch !== common.navigationEpoch ||
      snapshot.origin !== common.origin
    ) {
      throw new Error("invalid_snapshot");
    }

    // No browser API call is allowed between the bound snapshot and native consumption.
    openLeases.delete(leaseID);
    const consumptionPromise = browser.runtime.sendNativeMessage({
      ...common,
      phase: "consume",
      leaseID,
      snapshot,
    });
    const consumption = await consumptionPromise;
    leaseID = undefined;
    const status = consumption?.ok === true ? "OK" : "!";
    await browser.action.setBadgeText({tabId: tab.id, text: status});
  } catch {
    if (common !== undefined && leaseID !== undefined) {
      openLeases.delete(leaseID);
      await burnLease(common, leaseID);
    }
    await browser.action.setBadgeText({tabId: tab.id, text: "!"});
  }
});
