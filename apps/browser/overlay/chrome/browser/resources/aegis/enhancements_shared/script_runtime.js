// Copyright 2026 GCSA
// 每个脚本使用独立执行环境。send 只桥接该脚本已授权的有限操作。
(function (root) {
  "use strict";
  root.AegisCreateScriptRuntime = function (config, send) {
    let sequence = 0;
    const pending = new Map(),
      menu = new Map();
    const timeout = root.setTimeout.bind(root),
      clear = root.clearTimeout.bind(root);
    const receive = (message) => {
      const item = pending.get(message.request);
      if (!item) return;
      pending.delete(message.request);
      clear(item.timer);
      if (message.error) item.reject(new Error(message.error));
      else item.resolve(message.value);
    };
    const request = (op, args = {}) =>
      new Promise((resolve, reject) => {
        const id = String(++sequence);
        const timer = timeout(() => {
          pending.delete(id);
          reject(new Error("脚本操作已过期或权限已撤销。"));
        }, 5000);
        pending.set(id, { resolve, reject, timer });
        try {
          send(JSON.stringify({ request: id, op, ...args }));
        } catch (error) {
          receive({ request: id, error: String(error) });
        }
      });
    const requireGrant = (name) => {
      if (!config.grants.includes(name)) throw new Error("未声明权限：" + name);
    };
    const api = {
      GM: Object.freeze({
        async getValue(key, fallback) {
          requireGrant("GM.getValue");
          const value = await request("get", { key });
          return value === null || value === undefined ? fallback : value;
        },
        async setValue(key, value) {
          requireGrant("GM.setValue");
          return request("set", { key, value });
        },
        async deleteValue(key) {
          requireGrant("GM.deleteValue");
          return request("delete", { key });
        },
      }),
      GM_addStyle(css) {
        requireGrant("GM_addStyle");
        if (typeof css !== "string" || css.length > 32768)
          throw new Error("样式超过限制。");
        const style = document.createElement("style");
        style.textContent = css;
        (document.head || document.documentElement).append(style);
        return style;
      },
      GM_registerMenuCommand(label, callback) {
        requireGrant("GM_registerMenuCommand");
        if (
          typeof label !== "string" ||
          !label.trim() ||
          label.length > 100 ||
          typeof callback !== "function" ||
          menu.size >= 16
        )
          throw new Error("脚本菜单无效或已达到上限。");
        const id = String(menu.size + 1);
        menu.set(id, callback);
        void request("menu", { key: id, label }).catch((error) =>
          console.warn(error.message),
        );
        return id;
      },
    };
    return Object.freeze({
      api,
      receive,
      runMenu: (id) => {
        const callback = menu.get(id);
        if (callback) callback();
      },
      report: (status, error = "") => {
        void request("report", { status, error: String(error).slice(0, 1000) }).catch(
          () => {},
        );
      },
    });
  };
})(globalThis);
