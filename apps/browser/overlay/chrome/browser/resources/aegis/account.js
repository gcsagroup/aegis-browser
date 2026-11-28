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
  resolve: ["Resolve sync issues", "处理同步问题"],
  paused: ["Sync is paused in your Aegis Link account.", "浏览器同步已在门户中暂停。"],
  manage: ["Manage sync in the portal", "在门户管理同步"],
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
const menuView = () => new URLSearchParams(location.search).get("view");
// 历史记录中已下线的入口返回普通账号页，未识别的页面没有桥接权限。
if (location.search && !["?view=portal-profile", "?view=signout"].includes(location.search)) {
  location.replace(location.pathname);
}
const selectionKey = (u) => "sync-types:" + JSON.stringify([u.origin, u.id]);
// 每个账号、来源和数据类型分别记录需要用户选择的冲突，不存储任何同步内容。
const attentionKey = (u, kind) => "sync-attention:" + JSON.stringify([u.origin, u.id, kind]);
function pendingKinds(u) {
  return selectedKinds(u).filter((kind) => localStorage.getItem(attentionKey(u, kind)));
}
function updateAttention() {
  el("resolve").hidden = !user || !pendingKinds(user).length;
}
function selectedKinds(u) {
  const saved = localStorage.getItem(selectionKey(u));
  if (saved === null) return ["bookmarks"];
  // 损坏的本机选择不能默认为同意上传，用户可重新勾选。
  try {
    const value = JSON.parse(saved);
    return Array.isArray(value) ? kinds.filter((kind) => value.includes(kind)) : [];
  } catch {
    return [];
  }
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
  const signout = !!user && menuView() === "signout";
  let heading = welcomeWindow || !user ? "heading" : "signed";
  if (signout) heading = "logout";
  el("heading").textContent = tr(heading);
  document.querySelector(".benefits").hidden = !welcomeWindow;
  el("skip").hidden = !welcomeWindow;
  el("identity").hidden = !user;
  el("identity").textContent = user?.email || "";
  el("sync").hidden = !user || signout;
  el("signout").hidden = !signout;
  el("welcome").hidden = !!user;
  updateAttention();
}
// 普通账号页只读取身份。隐藏文档执行常规同步，前台仅在用户选择解决冲突时取密钥。
async function refresh(resolvePending = false) {
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
    el("status").textContent = "";
    if (menuView() === "portal-profile") {
      await call("portalProfile", { account: current.id });
      return;
    }
    if (!background && !resolvePending) {
      if (menuView() !== "signout") {
        const policy = await call("syncPolicy", { account: current.id });
        el("run").hidden = policy.paused === true;
        el("manage").hidden = !policy.paused;
        if (policy.paused) el("status").textContent = tr("paused");
      }
      return;
    }
    const selected = background ? selectedKinds(current) : pendingKinds(current);
    if (!selected.length) return;
    el("status").textContent = tr("working");
    const master = await importAccountKey(
      (await call("key", { account: current.id })).key,
    );
    for (const kind of selected) {
      try {
        await synchronize(call, current, kind, master, choose, requestLegacy);
        localStorage.removeItem(attentionKey(current, kind));
      } catch (error) {
        if (!background || error?.message !== "attention") throw error;
        localStorage.setItem(attentionKey(current, kind), "1");
      }
    }
    if (!background) el("status").textContent = tr("done");
  } catch (error) {
    const key = error?.message || error;
    if (key === "signin") {
      show(null);
      if (location.hash === "#signin") await call("login");
    }
    el("status").textContent = ["signin", "cancelled"].includes(key) ? "" : tr(key);
    el("retry").hidden = ["signin", "cancelled"].includes(key) || resolvePending;
  } finally {
    busy = false;
    updateAttention();
    el("sync").querySelector("fieldset").disabled = false;
    el("run").disabled = false;
    el("logout").disabled = false;
    if (background) await call("finishAutoSync");
  }
}
el("login").onclick = () => call("login");
el("manage").onclick = () => call("portalSync", { account: user.id });
el("skip").onclick = () => call("skip");
el("retry").onclick = () => refresh();
el("resolve").onclick = () => refresh(true);
el("confirmLogout").onclick = el("logout").onclick = async () => {
  if (busy) return;
  busy = true;
  try {
    await call("logout");
    history.replaceState(null, "", location.pathname);
    show(null);
    el("status").textContent = "";
  } catch (error) {
    el("status").textContent = tr(error);
  } finally {
    busy = false;
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
  el("status").textContent = "";
  updateAttention();
};
el("sync").onsubmit = async (event) => {
  event.preventDefault();
  if (!user || busy || el("run").hidden) return;
  if (!selectedKinds(user).length) {
    el("status").textContent = tr("none");
    return;
  }
  el("run").disabled = true;
  try {
    await call("syncAndGoHome", { account: user.id });
  } catch (error) {
    el("status").textContent = tr(error);
    el("run").disabled = false;
  }
};
window.addEventListener("storage", updateAttention);
window.addEventListener("hashchange", () => { if (!background) void refresh(); });
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !background) void refresh();
});
show(null);
void refresh();
