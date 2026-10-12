// Copyright 2026 GCSA
// 仅由浏览器在用户明确授权的网站加载；没有文件、网络或原生权限。
(function (root) {
  "use strict";
  root.AegisInstallSiteRules = function (rule) {
    if (!rule || rule.disabled || root.__aegisSiteRulesInstalled) return;
    root.__aegisSiteRulesInstalled = true;
    if (rule.menu || rule.copy) {
      const events = [
        ...(rule.menu ? ["contextmenu"] : []),
        ...(rule.copy ? ["copy", "cut", "selectstart", "dragstart"] : []),
      ];
      for (const type of events)
        root.addEventListener(type, (event) => event.stopImmediatePropagation(), true);
    }
    if (rule.copy) {
      const install = () => {
        if (
          !document.documentElement ||
          document.getElementById("__aegis_selection_style")
        )
          return;
        const style = document.createElement("style");
        style.id = "__aegis_selection_style";
        style.textContent =
          "* { -webkit-user-select: text !important; user-select: text !important; -webkit-touch-callout: default !important; } input,textarea,[contenteditable] { user-select: auto !important; }";
        document.documentElement.append(style);
      };
      install();
      document.addEventListener("DOMContentLoaded", install, { once: true });
    }
    if (!rule.debug) return;
    // BOSS 快捷键兼容：阻止网页拦截调试组合键，保留浏览器默认操作。
    const host = root.location?.hostname || "";
    if (/(^|\.)zhipin\.com$/.test(host)) {
      // 2026-10-13：已取样的 v5474 SDK 从空白 iframe 借用 console，
      // 用 id getter、Date/Function.toString 和大对象打印探测 DevTools。
      // 仅忽略该资源内检测方法的探针；普通日志、计时器和导航仍调用原实现。
      const wrapped = new WeakSet();
      const wrapConsole = (consoleObject) => {
        if (!consoleObject || wrapped.has(consoleObject)) return;
        wrapped.add(consoleObject);
        for (const name of ["log", "table"]) {
          const original = consoleObject[name];
          if (typeof original !== "function") continue;
          consoleObject[name] = new Proxy(original, {
            apply(target, receiver, args) {
              try {
                const value = args[0];
                const stack = new Error().stack || "";
                const detector = /\bXCI[DT]\b/.test(stack) &&
                  stack.includes("https://static.zhipin.com/zhipin-ssr-seo/v5474/client/f6251fd.js");
                const probe = value && (
                  Object.getOwnPropertyDescriptor(value, "id")?.get ||
                  (Object.hasOwn(value, "toString") &&
                    (typeof value === "function" || Object.prototype.toString.call(value) === "[object Date]")) ||
                  (Array.isArray(value) && value.length === 50 && value[0] &&
                    Object.keys(value[0]).length === 500));
                if (detector && probe) return;
              } catch {}
              return Reflect.apply(target, receiver, args);
            },
          });
        }
      };
      try {
        wrapConsole(root.console);
        const proto = root.HTMLIFrameElement?.prototype;
        const descriptor = proto && Object.getOwnPropertyDescriptor(proto, "contentWindow");
        if (descriptor?.get && descriptor.configurable) {
          Object.defineProperty(proto, "contentWindow", {
            ...descriptor,
            get: new Proxy(descriptor.get, {
              apply(target, receiver, args) {
                const frame = Reflect.apply(target, receiver, args);
                try { wrapConsole(frame?.console); } catch {}
                return frame;
              },
            }),
          });
        }
      } catch {}
      for (const type of ["keydown", "keyup"]) root.addEventListener(type, event => {
        const key = String(event.key).toLowerCase();
        if (key === "f12" || (event.metaKey && event.altKey && ["i", "j", "u", "c"].includes(key)) ||
            (event.ctrlKey && event.shiftKey && ["i", "j", "c"].includes(key)) ||
            (event.ctrlKey && key === "u")) event.stopImmediatePropagation();
      }, true);
    }
    // 只消除动态构造的纯 debugger 函数，不改写一般函数和计时器。
    const Original = root.Function;
    const isOnlyDebugger = (body) =>
      typeof body === "string" && /^\s*(?:debugger\s*;?\s*)+$/.test(body);
    const replacement = new Proxy(Original, {
      apply(target, receiver, args) {
        return Reflect.apply(
          target,
          receiver,
          isOnlyDebugger(args.at(-1)) ? [...args.slice(0, -1), ""] : args,
        );
      },
      construct(target, args, receiver) {
        return Reflect.construct(
          target,
          isOnlyDebugger(args.at(-1)) ? [...args.slice(0, -1), ""] : args,
          receiver,
        );
      },
    });
    try {
      root.Function = replacement;
      Object.defineProperty(Original.prototype, "constructor", {
        value: replacement,
        configurable: true,
        writable: true,
      });
    } catch {}
    // 常见窗口尺寸检测与 disable-devtool 的公开暂停选项。
    for (const [outer, inner] of [
      ["outerWidth", "innerWidth"],
      ["outerHeight", "innerHeight"],
    ]) {
      try {
        Object.defineProperty(root, outer, {
          get: () => root[inner],
          configurable: true,
        });
      } catch {}
    }
    try {
      let value = root.DisableDevtool;
      const suspend = (candidate) => {
        if (typeof candidate === "function") candidate.isSuspend = true;
      };
      suspend(value);
      if (
        !Object.getOwnPropertyDescriptor(root, "DisableDevtool") ||
        Object.getOwnPropertyDescriptor(root, "DisableDevtool").configurable
      ) {
        Object.defineProperty(root, "DisableDevtool", {
          configurable: true,
          get: () => value,
          set: (next) => {
            value = next;
            suspend(next);
          },
        });
      }
    } catch {}
  };
})(globalThis);
