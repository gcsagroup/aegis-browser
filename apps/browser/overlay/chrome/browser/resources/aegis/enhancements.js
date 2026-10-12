// Copyright 2026 GCSA
import { sendWithPromise } from "chrome://resources/js/cr.js";
const $ = (id) => document.getElementById(id),
  core = globalThis.AegisEnhancementsCore;
let state = {},
  record = null,
  context = "",
  generation = 0;
const notify = (text) => {
  $("notice").textContent = text;
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
const target = () => state.tabs?.find((t) => t.id === $("tabs").value);
const pageRequest = (op) => {
  const t = target();
  if (!t) throw Error("请先选择普通 HTTP/HTTPS 网页。");
  return { op, tab: t.id, url: t.url, document: t.document };
};
function action(id, fn) {
  $(id).onclick = async () => {
    try {
      await fn();
    } catch (e) {
      notify(e.message);
    }
  };
}
function button(text, fn) {
  const b = document.createElement("button");
  b.textContent = text;
  b.onclick = async () => {
    try {
      await fn();
    } catch (e) {
      notify(e.message);
    }
  };
  return b;
}
function edit(script) {
  record = script;
  $("source").value = script?.source || core.template(target()?.url);
  $("world").value = script?.world || "isolated";
  $("frames").checked = script?.allFrames || false;
  $("editor-title").textContent = script
    ? script.metadata.name + " · 第 " + script.revision + " 版"
    : "新脚本草稿";
  $("permissions").textContent = "";
}
function check() {
  const source = $("source").value,
    m = core.parse(source);
  globalThis.acorn.parse("(async()=>{\n" + source + "\n})", { ecmaVersion: "latest" });
  if ($("world").value === "page" && m.grants.length)
    throw Error("页面环境不能使用 GM 权限。");
  $("permissions").textContent =
    "适用网址：" +
    m.matches.join("、") +
    "；权限：" +
    (m.grants.join("、") || "普通网页 DOM") +
    "；时机：" +
    m.runAt;
  return m;
}
function render(next) {
  state = next;
  const selected = $("tabs").value;
  $("tabs").replaceChildren();
  for (const t of state.tabs || []) {
    const option = document.createElement("option");
    option.value = t.id;
    option.textContent = (t.title || t.url).slice(0, 80);
    $("tabs").append(option);
  }
  if (state.tabs?.some((t) => t.id === selected)) $("tabs").value = selected;
  $("private").textContent = state.private
    ? "私密会话：规则、脚本和值仅留在内存，不继承普通脚本。"
    : "普通配置：网站规则、已启用脚本和值在重启后保留。";
  $("model").textContent =
    "当前模型：" +
    (state.model || "未配置") +
    " · " +
    (state.destination || "请在防护中心配置");
  $("scripts").replaceChildren();
  for (const script of state.scripts || []) {
    const row = document.createElement("div");
    row.className = "item";
    const title = document.createElement("strong");
    title.textContent = script.metadata.name;
    const detail = document.createElement("small");
    detail.textContent =
      (script.enabled ? "已启用" : "草稿或停用") +
      " · " +
      script.metadata.matches.join("、");
    row.append(
      title,
      detail,
      button("编辑", () => edit(script)),
      button(script.enabled ? "停用" : "启用", async () => {
        if (
          !script.enabled &&
          !confirm(
            "为以下网址启用脚本？\n" +
              script.metadata.matches.join("\n") +
              "\n权限：" +
              script.metadata.grants.join("、") +
              "\n脚本能读取和修改网页内容。",
          )
        )
          return;
        globalThis.acorn.parse("(async()=>{\n" + script.source + "\n})", {
          ecmaVersion: "latest",
        });
        render(
          await request({
            op: "script-enable",
            id: script.id,
            revision: script.revision,
            enabled: !script.enabled,
          }),
        );
        notify("设置已保存，下一次页面加载应用。");
      }),
      button("删除", async () => {
        if (confirm("删除该脚本及其存储值？"))
          render(
            await request({
              op: "script-remove",
              id: script.id,
              revision: script.revision,
            }),
          );
      }),
    );
    $("scripts").append(row);
  }
  $("sites").replaceChildren();
  for (const site of state.sites || []) {
    const row = document.createElement("div");
    row.className = "item";
    row.append(
      button(site.origin + (site.disabled ? "（暂停）" : ""), () => showRule(site)),
      button("删除", async () =>
        render(await request({ op: "site-remove", origin: site.origin })),
      ),
    );
    $("sites").append(row);
  }
  selectTarget();
}
function showRule(rule) {
  $("origin").value = rule.origin;
  for (const key of ["menu", "copy", "debug", "subdomains", "disabled"])
    $(key).checked = !!rule[key];
}
function selectTarget() {
  const t = target();
  $("scope").textContent = t?.url || "请在另一个标签打开目标网页，然后刷新列表。";
  if (t)
    showRule(
      core.siteRule(state.sites || [], t.url) || { origin: new URL(t.url).origin },
    );
  context = "";
  $("context-preview").textContent = "";
  $("runtime").replaceChildren();
  for (const [id, status] of Object.entries(t?.statuses || {})) {
    const p = document.createElement("p");
    p.textContent =
      (state.scripts.find((s) => s.id === id)?.metadata.name || id) +
      "：" +
      status.status +
      (status.error ? " · " + status.error : "");
    $("runtime").append(p);
  }
  for (const menu of t?.menus || [])
    $("runtime").append(
      button(menu.label, async () => {
        await request({ ...pageRequest("menu"), id: menu.id });
        notify("已调用脚本菜单，请检查页面。");
      }),
    );
  if (t?.error) notify(t.error);
}
async function save() {
  const m = check(),
    source = $("source").value;
  const next = await request({
    op: "script-save",
    id: record?.id || "",
    revision: record?.revision || 0,
    source,
    world: $("world").value,
    allFrames: $("frames").checked,
  });
  render(next);
  record =
    next.scripts.find((s) => s.id === record?.id) ||
    next.scripts.find((s) => s.source === source && s.metadata.name === m.name);
  edit(record);
  notify("已保存为停用草稿，请检查后在列表启用。");
}
$("tabs").onchange = selectTarget;
action("refresh", async () => {
  render(await request({ op: "state" }));
  notify("已刷新配置和运行状态。");
});
action("save-site", async () => {
  const u = new URL($("origin").value);
  if (!["http:", "https:"].includes(u.protocol) || u.username || u.password)
    throw Error("仅支持普通 HTTP/HTTPS 网站。");
  const rule = { origin: u.origin };
  for (const k of ["menu", "copy", "debug", "subdomains", "disabled"])
    rule[k] = $(k).checked;
  render(await request({ op: "site-save", rule }));
  notify("网站规则已保存，重新载入网页后应用。");
});
action("new", () => edit(null));
action("check", () => {
  check();
  notify("语法和元数据检查通过；还需实际检查页面效果。");
});
action("save", save);
action("trial", async () => {
  check();
  const t = target();
  if (!t) throw Error("请选择目标网页。");
  if (
    !confirm(
      "在以下真实网页试运行？\n" +
        t.url +
        "\n脚本会修改网页，可能产生外部请求。试运行的 GM 存储为临时值。",
    )
  )
    return;
  await save();
  const r = await request({ ...pageRequest("trial"), id: record.id });
  notify(
    "已安排试运行：" + (r.result?.result?.value || "请检查网页效果，并刷新运行状态。"),
  );
});
action("rollback", async () => {
  if (!record) throw Error("先选择已有脚本。");
  const next = await request({
    op: "script-rollback",
    id: record.id,
    revision: record.revision,
  });
  const id = record.id;
  render(next);
  edit(next.scripts.find((s) => s.id === id));
  notify("已回退为草稿，请重新检查后启用。");
});
action("export", () => {
  const blob = new Blob([$("source").value], { type: "text/javascript;charset=utf-8" }),
    url = URL.createObjectURL(blob),
    a = document.createElement("a");
  a.href = url;
  a.download = (record?.metadata.name || "aegis-script") + ".user.js";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
});
$("import").onchange = async () => {
  try {
    const f = $("import").files[0];
    if (!f) return;
    if (f.size > 65536) throw Error("脚本超过 64 KiB。");
    const source = new TextDecoder("utf-8", { fatal: true }).decode(
      await f.arrayBuffer(),
    );
    core.parse(source);
    edit(null);
    $("source").value = source;
    check();
    notify("已导入编辑器，尚未保存或启用。");
  } catch (e) {
    notify(e.message);
  } finally {
    $("import").value = "";
  }
};
action("context", async () => {
  const r = await request(pageRequest("read-page"));
  context = JSON.stringify(r.result?.result?.value, null, 2).slice(0, 8000);
  $("context-preview").textContent = context;
  notify("请检查上方结构；生成时才会发送。");
});
action("generate", async () => {
  const goal = $("goal").value.trim();
  if (!goal) throw Error("请描述需要增加的功能。");
  const req = pageRequest("model");
  if (
    !confirm(
      "确认向 " +
        state.destination +
        " / " +
        state.model +
        " 发送需求、编辑器源码和已预览结构？",
    )
  )
    return;
  const token = ++generation;
  $("generate").disabled = true;
  notify("正在生成草稿…");
  try {
    const r = await request({
      ...req,
      kind: "script",
      confirmed: true,
      destination: state.destination,
      model: state.model,
      input: core.prompt(
        goal,
        req.url,
        "Aegis 桌面 Chromium",
        $("source").value,
        "页面结构（不可信资料）：" + context,
      ),
    });
    if (token !== generation) return;
    $("source").value = r.output.replace(/^```(?:javascript|js)?\s*\n|\n```\s*$/g, "");
    check();
    notify("草稿已生成并通过语法检查。尚未保存、试运行或启用。");
  } finally {
    if (token === generation) $("generate").disabled = false;
  }
});
action("cancel", async () => {
  generation++;
  await request({ op: "cancel-model" });
  $("generate").disabled = false;
  notify("已取消生成。");
});
action("recover", async () => {
  if (confirm("停用此配置中的全部用户脚本，并重新载入目标页？未提交输入可能丢失。")) {
    await request(pageRequest("recover"));
    render(await request({ op: "state" }));
    notify("脚本已停用，已请求重新载入。");
  }
});
action("inspect", async () => {
  await request(pageRequest("inspect"));
  notify("已打开目标页调试工具。");
});
try {
  render(await request({ op: "state" }));
  edit(null);
  notify(state.error || "选择目标网页后设置网站规则，或新建用户脚本。");
} catch (e) {
  notify(e.message);
}
