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
const send = (type, value) =>
  reader.contentWindow.postMessage({ type, value }, "chrome-untrusted://aegis-markdown");
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
  current = document;
  local = isLocal;
  if (ready) send("load", current);
  const origin = /^https?:/.test(current.baseURL || "")
    ? new URL(current.baseURL).origin
    : "";
  $("auto-preview").disabled = !origin;
  $("auto-preview").checked = !!state.markdownSites?.[origin];
  notify("已打开 " + current.title + "，文档只读。外部图片需要在阅读区主动加载。");
}
async function file(f) {
  if (!f || !/\.(md|markdown)$/i.test(f.name))
    throw Error("请选择 .md 或 .markdown 文件。");
  if (f.size > 2097152) throw Error("文档超过 2 MiB，请使用原文件查看。");
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
    if (current) send("load", current);
  } else if (type === "copy" && typeof value === "string" && value.length <= 2097152)
    navigator.clipboard.writeText(value).then(
      () => notify("已复制。"),
      () => notify("复制失败，请重试。"),
    );
  else if (type === "open" && typeof value === "string") {
    try {
      const u = new URL(value);
      if (["http:", "https:"].includes(u.protocol) && !u.username && !u.password)
        window.open(u.href, "_blank", "noopener,noreferrer");
    } catch {}
  } else if (type === "relativeLink")
    notify("本地相对链接请通过“打开文件”选择目标文档：" + String(value).slice(0, 200));
  else if (type === "images" && Array.isArray(value))
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
    if (!current || !local) throw Error("只有本地导入文档可授权本地图片目录。");
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
      if (total > 10485760) throw Error("图片合计超过 10 MiB，请选择更小的图片。");
      resources[ref] = await new Promise((resolve, reject) => {
        const r = new FileReader();
        r.onload = () => resolve(r.result);
        r.onerror = reject;
        r.readAsDataURL(f);
      });
    }
    if(current !== targetDocument || !local) throw Error("文档已变化，请重新选择图片目录。");
    current.resources = resources;
    send("load", current);
    notify("已在授权目录内加载 " + Object.keys(resources).length + " 张图片。");
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
  const d = await request({ op: "downloads" });
  $("downloads").replaceChildren();
  for (const item of d.downloads) {
    const option = document.createElement("option");
    option.value = item.id;
    option.textContent = item.title;
    $("downloads").append(option);
  }
}
action("refresh", refresh);
action("read-page", async () => {
  const t = state.tabs.find((t) => t.id === $("tabs").value);
  if (!t) throw Error("请先打开在线 Markdown 原文页。");
  const r = await request({ op: "read-markdown", tab: t.id, url: t.url });
  const payload = r.result?.result?.value;
  if (!payload?.text) throw Error("页面没有可读取的文本。");
  load(payload, false);
});
action("print", () => {
  if (!current) throw Error("请先打开文档。");
  send("print");
});
action("assistant", () => {
  if (!current) throw Error("请先打开文档。");
  $("ai-input").value = current.text;
  $("ai-output").textContent = "";
  $("model").textContent =
    (state.destination || "未配置模型服务") + " / " + (state.model || "");
  $("ai").showModal();
});
action("generate", async () => {
  const text = $("ai-input").value;
  if (new TextEncoder().encode(text).length > 32768)
    throw Error("发送内容超过 32 KiB，请先缩小到需要处理的部分。");
  if (
    !confirm("向 " + state.destination + " / " + state.model + " 发送编辑后的文档内容？")
  )
    return;
  const token = ++generation;
  $("generate").disabled = true;
  $("ai-output").textContent = "正在处理…";
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
  $("ai-output").textContent = "已取消。";
}
action("cancel", cancel);
action("close", async () => {
  await cancel();
  $("ai").close();
});
action("open-download", async () => {
  const r = await request({ op: "open-download", id: $("downloads").value });
  load(r, true);
});
action("save-reading", async () => {
  if (!current) throw Error("请先打开文档。");
  if (new TextEncoder().encode(current.text).length > 32768)
    throw Error("阅读库目前最多保存 32 KiB，请保留原文件。");
  await request({
    op: "save-reading",
    text: current.text,
    title: current.title,
    url: current.baseURL || "file:///Markdown/" + encodeURIComponent(current.title),
  });
  notify("文档已保存到加密阅读库，可从助手的阅读库查看。");
});
$("auto-preview").onchange = async () => {
  try {
    const origin = new URL(current.baseURL).origin;
    state = await request({
      op: "markdown-site",
      origin,
      enabled: $("auto-preview").checked,
    });
    notify("网站预览设置已保存，下次访问 Markdown 原文时应用。");
  } catch (e) {
    notify(e.message);
  }
};
try {
  await refresh();
  const pending = await request({ op: "take-markdown" });
  if (typeof pending.text === "string") load(pending, !!pending.local);
} catch (e) {
  notify(e.message);
}
