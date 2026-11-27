// 普通浏览器配置文件才提供同步；账号沿用门户自己的登录流程。站点权限仅在用户选择该站时申请。
import { portalOrigin } from "./codec.js";
import { portalRequest } from "./portal.js";
import { synchronize } from "./sync.js";

const labels = {
  site: ["Portal address", "门户地址"],
  login: ["Open portal to sign in", "打开门户登录"],
  sync: ["Sync", "同步"],
  what: ["Data to sync", "同步内容"],
  bookmarks: ["Aegis Link bookmark folder", "Aegis Link 书签文件夹"],
  preferences: ["Default and minimum font sizes", "默认字号和最小字号"],
  pass: ["Sync passphrase", "同步口令"],
  hint: [
    "Use the same passphrase (12 characters or more) on each device. The portal cannot recover it.",
    "每台设备使用相同的同步口令，至少 12 个字符。门户无法找回此口令。",
  ],
  now: ["Sync now", "立即同步"],
  cancel: ["Cancel", "取消"],
  cloud: ["Use cloud copy", "使用云端副本"],
  local: ["Use this device", "使用本机副本"],
  changed: [
    "Both copies have data. Choose which copy to keep.",
    "本机和云端均有数据，请选择要保留的副本。",
  ],
  opened: [
    "Sign in on the portal tab, then return here.",
    "请在门户标签页登录后回到这里。",
  ],
  done: ["Synced", "已同步"],
  running: ["Syncing…", "正在同步…"],
  signin: ["Open the portal and sign in first.", "请先打开门户并登录。"],
  network: [
    "Cannot reach the portal. Check its address and try again.",
    "无法访问门户，请检查地址后重试。",
  ],
  origin: [
    "Use an HTTPS portal address, or a local development address.",
    "请输入 HTTPS 门户地址或本机开发地址。",
  ],
  account: ["The signed-in account changed. Try again.", "当前登录账号已变更，请重试。"],
  unlock: [
    "The passphrase could not unlock this cloud copy.",
    "同步口令无法解开这份云端副本。",
  ],
  conflict: [
    "Data changed during sync. Try again to compare the latest copies.",
    "同步期间数据已变化，请重试以比较最新副本。",
  ],
  limit: ["This collection exceeds the 2 MiB limit.", "此集合超过 2 MiB 限制。"],
  invalid: ["The sync data format is invalid.", "同步资料格式无效。"],
  folder: ["Bookmark folder unavailable.", "无法访问书签文件夹。"],
  url: [
    "Only HTTP and HTTPS bookmarks without embedded credentials are supported.",
    "仅支持未嵌入凭据的 HTTP 和 HTTPS 书签。",
  ],
  choose: ["Select data to sync.", "请选择同步内容。"],
  denied: ["Portal access was not granted.", "未获得该门户的访问权限。"],
  settings: [
    "These font settings could not be changed. Check your browser policies.",
    "无法更改字号，请检查浏览器管理策略。",
  ],
  cancelled: ["Sync cancelled.", "本次同步已取消。"],
};
const language = navigator.language.startsWith("zh") ? 1 : 0;
const text = (k) => (labels[k] || labels.network)[language];
const el = (id) => document.getElementById(id);
const status = (value) => {
  el("status").textContent = value;
};
document.documentElement.lang = language ? "zh-CN" : "en";
document.querySelectorAll("[data-text]").forEach((node) => {
  node.textContent = text(node.dataset.text);
});
const saved = await chrome.storage.local.get(["portal", "kinds"]);
el("site").value = saved.portal || "";
if (saved.kinds)
  for (const kind of ["bookmarks", "preferences"])
    el(kind).checked = saved.kinds.includes(kind);

function originAndPermission() {
  const origin = portalOrigin(el("site").value.trim());
  const permission = { origins: [origin + "/*"] };
  return { origin, permission };
}
el("connection").onsubmit = async (e) => {
  e.preventDefault();
  try {
    const { origin, permission } = originAndPermission();
    if (!(await chrome.permissions.request(permission))) throw new Error("denied");
    await chrome.storage.local.set({ portal: origin });
    await chrome.tabs.create({ url: origin + "/account" });
    status(text("opened"));
  } catch (err) {
    status(text(err.message));
  }
};
async function choose(kind) {
  const dialog = el("decision");
  el("subject").textContent = text(kind);
  dialog.returnValue = "cancel";
  const choice = new Promise((resolve) =>
    dialog.addEventListener("close", () => resolve(dialog.returnValue), { once: true }),
  );
  dialog.showModal();
  const answer = await choice;
  if (!["restore", "upload"].includes(answer)) throw new Error("cancelled");
  return answer;
}
el("sync").onsubmit = async (e) => {
  e.preventDefault();
  if (el("run").disabled) return;
  el("run").disabled = true;
  const pass = el("pass").value;
  try {
    const { origin, permission } = originAndPermission();
    if (!(await chrome.permissions.contains(permission))) throw new Error("signin");
    const kinds = ["bookmarks", "preferences"].filter((k) => el(k).checked);
    if (!kinds.length) throw new Error("choose");
    const tabs = await chrome.tabs.query({ url: origin + "/*" });
    const tab = tabs.find(
      (t) => !t.incognito && t.url && new URL(t.url).origin === origin,
    );
    if (!tab) throw new Error("signin");
    const user = await portalRequest(tab.id, origin, null);
    status(text("running") + " " + user.email);
    await chrome.storage.local.set({ kinds });
    for (const kind of kinds) await synchronize(tab.id, origin, user, kind, pass, choose);
    status(text("done") + " · " + user.email + " · " + kinds.map(text).join(" / "));
    el("pass").value = "";
  } catch (err) {
    status(text(err.message));
  } finally {
    el("run").disabled = false;
  }
};
