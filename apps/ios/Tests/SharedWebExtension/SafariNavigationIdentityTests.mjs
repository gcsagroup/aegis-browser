import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(
  new URL("../../SharedWebExtension/background.js", import.meta.url),
  "utf8",
);
const listeners = {};
const nativeMessages = [];
const sandbox = {
  addEventListener(name, callback) {
    listeners[name] = callback;
  },
  browser: {
    action: {
      onClicked: {
        addListener(callback) {
          listeners.clicked = callback;
        },
      },
      async setBadgeText() {},
    },
    extension: {inIncognitoContext: false},
    runtime: {
      id: "com.gcsa.aegis.ios.app.safari",
      async sendNativeMessage(message) {
        nativeMessages.push(message);
        return {ok: false};
      },
    },
    scripting: {
      async executeScript() {
        throw new Error("not used by this deterministic test");
      },
    },
    tabs: {
      async get() {
        throw new Error("not used by this deterministic test");
      },
      onRemoved: {
        addListener(callback) {
          listeners.removed = callback;
        },
      },
      onUpdated: {
        addListener(callback) {
          listeners.updated = callback;
        },
      },
    },
    webNavigation: {
      onHistoryStateUpdated: {
        addListener(callback) {
          listeners.historyStateUpdated = callback;
        },
      },
    },
  },
  crypto: globalThis.crypto,
  navigation: undefined,
};
vm.createContext(sandbox);
vm.runInContext(source, sandbox);

const ensureIdentity = vm.runInContext("ensureDocumentIdentity", sandbox);
const observeTab = vm.runInContext("observeTabMetadata", sandbox);
const readSnapshot = vm.runInContext("readAuthorizedSnapshot", sandbox);

// Pre-authorization identity setup must work without window, location, or document.
const initialEpoch = observeTab(7, {url: "https://example.com/a"});
const initialIdentity = ensureIdentity(initialEpoch);
assert.equal(initialIdentity.navigationEpoch, 1);
assert.match(initialIdentity.documentToken, /^[0-9a-f-]{36}$/iu);

let pageReads = 0;
let domReads = 0;
const locationState = {
  href: "https://example.com/a",
  origin: "https://example.com",
};
Object.defineProperty(sandbox, "window", {
  value: {
    get location() {
      pageReads += 1;
      return locationState;
    },
  },
});
Object.defineProperty(sandbox, "document", {
  value: {
    get title() {
      domReads += 1;
      return "Example";
    },
    documentElement: {lang: "zh-CN"},
    querySelectorAll() {
      domReads += 1;
      return [{textContent: "标题"}];
    },
  },
});

// Legitimate control: the same token, epoch, and full URL produce one bounded snapshot.
const control = readSnapshot(
  initialIdentity.documentToken,
  initialIdentity.navigationEpoch,
  "https://example.com/a",
  initialEpoch,
);
assert.equal(control.documentToken, initialIdentity.documentToken);
assert.equal(control.navigationEpoch, initialIdentity.navigationEpoch);
assert.equal(control.origin, "https://example.com");
assert.deepEqual(Array.from(control.headings), ["标题"]);

// Same-URL pushState/replaceState is still a navigation identity change.
pageReads = 0;
domReads = 0;
listeners.historyStateUpdated({
  tabId: 7,
  frameId: 0,
  url: "https://example.com/a",
});
const sameURLHistoryEpoch = observeTab(7, {url: "https://example.com/a"});
assert.equal(sameURLHistoryEpoch, initialEpoch + 1);
assert.throws(
  () =>
    readSnapshot(
      initialIdentity.documentToken,
      initialIdentity.navigationEpoch,
      "https://example.com/a",
      sameURLHistoryEpoch,
    ),
  /stale_document_identity/u,
);
assert.equal(pageReads, 0);
assert.equal(domReads, 0);

// Timing 1: pushState before the second tabs.get advances the extension-side epoch.
pageReads = 0;
domReads = 0;
listeners.updated(
  7,
  {url: "https://example.com/b"},
  {url: "https://example.com/b"},
);
const historyEpoch = observeTab(7, {url: "https://example.com/b"});
assert.equal(historyEpoch, sameURLHistoryEpoch + 1);
locationState.href = "https://example.com/b";
assert.throws(
  () =>
    readSnapshot(
      initialIdentity.documentToken,
      initialIdentity.navigationEpoch,
      locationState.href,
      historyEpoch,
    ),
  /stale_document_identity/u,
);
assert.equal(pageReads, 0);
assert.equal(domReads, 0);

// Timing 2: navigation after tabs.get but before executeScript fails the full-URL check.
pageReads = 0;
domReads = 0;
locationState.href = "https://example.com/c";
assert.throws(
  () =>
    readSnapshot(
      initialIdentity.documentToken,
      historyEpoch,
      "https://example.com/b",
      historyEpoch,
    ),
  /navigation_url_mismatch/u,
);
assert.equal(pageReads, 1);
assert.equal(domReads, 0);

// Timing 3: the identity check, URL check, DOM read, and immutable return are one JS task.
const atomic = readSnapshot(
  initialIdentity.documentToken,
  historyEpoch,
  "https://example.com/c",
  historyEpoch,
);
assert.equal(atomic.navigationEpoch, historyEpoch);
assert.equal(Object.isFrozen(atomic), true);

// Timing 4: after the snapshot returns, native consume is invoked without another await.
const sendIndex = source.indexOf(
  "const consumptionPromise = browser.runtime.sendNativeMessage({",
);
const deleteIndex = source.lastIndexOf("openLeases.delete(leaseID);", sendIndex);
assert.ok(deleteIndex >= 0 && sendIndex > deleteIndex);
assert.doesNotMatch(source.slice(deleteIndex, sendIndex), /\bawait\b/u);

// Navigation lifecycle actively burns every open lease for the affected tab.
observeTab(9, {url: "https://example.com/a"});
vm.runInContext(
  `openLeases.set("00000000-0000-4000-8000-000000000099", {
    tabID: 9,
    common: {
      schemaVersion: 1,
      route: "page.observe",
      extensionID: browser.runtime.id,
      extensionInstanceID: crypto.randomUUID(),
      gestureNonce: crypto.randomUUID(),
      documentToken: crypto.randomUUID(),
      navigationEpoch: 1,
      isPrivate: false,
      tabID: 9,
      frameID: 0,
      origin: "https://example.com"
    }
  })`,
  sandbox,
);
listeners.updated(
  9,
  {url: "https://example.com/history"},
  {url: "https://example.com/history"},
);
assert.equal(nativeMessages.length, 1);
assert.equal(nativeMessages[0].phase, "consume");
assert.equal(
  nativeMessages[0].leaseID,
  "00000000-0000-4000-8000-000000000099",
);

console.log("SAFARI_NAVIGATION_IDENTITY_TESTS=PASS");
