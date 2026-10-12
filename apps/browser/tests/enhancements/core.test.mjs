import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import {createHash} from "node:crypto";
const root = new URL(
  "../../overlay/chrome/browser/resources/aegis/enhancements_shared/",
  import.meta.url,
);
const sandbox = { URL, TextEncoder };
vm.runInNewContext(fs.readFileSync(new URL("core.js", root), "utf8"), sandbox);
const core = sandbox.AegisEnhancementsCore;
const vectors = JSON.parse(
  fs.readFileSync(new URL("tests/matching-vectors.json", root), "utf8"),
);
test("共用网址匹配向量", () => {
  for (const v of vectors)
    assert.equal(core.matches(v.pattern, v.url), v.matches, JSON.stringify(v));
});
test("元数据与不支持的权限", () => {
  const source = core.template("https://example.com/article");
  const m = core.parse(source);
  assert.equal(m.name, "我的网页增强");
  assert.equal(m.matches[0], "https://example.com/*");
  for (const text of [
    source.replace("@grant GM_addStyle", "@grant GM_xmlhttpRequest"),
    source.replace("@name", "@require"),
    source.replace("https://example.com/*", "file:///*"),
    "alert(1);\n" + source,
    "x".repeat(65537),
  ])
    assert.throws(() => core.parse(text));
});
test("框架授权、排除与具体规则覆盖", () => {
  const m = core.parse(core.template("https://example.com/"));
  m.excludes = ["https://example.com/private/*"];
  assert.equal(core.applies(m, "https://example.com/a", false), false);
  assert.equal(core.applies(m, "https://example.com/a", false, true), true);
  assert.equal(core.applies(m, "https://example.com/private/a", true), false);
  m.noframes = true;
  assert.equal(core.applies(m, "https://example.com/a", false, true), false);
  const rules = [
    { origin: "https://example.com", subdomains: true, copy: true },
    { origin: "https://app.example.com", disabled: true },
  ];
  assert.equal(core.siteRule(rules, "https://app.example.com/a").disabled, true);
  assert.equal(core.siteRule(rules, "https://example.com.evil.test/"), null);
});
test("反调试只改写目标动态函数并保留普通函数", () => {
  const listeners = [];
  const page = {
    innerWidth: 800,
    innerHeight: 600,
    outerWidth: 1200,
    outerHeight: 900,
    addEventListener: (...x) => listeners.push(x),
    document: {},
  };
  vm.createContext(page);
  vm.runInContext(fs.readFileSync(new URL("site_rules.js", root), "utf8"), page);
  vm.runInContext("AegisInstallSiteRules({menu:true,debug:true});", page);
  assert.equal(page.outerWidth, 800);
  assert.equal(page.outerHeight, 600);
  assert.equal(vm.runInContext('Function("return 42")()', page), 42);
  assert.equal(
    vm.runInContext('Function("debugger;").toString().includes("debugger")', page),
    false,
  );
  assert.equal(
    vm.runInContext(
      'Function("return 2; debugger;").toString().includes("debugger")',
      page,
    ),
    true,
  );
  let stopped = false;
  listeners[0][1]({
    stopImmediatePropagation() {
      stopped = true;
    },
  });
  assert.equal(stopped, true);
});
test("存储权限与回复隔离", async () => {
  const sent = [];
  const ctx = { setTimeout, clearTimeout, console };
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(new URL("script_runtime.js", root), "utf8"), ctx);
  const a = ctx.AegisCreateScriptRuntime({ grants: ["GM.getValue"] }, (x) =>
    sent.push(JSON.parse(x)),
  );
  await assert.rejects(a.api.GM.setValue("x", 1));
  const pending = a.api.GM.getValue("x", 7);
  a.receive({ request: "99", value: "wrong" });
  a.receive({ request: sent[0].request, value: 12 });
  assert.equal(await pending, 12);
});

test("元数据字节上限一致，不静默截断名称", () => {
  const source = core.template("https://example.com/");
  const name = "名称".repeat(100);
  assert.equal(core.parse(source.replace("我的网页增强", name)).name, name);
  assert.throws(() => core.parse(source.replace("我的网页增强", "x".repeat(801))));
  assert.throws(() => core.parse(source.replace("// ==UserScript==", "//==UserScript==")));
});

test("BOSS 调试快捷键只阻止网页监听，普通按键和其他网站保持原样", () => {
  for (const hostname of ["www.zhipin.com", "zhipin.com", "zhipin.com.evil.test", "example.com"]) {
    const listeners = [];
    const page = { location: { hostname }, addEventListener: (...args) => listeners.push(args) };
    vm.createContext(page);
    vm.runInContext(fs.readFileSync(new URL("site_rules.js", root), "utf8"), page);
    vm.runInContext("AegisInstallSiteRules({debug:true});", page);
    const handler = listeners.find(([type]) => type === "keydown")?.[1];
    const allowed = ["www.zhipin.com", "zhipin.com"].includes(hostname);
    assert.equal(!!handler, allowed);
    if (!handler) continue;
    let stopped = false;
    handler({key:"i",metaKey:true,altKey:true,stopImmediatePropagation(){stopped=true;},preventDefault(){throw Error("不得取消浏览器默认操作");}});
    assert.equal(stopped,true);
    stopped=false;
    handler({key:"a",ctrlKey:true,stopImmediatePropagation(){stopped=true;}});
    assert.equal(stopped,false);
  }
});


test("离线解析器与许可证均匹配固定摘要", () => {
  const manifest=JSON.parse(fs.readFileSync(new URL("vendor/manifest.json",root),"utf8"));
  for(const [name,record] of Object.entries(manifest)) {
    const bytes=fs.readFileSync(new URL("vendor/"+name,root));
    assert.equal(createHash("sha256").update(bytes).digest("hex"),record.sha256,name);
  }
});

test("BOSS 控制台探针仅限已取样资源，保留普通日志与 iframe 对象", () => {
  const output = [];
  const consoleObject = {log: (...args) => output.push(args), table: (...args) => output.push(args)};
  const childConsole = {log: (...args) => output.push(args), table: (...args) => output.push(args)};
  const child = {console: childConsole};
  const page = {location: {hostname: "www.zhipin.com"}, console: consoleObject,
    addEventListener() {}, HTMLIFrameElement: class {get contentWindow() {return child;}}};
  vm.createContext(page);
  vm.runInContext(fs.readFileSync(new URL("site_rules.js", root), "utf8"), page);
  vm.runInContext("AegisInstallSiteRules({debug:true});", page);
  const probe = "function XCID(){const d=new Date();d.toString=()=>'';console.log(d);const f=new HTMLIFrameElement();f.contentWindow.console.log(d);console.log('正常日志');}XCID();";
  vm.runInContext(probe, page, {filename:"https://static.zhipin.com/zhipin-ssr-seo/v5474/client/f6251fd.js"});
  assert.deepEqual(output, [["正常日志"]]);
  output.length = 0;
  vm.runInContext(probe, page, {filename:"https://example.com/app.js"});
  assert.equal(output.length, 3);
  assert.equal(vm.runInContext("new HTMLIFrameElement().contentWindow", page), child);
});
