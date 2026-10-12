// Copyright 2026 GCSA
// 文档渲染页没有原生文件、模型或设置接口；链接交给外层浏览器处理。
(function () {
  "use strict";
  const $ = (id) => document.getElementById(id);
  let current = { text: "", title: "Markdown 阅读", baseURL: "", resources: {} },
    remote = false,
    font = 17,
    found = -1,
    marks = [],
    lastQuery = "";
  const escape = (text) =>
    text.replace(
      /[&<>"']/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
    );
  const parser = globalThis
    .markdownit({
      html: false,
      linkify: true,
      breaks: false,
      maxNesting: 32,
      highlight(code, language) {
        if (code.length > 20000 || !globalThis.hljs.getLanguage(language))
          return escape(code);
        try {
          return globalThis.hljs.highlight(code, { language, ignoreIllegals: true })
            .value;
        } catch {
          return escape(code);
        }
      },
    })
    .use(globalThis.markdownitTaskLists, { enabled: false });
  const send = (type, value) => {
    if (parent !== window) parent.postMessage({ type, value }, "chrome://aegis");
    else if (window.webkit?.messageHandlers?.aegisMarkdown)
      window.webkit.messageHandlers.aegisMarkdown.postMessage({ type, value });
  };
  function imageAddress(raw) {
    if (Object.hasOwn(current.resources || {}, raw)) {
      const value = current.resources[raw];
      if (
        typeof value === "string" &&
        /^data:image\/(png|jpeg|gif|webp);base64,[a-z0-9+/=]+$/i.test(value) &&
        value.length < 6000000
      )
        return value;
    }
    try {
      const url = new URL(raw, current.baseURL || "https://invalid.local/");
      if (
        !remote ||
        !["http:", "https:"].includes(url.protocol) ||
        url.username ||
        url.password ||
        url.hostname === "invalid.local"
      )
        return "";
      return url.href;
    } catch {
      return "";
    }
  }
  function render() {
    const tokens = parser.parse(current.text, {});
    let blockedImages = 0;
    // 在清理器解析 HTML 之前移除未授权图片地址，避免清理期间产生请求。
    const visit = (list) => {
      for (const token of list) {
        if (token.type === "image") {
          const src = imageAddress(token.attrGet("src") || "");
          if (!src) blockedImages++;
          token.attrSet("src", src);
          token.attrSet("loading", "lazy");
          token.attrSet("referrerpolicy", "no-referrer");
        }
        if (token.children) visit(token.children);
      }
    };
    visit(tokens);
    const html = parser.renderer.render(tokens, parser.options, {});
    const clean = globalThis.DOMPurify.sanitize(html, {
      RETURN_TRUSTED_TYPE: true,
      USE_PROFILES: { html: true },
      FORBID_TAGS: ["form", "style", "iframe", "object", "embed", "video", "audio"],
      FORBID_ATTR: ["style", "srcset", "name"],
      ALLOW_DATA_ATTR: false,
    });
    $("document").innerHTML = clean;
    $("source").textContent = current.text;
    $("outline").replaceChildren();
    const used = new Map();
    for (const header of $("document").querySelectorAll("h1,h2,h3,h4,h5,h6")) {
      const stem =
        "md-" +
        header.textContent
          .trim()
          .toLowerCase()
          .replace(/[^\p{L}\p{N}_-]+/gu, "-")
          .slice(0, 100);
      const number = used.get(stem) || 0;
      used.set(stem, number + 1);
      header.id = stem + (number ? "-" + number : "");
      const a = document.createElement("a");
      a.href = "#" + header.id;
      a.textContent = header.textContent;
      a.dataset.level = header.tagName.slice(1);
      a.addEventListener("click", (event) => {
        event.preventDefault();
        header.scrollIntoView({ block: "start" });
      });
      $("outline").append(a);
    }
    for (const input of $("document").querySelectorAll("input")) input.disabled = true;
    for (const code of $("document").querySelectorAll("pre > code")) {
      const button = document.createElement("button");
      button.className = "code-copy";
      button.textContent = "复制";
      button.addEventListener("click", () => send("copy", code.textContent));
      code.parentElement.prepend(button);
    }
    $("document")
      .querySelectorAll("a")
      .forEach((a) =>
        a.addEventListener("click", (event) => {
          event.preventDefault();
          const raw = a.getAttribute("href");
          if (raw?.startsWith("#")) {
            let anchor;
            try {
              anchor = decodeURIComponent(raw.slice(1));
            } catch {
              return;
            }
            const target = document.getElementById(
              anchor.startsWith("md-") ? anchor : "md-" + anchor,
            );
            if (target && $("document").contains(target)) target.scrollIntoView();
            return;
          }
          try {
            const url = new URL(raw, current.baseURL);
            if (
              ["http:", "https:"].includes(url.protocol) &&
              !url.username &&
              !url.password
            )
              send("open", url.href);
            else send("relativeLink", raw);
          } catch {
            send("relativeLink", raw);
          }
        }),
      );
    $("notice").textContent = blockedImages
      ? `${blockedImages} 张图片尚未加载。外部图片可按需加载，本地相对图片需要授权资源目录。`
      : "文档只读；代码块不会执行。";
    marks = [];
    found = -1;
    lastQuery = "";
  }
  function load(payload) {
    if (
      !payload ||
      typeof payload.text !== "string" ||
      new TextEncoder().encode(payload.text).length > 2097152
    ) {
      $("notice").textContent = "文档超过 2 MiB 或格式无效，请查看原始文件。";
      return false;
    }
    current = {
      text: payload.text,
      title: String(payload.title || "Markdown 阅读").slice(0, 300),
      baseURL: String(payload.baseURL || ""),
      resources: payload.resources || {},
    };
    remote = false;
    $("title").textContent = current.title;
    $("origin").textContent = current.baseURL || "本地导入 · 只读";
    document.title = current.title;
    render();
    send("images", globalThis.AegisMarkdown.images());
    return true;
  }
  function find() {
    const query = $("query").value.trim();
    if (query === lastQuery && marks.length) {
      found = (found + 1) % marks.length;
      marks[found].scrollIntoView({ block: "center" });
      $("notice").textContent = `第 ${found + 1} / ${marks.length} 处匹配`;
      return;
    }
    lastQuery = query;
    for (const mark of marks) mark.replaceWith(document.createTextNode(mark.textContent));
    $("document").normalize();
    marks = [];
    if (!query || query.length > 200) return;
    const walker = document.createTreeWalker($("document"), NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode())
      if (!walker.currentNode.parentElement.closest("button"))
        nodes.push(walker.currentNode);
    for (const node of nodes) {
      if (marks.length >= 2000) break;
      const text = node.textContent,
        lower = text.toLocaleLowerCase(),
        needle = query.toLocaleLowerCase();
      let start = 0,
        index;
      const fragment = document.createDocumentFragment();
      while ((index = lower.indexOf(needle, start)) !== -1 && marks.length < 2000) {
        fragment.append(text.slice(start, index));
        const mark = document.createElement("mark");
        mark.textContent = text.slice(index, index + query.length);
        fragment.append(mark);
        marks.push(mark);
        start = index + query.length;
      }
      if (start) {
        fragment.append(text.slice(start));
        node.replaceWith(fragment);
      }
    }
    found = marks.length ? (found + 1) % marks.length : -1;
    if (found >= 0) marks[found].scrollIntoView({ block: "center" });
    $("notice").textContent = marks.length
      ? `第 ${found + 1} / ${marks.length} 处匹配`
      : "没有找到匹配内容。";
  }
  $("outline-toggle").onclick = () => {
    $("outline").hidden = !$("outline").hidden;
    $("outline-toggle").setAttribute("aria-expanded", String(!$("outline").hidden));
  };
  $("source-toggle").onclick = () => {
    $("source").hidden = !$("source").hidden;
    $("document").hidden = !$("source").hidden;
    $("source-toggle").setAttribute("aria-pressed", String(!$("source").hidden));
  };
  $("copy-source").onclick = () => send("copy", current.text);
  $("theme").onclick = () => {
    const next = document.documentElement.style.colorScheme === "dark" ? "light" : "dark";
    document.documentElement.style.colorScheme = next;
  };
  $("width").onclick = () => {
    const style = document.documentElement.style;
    style.setProperty(
      "--measure",
      style.getPropertyValue("--measure") === "1100px" ? "820px" : "1100px",
    );
  };
  $("font-down").onclick = () => {
    font = Math.max(12, font - 1);
    document.documentElement.style.setProperty("--font", font + "px");
  };
  $("font-up").onclick = () => {
    font = Math.min(28, font + 1);
    document.documentElement.style.setProperty("--font", font + "px");
  };
  $("find").onclick = find;
  $("query").addEventListener("keydown", (e) => {
    if (e.key === "Enter") find();
  });
  $("remote-images").onclick = () => {
    remote = !remote;
    render();
    $("remote-images").textContent = remote ? "停用外部图片" : "加载外部图片";
  };
  window.addEventListener("message", (event) => {
    if (
      event.source === parent &&
      event.origin === "chrome://aegis" &&
      event.data?.type === "load"
    )
      load(event.data.value);
    if (
      event.source === parent &&
      event.origin === "chrome://aegis" &&
      event.data?.type === "print"
    )
      window.print();
  });
  globalThis.AegisMarkdown = Object.freeze({
    load,
    setFont: (size) => {
      if (Number.isFinite(size)) {
        font = Math.max(12, Math.min(48, size));
        document.documentElement.style.setProperty("--font", font + "px");
      }
    },
    text: () => current.text,
    images: () => {
      const refs = [];
      const visit = (list) => {
        for (const token of list) {
          if (token.type === "image") refs.push(token.attrGet("src") || "");
          if (token.children) visit(token.children);
        }
      };
      visit(parser.parse(current.text, {}));
      return [...new Set(refs)].slice(0, 100);
    },
  });
  send("ready", true);
})();
