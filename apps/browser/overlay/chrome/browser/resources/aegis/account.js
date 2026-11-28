// WebUI 只调用本机编译的账号消息；门户地址、Cookie 和 CSRF 均由浏览器进程处理。
import { sendWithPromise } from "chrome://resources/js/cr.js";
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
    "Only your sync passphrase unlocks your data.",
    "只有持有同步口令才能解开资料。",
  ],
  signIn: ["Sign in", "登录"],
  skip: ["Continue without signing in", "保持未登录状态"],
  logout: ["Sign out", "退出账号"],
  choose: ["Sync on this device", "在此设备同步"],
  pass: ["Sync passphrase", "同步口令"],
  passHint: [
    "Use the same passphrase of 12 or more characters on both devices.",
    "请在两台设备使用相同的同步口令，至少 12 个字符。",
  ],
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
const welcomeWindow = await call("isWelcomeWindow");
let user,
  busy = false;
document.documentElement.lang = zh ? "zh-CN" : "en";
document
  .querySelectorAll("[data-copy]")
  .forEach((node) => (node.textContent = tr(node.dataset.copy)));
function show(account) {
  if (user?.id !== account?.id) el("pass").value = "";
  user = account;
  el("heading").textContent = tr(welcomeWindow ? "heading" : "signed");
  document.querySelector(".benefits").hidden = !welcomeWindow;
  el("skip").hidden = !welcomeWindow;
  el("identity").hidden = !user;
  el("identity").textContent = user?.email || "";
  el("sync").hidden = !user;
  el("welcome").hidden = !!user;
}
async function refresh() {
  if (busy) return;
  busy = true;
  el("retry").hidden = true;
  try {
    show(await call("session"));
    el("status").textContent = "";
  } catch (error) {
    if (error === "signin" && location.hash === "#signin") {
      await call("login");
      return;
    }
    show(null);
    el("status").textContent = error === "signin" ? "" : tr(error);
    el("retry").hidden = error === "signin";
  } finally {
    busy = false;
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
async function choose(kind) {
  const dialog = el("decision");
  el("subject").textContent = tr(kind === "preferences" ? "fonts" : "bookmarks");
  dialog.returnValue = "cancel";
  const closed = new Promise((resolve) =>
    dialog.addEventListener("close", () => resolve(dialog.returnValue), { once: true }),
  );
  dialog.showModal();
  const value = await closed;
  if (!["restore", "upload"].includes(value)) throw new Error("cancelled");
  return value;
}
el("sync").onsubmit = async (event) => {
  event.preventDefault();
  if (busy || !user) return;
  const selected = ["bookmarks", "preferences"].filter((k) => el(k).checked);
  if (!selected.length) {
    el("status").textContent = tr("none");
    return;
  }
  busy = true;
  el("run").disabled = true;
  el("logout").disabled = true;
  try {
    const current = await call("session");
    if (current.id !== user.id) {
      show(current);
      throw new Error("account");
    }
    el("status").textContent = tr("working");
    for (const kind of selected)
      await synchronize(call, current, kind, el("pass").value, choose);
    el("status").textContent = tr("done");
  } catch (error) {
    const key = error?.message || error;
    if (key === "signin") show(null);
    el("status").textContent = key === "cancelled" ? "" : tr(key);
  } finally {
    el("pass").value = "";
    busy = false;
    el("run").disabled = false;
    el("logout").disabled = false;
  }
};
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && !el("decision").open) void refresh();
});
show(null);
void refresh();
