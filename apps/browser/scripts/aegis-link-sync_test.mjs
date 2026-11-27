// 检查浏览器同步协议在账号切换、错误口令及并发编辑场景下不会静默覆盖资料。
import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { createHash, createPublicKey } from "node:crypto";
import {
  portalOrigin,
  seal,
  unseal,
  fingerprint,
} from "../overlay/chrome/browser/resources/aegis_link/codec.js";
import {
  validateTree,
  validatePreferences,
} from "../overlay/chrome/browser/resources/aegis_link/profile.js";

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
test("仅连接用户明确选择的门户，拒绝带凭据或路径的地址", () => {
  for (const raw of [
    "https://portal.example.test",
    "http://127.0.0.1:5176",
    "http://localhost:5176",
  ])
    assert.equal(portalOrigin(raw + "/"), raw);
  for (const raw of [
    "http://example.test",
    "https://u:p@example.test",
    "https://example.test/api",
    "file:///tmp",
    "https://example.test/#token",
  ])
    assert.throws(() => portalOrigin(raw));
});
test("在更改本地资料前验证整棵书签树与字号", () => {
  const data = [
    { title: "Folder", children: [{ title: "Example", url: "https://example.test" }] },
  ];
  assert.deepEqual(validateTree(data), data);
  for (const url of [
    "javascript:alert(1)",
    "file:///tmp/item",
    "https://user:pw@example.test",
  ])
    assert.throws(() => validateTree([{ title: "test", url }]));
  assert.throws(() => validateTree(Array.from({ length: 10001 }, () => data[0])));
  assert.throws(() => validatePreferences({ defaultSize: -1, minimumSize: 42 }));
  assert.deepEqual(validatePreferences({ defaultSize: 18, minimumSize: 0 }), {
    defaultSize: 18,
    minimumSize: 0,
  });
});
test("设置入口的组件 ID 与清单公钥及产品补丁一致", async (context) => {
  // 此测试独立进程内使用仓库固定资源路径，结束时恢复调用者的工作目录。
  const previous = process.cwd();
  context.after(() => process.chdir(previous));
  process.chdir(fileURLToPath(new URL("../", import.meta.url)));
  const manifest = JSON.parse(
    await readFile("overlay/chrome/browser/resources/aegis_link/manifest.json", "utf8"),
  );
  const publicKey = createPublicKey({
    key: Buffer.from(manifest.key, "base64"),
    format: "der",
    type: "spki",
  });
  assert.equal(publicKey.type, "public");
  assert.equal(publicKey.asymmetricKeyType, "rsa");
  const hash = createHash("sha256")
    .update(Buffer.from(manifest.key, "base64"))
    .digest("hex")
    .slice(0, 32);
  const id = Array.from(hash, (d) => String.fromCharCode(97 + parseInt(d, 16))).join("");
  const settings = await readFile(
    "overlay/chrome/browser/resources/settings/aegis_page/aegis_page.html",
    "utf8",
  );
  assert.ok(settings.includes("chrome-extension://" + id + "/account.html"));
  const patch = await readFile("patches/0562-aegis-link-desktop-sync.patch", "utf8");
  for (const file of [
    "account.html",
    "account.css",
    "account.js",
    "manifest.json",
    "codec.js",
    "portal.js",
    "sync.js",
    "profile.js",
  ]) {
    assert.ok(patch.includes('file="aegis_link/' + file + '"'));
    // 发行构建通过 git am 还原资源，光在 GRIT 中声明文件无法将内容带入源码树。
    const path = "chrome/browser/resources/aegis_link/" + file;
    assert.ok(patch.includes("diff --git a/" + path + " b/" + path), file);
  }
  assert.ok(patch.includes("b/chrome/browser/resources/settings/aegis_page/aegis_page.html"));
  assert.equal(manifest.incognito, "not_allowed");
});
