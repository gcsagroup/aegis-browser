import "/strings.m.js";
import { loadTimeData } from "chrome://resources/js/load_time_data.js";
import "./enhancements_shared/i18n.js";
const uiText = value => globalThis.AegisI18n.t(value);
globalThis.AegisI18n.setLocale(loadTimeData.getString("aegisLocale"));
globalThis.AegisI18n.translate(document);
// Copyright 2026 GCSA
import { sendWithPromise } from "chrome://resources/js/cr.js";
const $ = (id) => document.getElementById(id),
  reader = $("reader");
let current = null,
  state = {},
  ready = false,
  images = [],
  local = false,
  generation = 0;
const notify = (t) => {
  $("notice").textContent = t;
};
const send = (type, value) => {
  if (type === "configure") {
    const theme = value?.preferences?.theme;
    document.documentElement.style.colorScheme = ["dark", "light"].includes(theme) ? theme : "light dark";
  }
  reader.contentWindow.postMessage({ type, value }, "chrome-untrusted://aegis-markdown");
};
async function request(value) {
  const r = await sendWithPromise("aegisEnhancements", value);
  if (r.error) throw Error(typeof r.error === "string" ? r.error : r.error.message);
  if (r.result?.exceptionDetails)
    throw Error(
      r.result.exceptionDetails.exception?.description || r.result.exceptionDetails.text,
    );
  return r;
}
function action(id, fn) {
  $(id).onclick = async () => {
    try {
      await fn();
    } catch (e) {
      notify(e.message);
      $("ai-output").textContent = e.message;
    }
  };
}
function load(document, isLocal) {
  generation++;
  void request({op: "cancel-model"});
  $("generate").disabled = false;
  $("ai").hidden = true;
  $("assistant").setAttribute("aria-expanded", "false");
  $("ai-output").textContent = "";
  current = document;
  local = isLocal;
  $("document-title").textContent = current.title;
  $("source-toggle").setAttribute("aria-pressed", "false");
  $("source-info").textContent = isLocal ? uiText("本地文档 · 只读") : new URL(current.baseURL).host + uiText(" · 只读");
  $("source-address").textContent = current.baseURL || uiText("从本机导入，未上传原文件。");
  $("directory").disabled = !isLocal;
  $("start").hidden = true;
  $("workspace").hidden = false;
  $("document-tools").hidden = false;
  if (ready) send("load", current);
  const origin = /^https?:/.test(current.baseURL || "")
    ? new URL(current.baseURL).origin
    : "";
  $("auto-preview").disabled = !origin;
  $("auto-preview").checked = !!state.markdownSites?.[origin];
  notify("");
}
async function file(f) {
  if (!f || !/\.(md|markdown)$/i.test(f.name))
    throw Error(uiText("请选择 .md 或 .markdown 文件。"));
  if (f.size > 2097152) throw Error(uiText("文档超过 2 MiB，请使用原文件查看。"));
  const text = new TextDecoder("utf-8", { fatal: true }).decode(await f.arrayBuffer());
  load({ text, title: f.name, baseURL: "", resources: {} }, true);
}
window.addEventListener("message", (event) => {
  if (
    event.source !== reader.contentWindow ||
    event.origin !== "chrome-untrusted://aegis-markdown"
  )
    return;
  const { type, value } = event.data || {};
  if (type === "ready") {
    ready = true;
    send("configure", {embedded: true, locale: loadTimeData.getString("aegisLocale"), preferences: state.readingPreferences});
    if (current) send("load", current);
  } else if (type === "copy" && typeof value === "string" && value.length <= 2097152)
    navigator.clipboard.writeText(value).then(
      () => notify(uiText("已复制。")),
      () => notify(uiText("复制失败，请重试。")),
    );
  else if (type === "open" && typeof value === "string") {
    try {
      const u = new URL(value);
      if (["http:", "https:"].includes(u.protocol) && !u.username && !u.password)
        window.open(u.href, "_blank", "noopener,noreferrer");
    } catch {}
  } else if (type === "relativeLink")
    notify(uiText("本地相对链接请通过“打开文件”选择目标文档：") + String(value).slice(0, 200));
  else if (type === "resources") $("directory").click();
  else if (type === "view-state" && value && typeof value === "object") {
    $("outline-toggle").setAttribute("aria-expanded", String(value.outline === true));
    $("source-toggle").setAttribute("aria-pressed", String(value.source === true));
  } else if (type === "images" && Array.isArray(value))
    images = value.filter((x) => typeof x === "string").slice(0, 100);
});
$("file").onchange = async () => {
  try {
    await file($("file").files[0]);
  } catch (e) {
    notify(e.message);
  } finally {
    $("file").value = "";
  }
};
document.addEventListener("dragover", (e) => e.preventDefault());
document.addEventListener("drop", async (e) => {
  e.preventDefault();
  try {
    await file(e.dataTransfer.files[0]);
  } catch (error) {
    notify(error.message);
  }
});
$("directory").onchange = async () => {
  try {
    if (!current || !local) throw Error(uiText("只有本地导入文档可授权本地图片目录。"));
    const targetDocument = current;
    const files = new Map();
    for (const f of $("directory").files) {
      const path = f.webkitRelativePath.split("/").slice(1).join("/");
      files.set(path, f);
    }
    const resources = {};
    let total = 0;
    for (const ref of images) {
      if (/^[a-z][a-z\d+.-]*:|^\/|^\\/i.test(ref)) continue;
      let path;
      try {
        path = decodeURIComponent(ref.split(/[?#]/)[0]);
      } catch {
        continue;
      }
      const parts = path.split("/");
      if (parts.some((p) => p === ".." || p.includes("\\"))) continue;
      path = parts.filter((p) => p && p !== ".").join("/");
      const f = files.get(path);
      if (!f || !/^image\/(png|jpeg|gif|webp)$/.test(f.type) || f.size > 4194304)
        continue;
      total += f.size;
      if (total > 10485760) throw Error(uiText("图片合计超过 10 MiB，请选择更小的图片。"));
      resources[ref] = await new Promise((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => resolve(r.result);
        r.onerror = reject;
        r.readAsDataURL(f);
      });
    }
    if(current !== targetDocument || !local) throw Error(uiText("文档已变化，请重新选择图片目录。"));
    current.resources = resources;
    send("load", current);
    notify(uiText("已在授权目录内加载 ") + Object.keys(resources).length + uiText(" 张图片。"));
  } catch (e) {
    notify(e.message);
  } finally {
    $("directory").value = "";
  }
};
async function refresh() {
  state = await request({ op: "state" });
  const prior = $("tabs").value;
  $("tabs").replaceChildren();
  for (const t of state.tabs || []) {
    const option = document.createElement("option");
    option.value = t.id;
    option.textContent = (t.title || t.url).slice(0, 65);
    $("tabs").append(option);
  }
  if (state.tabs.some((t) => t.id === prior)) $("tabs").value = prior;

}
action("refresh", refresh);
action("read-page", async () => {
  const t = state.tabs.find((t) => t.id === $("tabs").value);
  if (!t) throw Error(uiText("请先打开在线 Markdown 原文页。"));
  const r = await request({ op: "read-markdown", tab: t.id, url: t.url, document: t.document });
  const payload = r.result?.result?.value;
  if (!payload?.text) throw Error(uiText("页面没有可读取的文本。"));
  load(payload, false);
});
action("print", () => {
  if (!current) throw Error(uiText("请先打开文档。"));
  send("print");
});
action("assistant", () => {
  if (!current) throw Error(uiText("请先打开文档。"));
  $("ai-input").value = current.text;
  $("ai-output").textContent = "";
  $("model").textContent =
    (state.destination || uiText("未配置模型服务")) + " / " + (state.model || "");
  $("ai").hidden = !$("ai").hidden;
  $("assistant").setAttribute("aria-expanded", String(!$("ai").hidden));
});
action("generate", async () => {
  const text = $("ai-input").value;
  if (new TextEncoder().encode(text).length > 32768)
    throw Error(uiText("发送内容超过 32 KiB，请先缩小到需要处理的部分。"));
  if (
    !confirm(uiText("向 ") + state.destination + " / " + state.model + uiText(" 发送编辑后的文档内容？"))
  )
    return;
  const token = ++generation;
  $("generate").disabled = true;
  $("ai-output").textContent = uiText("正在处理…");
  try {
    const r = await request({
      op: "model",
      kind: "markdown",
      confirmed: true,
      destination: state.destination,
      model: state.model,
      input: JSON.stringify({ task: $("ai-goal").value, document: text }),
    });
    if (token === generation) $("ai-output").textContent = r.output;
  } finally {
    if (token === generation) $("generate").disabled = false;
  }
});
async function cancel() {
  generation++;
  await request({ op: "cancel-model" });
  $("generate").disabled = false;
  $("ai-output").textContent = uiText("已取消。");
}
action("cancel", cancel);
action("close", async () => {
  await cancel();
  $("ai").hidden = true;
  $("assistant").setAttribute("aria-expanded", "false");
});
action("save-reading", async () => {
  if (!current) throw Error(uiText("请先打开文档。"));
  if (new TextEncoder().encode(current.text).length > 32768)
    throw Error(uiText("阅读库目前最多保存 32 KiB，请保留原文件。"));
  if (!confirm(uiText("保存完整原文到普通阅读库？文档会持久保留，包括从私密浏览打开的内容。"))) return;
  await request({
    op: "save-reading",
    text: current.text,
    title: current.title,
    url: current.baseURL || "file:///Markdown/" + encodeURIComponent(current.title),
  });
  notify(uiText("文档已保存到加密阅读库，可从浏览器菜单的阅读库查看。"));
});
$("auto-preview").onchange = async () => {
  try {
    const origin = new URL(current.baseURL).origin;
    state = await request({
      op: "markdown-site",
      origin,
      enabled: $("auto-preview").checked,
    });
    notify(uiText("网站预览设置已保存，下次访问 Markdown 原文时应用。"));
  } catch (e) {
    notify(e.message);
  }
};
try {
  await refresh();
  const prefs = state.readingPreferences || {theme: "system", family: "sans", font: 17, spacing: 180, width: 820};
  for (const [key, value] of Object.entries(prefs)) if ($("reading-" + key)) $("reading-" + key).value = String(value);
  if (ready) send("configure", {embedded: true, locale: loadTimeData.getString("aegisLocale"), preferences: prefs});
  const pending = await request({ op: "take-markdown" });
  if (typeof pending.text === "string") load(pending, !!pending.local);
  else {
    const params = new URLSearchParams(location.hash.slice(1));
    const recordID = params.get("record");
    if (recordID) {
      const library = await request({op: "library-list"});
      const record = library.records?.find(item => item.id === recordID);
      if (!record?.text) throw Error(uiText("已保存的文档不可用。"));
      load({text: record.text, title: record.title, baseURL: /^https?:/.test(record.url || "") ? record.url : "", resources: {}}, !/^https?:/.test(record.url || ""));
    }
    const t = state.tabs.find(tab => tab.id === params.get("tab"));
    if (t) { $("tabs").value = t.id; $("read-page").click(); }
  }
} catch (e) {
  notify(e.message);
}

for (const id of ["outline-toggle", "find-toggle", "source-toggle", "copy-source", "remote-images"])
  action(id, () => {
    if (!current) return;
    send("command", id);
    if (id === "outline-toggle") $(id).setAttribute("aria-expanded", String($(id).getAttribute("aria-expanded") !== "true"));
    if (id === "source-toggle") $(id).setAttribute("aria-pressed", String($(id).getAttribute("aria-pressed") !== "true"));
  });
action("open-another", () => $("file").click());
for (const key of ["theme", "family", "font", "spacing", "width"])
  $("reading-" + key).onchange = async () => {
    const preferences = {};
    for (const field of ["theme", "family", "font", "spacing", "width"])
      preferences[field] = ["font", "spacing", "width"].includes(field) ? Number($("reading-" + field).value) : $("reading-" + field).value;
    try {
      state = await request({op: "reading-preferences", preferences});
      send("configure", {embedded: true, locale: loadTimeData.getString("aegisLocale"), preferences});
      notify(uiText("阅读外观已保存。"));
    } catch (error) { notify(error.message); }
  };
