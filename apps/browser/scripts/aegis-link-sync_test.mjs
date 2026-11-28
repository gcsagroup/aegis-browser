// 验证原生账号页的加密协议和原生资源随锁定的 Chromium 补丁交付。
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import {
  fingerprint,
  seal,
  unseal,
} from "../overlay/chrome/browser/resources/aegis/account_crypto.js";
test("同步信封绑定用户与集合，错误口令和损坏密文均不返回资料", async () => {
  const data = [{ title: "Guide", url: "https://example.test/guide" }];
  const key = "two-device test passphrase";
  const a = '["v1","https://portal.example.test","acct1","bookmarks"]';
  const first = await seal(data, key, a);
  const next = await seal(data, key, a);
  assert.notEqual(first, next);
  assert.deepEqual(await unseal(first, key, a), data);
  for (const [p, b] of [
    [key + "x", a],
    [key, a.replace("acct1", "acct2")],
    [key, a.replace("bookmarks", "preferences")],
  ]) {
    await assert.rejects(unseal(first, p, b), /unlock/);
  }
  const corrupt = Buffer.from(first, "base64");
  corrupt[35] ^= 2;
  await assert.rejects(unseal(corrupt.toString("base64"), key, a), /unlock/);
  assert.equal(
    await fingerprint(data),
    await fingerprint(JSON.parse(JSON.stringify(data))),
  );
});

test("欢迎页、工具栏、菜单和同步资料在原生补丁中交付", async () => {
  const patch = await readFile(
    new URL("../patches/0562-aegis-link-desktop-sync.patch", import.meta.url),
    "utf8",
  );
  for (const path of [
    "resources/aegis/account.html",
    "resources/aegis/account.js",
    "resources/aegis/account_crypto.js",
    "resources/aegis/account_sync.js",
    "ui/webui/aegis/link_account_handler.cc",
    "ui/webui/aegis/link_profile_data.cc",
    "ui/views/profiles/avatar_toolbar_button_state_manager.cc",
    "ui/views/profiles/profile_menu_view.cc",
    "ui/startup/startup_browser_creator.cc",
  ]) {
    assert.ok(patch.includes(" b/chrome/browser/" + path), path);
  }
  assert.ok(!patch.includes("chrome-extension://"));
});
