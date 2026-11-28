// WebUI 只调用本机编译的账号消息；门户地址、Cookie 和 CSRF 均由浏览器进程处理。
import { sendWithPromise } from "chrome://resources/js/cr.js";
import { importAccountKey } from "./account_crypto.js";
import { synchronize } from "./account_sync.js";
const zh = navigator.language.startsWith("zh");
const words = new Map(Object.entries({
  heading: ["Sign in to Aegis Browser", "登录 Aegis Browser"],
  signed: ["Your Aegis Browser", "你的 Aegis Browser"],
  bookmarks: ["Bookmarks", "书签"],
  bookmarkHint: [
    "Take your Aegis Link folder to another device.",
    "在其他设备上打开同一份 Aegis Link 书签。",
  ],
  fonts: ["Font sizes", "阅读字号"],
  fontHint: [
    "Use your preferred font sizes across devices.",
    "在不同设备上使用习惯的字号。",
  ],
  privacy: ["Encrypted sync", "加密同步"],
  privacyHint: [
    "Sign in on another device to access your encrypted data.",
    "在其他设备登录同一账号，即可同步加密保存的资料。",
  ],
  signIn: ["Sign in", "登录"],
  skip: ["Continue without signing in", "保持未登录状态"],
  logout: ["Sign out", "退出账号"],
  choose: ["Sync on this device", "在此设备同步"],
  legacyTitle: ["Move your existing data to account sync", "将旧资料迁移到账号同步"],
  legacyHint: [
    "Enter the passphrase used to encrypt this copy. After migration, signing in is enough.",
    "输入当时加密这份资料的口令。迁移后，在其他设备登录同一账号即可同步。",
  ],
  oldPass: ["Previous passphrase", "旧同步口令"],
  migrate: ["Migrate", "迁移"],
  sync: ["Sync now", "立即同步"],
  done: ["Synced", "已同步"],
  retry: ["Retry", "重试"],
  conflictTitle: ["Both copies have changes", "两台设备的资料都发生了变化"],
  local: ["Use this device", "使用本机副本"],
  cloud: ["Use cloud copy", "使用云端副本"],
  cancel: ["Cancel", "取消"],
  network: ["Cannot reach the account service. Try again.", "无法连接账号服务，请重试。"],
  unlock: ["Incorrect sync passphrase.", "同步口令无法解开云端副本。"],
  conflict: ["Data changed. Sync again to compare.", "资料已变更，请重新同步。"],
  account: ["Your account changed. Sign in again.", "账号已变更，请重新登录。"],
  invalid: ["Unsupported data in this collection.", "资料格式不受支持。"],
  limit: ["This collection is too large.", "同步资料超出上限。"],
  folder: ["Bookmarks are unavailable. Try again.", "书签暂不可用，请重试。"],
  settings: ["Your administrator manages these font settings.", "这些字号由管理员管理。"],
  none: ["Select what to sync.", "请选择同步内容。"],
  working: ["Syncing…", "正在同步…"],
}));
const tr = (key) => (words.get(key) ?? words.get("network"))[zh ? 1 : 0];
const el = (id) => document.getElementById(id);
const call = (action, input = {}) => sendWithPromise("aegisLinkAccount", action, input);
const kinds = ["bookmarks", "preferences"];
const background = location.hash === "#autosync";
const selectionKey = (u) => "sync-types:" + JSON.stringify([u.origin, u.id]);
function selectedKinds(u) {
  const saved = localStorage.getItem(selectionKey(u));
  return saved ? JSON.parse(saved) : ["bookmarks"];
}
const welcomeWindow = await call("isWelcomeWindow");
let user,
  busy = false;
document.documentElement.lang = zh ? "zh-CN" : "en";
document
  .querySelectorAll("[data-copy]")
  .forEach((node) => (node.textContent = tr(node.dataset.copy)));
function show(account) {
  if (account && account.id !== user?.id) {
    const selected = selectedKinds(account);
    for (const kind of kinds) el(kind).checked = selected.includes(kind);
  }
  user = account;
  el("heading").textContent = tr(welcomeWindow ? "heading" : "signed");
  document.querySelector(".benefits").hidden = !welcomeWindow;
  el("skip").hidden = !welcomeWindow;
  el("identity").hidden = !user;
  el("identity").textContent = user?.email || "";
  el("sync").hidden = !user;
  el("welcome").hidden = !!user;
}
// 同一轮先核对真实会话，再获取仅在内存中使用的密钥。后台冲突留给用户打开账号页处理。
async function refresh() {
  if (busy) return;
  busy = true;
  el("retry").hidden = true;
  el("run").disabled = true;
  el("logout").disabled = true;
  el("sync").querySelector("fieldset").disabled = true;
  try {
    const current = await call("session");
    show(current);
    if (welcomeWindow) return;
    const selected = selectedKinds(current);
    if (!selected.length) {
      el("status").textContent = tr("none");
      return;
    }
    el("status").textContent = tr("working");
    const master = await importAccountKey(
      (await call("key", { account: current.id })).key,
    );
    let pending;
    for (const kind of selected) {
      if (!kinds.includes(kind)) continue;
      try {
        await synchronize(call, current, kind, master, choose, requestLegacy);
      } catch (error) {
        if (!background || error?.message !== "attention") throw error;
        pending = true;
      }
    }
    if (!pending) el("status").textContent = tr("done");
  } catch (error) {
    const key = error?.message || error;
    if (key === "signin") {
      show(null);
      if (location.hash === "#signin") await call("login");
    }
    el("status").textContent = ["signin", "cancelled"].includes(key) ? "" : tr(key);
    el("retry").hidden = ["signin", "cancelled"].includes(key) || !!user;
  } finally {
    busy = false;
    el("sync").querySelector("fieldset").disabled = false;
    el("run").disabled = false;
    el("logout").disabled = false;
    if (background) await call("finishAutoSync");
  }
}
el("login").onclick = () => call("login");
el("skip").onclick = () => call("skip");
el("retry").onclick = refresh;
el("logout").onclick = async () => {
  if (busy) return;
  try {
    await call("logout");
    show(null);
    el("status").textContent = "";
  } catch (error) {
    el("status").textContent = tr(error);
  }
};
async function decision(dialog) {
  if (background) throw new Error("attention");
  dialog.returnValue = "cancel";
  const closed = new Promise((resolve) =>
    dialog.addEventListener("close", () => resolve(dialog.returnValue), { once: true }),
  );
  dialog.showModal();
  const answer = await closed;
  if (answer === "cancel") throw new Error("cancelled");
  return answer;
}
async function choose(kind) {
  el("subject").textContent = tr(kind === "preferences" ? "fonts" : "bookmarks");
  return decision(el("decision"));
}
async function requestLegacy() {
  try {
    await decision(el("legacy"));
    return el("oldPass").value;
  } finally {
    el("oldPass").value = "";
  }
}
el("sync").onchange = (event) => {
  if (!user || !kinds.includes(event.target.id)) return;
  localStorage.setItem(
    selectionKey(user),
    JSON.stringify(kinds.filter((k) => el(k).checked)),
  );
  void refresh();
};
el("sync").onsubmit = (event) => {
  event.preventDefault();
  void refresh();
};
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !background) void refresh();
});
show(null);
void refresh();
