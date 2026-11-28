// 验证原生账号页的加密协议和原生资源随锁定的 Chromium 补丁交付。
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  fingerprint,
  importAccountKey,
  seal,
  unseal,
} from "../overlay/chrome/browser/resources/aegis/account_crypto.js";
import { synchronize } from "../overlay/chrome/browser/resources/aegis/account_sync.js";

const never = () => assert.fail("不应要求用户交互");
const newKey = () =>
  importAccountKey(crypto.getRandomValues(new Uint8Array(32)).toBase64());

test("账号密钥无需口令，密文绑定账号和类别，损坏或错误密钥不能解密", async () => {
  const data = [{ title: "Guide", url: "https://example.test/guide" }];
  const key = await newKey();
  const binding = '["aegis-link-v1","https://portal.example.test","one","bookmarks"]';
  const first = await seal(data, key, binding);
  assert.notEqual(first, await seal(data, key, binding));
  assert.deepEqual(await unseal(first, key, binding, never), {
    value: data,
    legacy: false,
  });
  for (const [wrongKey, wrongBinding] of [
    [await newKey(), binding],
    [key, binding.replace("one", "two")],
    [key, binding.replace("bookmarks", "preferences")],
  ])
    await assert.rejects(unseal(first, wrongKey, wrongBinding, never), /invalid/);
  const corrupt = Buffer.from(first, "base64");
  corrupt[35] ^= 2;
  await assert.rejects(
    unseal(corrupt.toString("base64"), key, binding, never),
    /invalid/,
  );
  assert.equal(await fingerprint(data), await fingerprint(structuredClone(data)));
});

// 固定向量来自已交付的 v1 格式。取消、错误口令均不得覆盖旧云端资料。
test("旧口令迁移成功一次后，其他设备仅凭账号即可读回同一份资料", async (t) => {
  const memory = new Map();
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: {
      getItem: (k) => memory.get(k) ?? null,
      setItem: (k, v) => memory.set(k, v),
    },
  });
  t.after(() => {
    delete globalThis.localStorage;
  });
  const original =
    "AQUFBQUFBQUFBQUFBQUFBQUCAgICAgICAgICAgIgUmmk2ohd/4NfqyHMKL2hMCxTRK7ivQ/wARwXbcbus1ij80AGIjZTDnL7Ukt19XyV0p0Z9DjK2HT56Uz4bKg=";
  const user = { id: "one", origin: "https://portal.example.test" };
  const expected = [{ title: "Old", url: "https://example.test/" }];
  const key = await newKey();
  let writes = 0,
    local = [],
    envelope = original;
  const call = async (action, input) => {
    if (action === "read") return { version: String(writes + 1), envelope };
    if (action === "profile") {
      if ("value" in input) local = structuredClone(input.value);
      return local;
    }
    assert.equal(action, "write");
    assert.equal(input.change.expected_version, String(writes + 1));
    envelope = input.change.envelope;
    return { version: String(++writes + 1) };
  };
  const sync = (old) => synchronize(call, user, "bookmarks", key, never, old);
  await assert.rejects(
    sync(() => {
      throw Error("cancelled");
    }),
    /cancelled/,
  );
  await assert.rejects(
    sync(() => "wrong"),
    /unlock/,
  );
  assert.deepEqual(local, []);
  assert.equal(envelope, original);
  const stale = (action, input) => {
    if (action === "write") throw new Error("conflict");
    return call(action, input);
  };
  await assert.rejects(
    synchronize(stale, user, "bookmarks", key, never, () => "legacy fixture"),
    /conflict/,
  );
  assert.deepEqual(local, []);
  assert.equal(envelope, original);
  assert.equal(await sync(() => "legacy fixture"), "download");
  assert.deepEqual(local, expected);
  assert.equal(writes, 1);
  assert.equal(Buffer.from(envelope, "base64")[0], 2);
  memory.clear();
  local = [];
  assert.equal(await sync(never), "download");
  assert.deepEqual(local, expected);
  assert.equal(writes, 1);
});

test("欢迎页、工具栏、菜单和同步资料在原生补丁中交付", async () => {
  const patch = await readFile(
    resolve(dirname(fileURLToPath(import.meta.url)), "../patches/0562-aegis-link-desktop-sync.patch"),
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
