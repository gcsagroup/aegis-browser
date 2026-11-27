// 仅同步本账号专属书签文件夹与 Chromium 的两项字号设置。文件夹引用按门户和账号分开持久化。
// 还原书签先构建临时树，确认旧树未被同时编辑后再切换引用，写入失败时旧内容仍然可用。
export function validateTree(items, level = 0, budget = { left: 10000 }) {
  if (!Array.isArray(items) || level > 40) throw new Error("invalid");
  return items.map((item) => {
    if (
      --budget.left < 0 ||
      !item ||
      typeof item.title !== "string" ||
      item.title.length > 8192
    )
      throw new Error("invalid");
    if (Array.isArray(item.children) && item.url === undefined) {
      return {
        title: item.title,
        children: validateTree(item.children, level + 1, budget),
      };
    }
    if (
      typeof item.url !== "string" ||
      item.url.length > 32768 ||
      item.children !== undefined
    )
      throw new Error("invalid");
    const url = new URL(item.url);
    if (!["https:", "http:"].includes(url.protocol) || url.username || url.password)
      throw new Error("url");
    return { title: item.title, url: item.url };
  });
}

export function validatePreferences(value) {
  if (
    ![value?.defaultSize, value?.minimumSize].every(
      (n) => Number.isInteger(n) && n >= 0 && n <= 100,
    ) ||
    value.defaultSize < 1
  )
    throw new Error("invalid");
  return { defaultSize: value.defaultSize, minimumSize: value.minimumSize };
}

async function subtree(id) {
  const [folder] = await globalThis.chrome.bookmarks.getSubTree(id);
  if (!folder || !Array.isArray(folder.children)) throw new Error("folder");
  return validateTree(folder.children);
}

async function folder(name, key) {
  const id = Object.values(await globalThis.chrome.storage.local.get(key))[0];
  if (id) {
    const existing = await globalThis.chrome.bookmarks.get(id).catch(() => []);
    if (existing[0] && !existing[0].url) return existing[0];
  }
  const [tree] = await globalThis.chrome.bookmarks.getTree();
  const parent =
    tree.children.find((n) => n.folderType === "bookmarks-bar") ||
    tree.children.find((n) => !n.unmodifiable);
  if (!parent) throw new Error("folder");
  const created = await globalThis.chrome.bookmarks.create({
    parentId: parent.id,
    title: name,
  });
  await globalThis.chrome.storage.local.set({ [key]: created.id });
  return created;
}

async function fill(parentId, items) {
  try {
    for (const item of items) {
      const node = await globalThis.chrome.bookmarks.create({
        parentId,
        title: item.title,
        ...(item.url ? { url: item.url } : {}),
      });
      if (item.children) await fill(node.id, item.children);
    }
  } catch (cause) {
    // 写入失败时由上层移除暂存树，同时向用户报告本地书签错误。
    throw new Error("folder", { cause });
  }
}

/** 获取本账号同步范围的一致性比较值，普通书签栏及其他门户账号的目录不参与。 */
export async function profileStore(collection, binding, email) {
  if (collection === "preferences") {
    return {
      async read() {
        const [a, b] = await Promise.all([
          globalThis.chrome.fontSettings.getDefaultFontSize({}),
          globalThis.chrome.fontSettings.getMinimumFontSize({}),
        ]);
        return validatePreferences({
          defaultSize: a.pixelSize,
          minimumSize: b.pixelSize,
        });
      },
      async apply(data, before) {
        const next = validatePreferences(data);
        const current = await this.read();
        if (
          current.defaultSize !== before.defaultSize ||
          current.minimumSize !== before.minimumSize
        )
          throw new Error("conflict");
        // 两个 Chromium 设置没有事务；次项写入失败时还原本次修改的首项。
        await globalThis.chrome.fontSettings.setDefaultFontSize({
          pixelSize: next.defaultSize,
        });
        try {
          await globalThis.chrome.fontSettings.setMinimumFontSize({
            pixelSize: next.minimumSize,
          });
          const actual = await this.read();
          if (
            actual.defaultSize !== next.defaultSize ||
            actual.minimumSize !== next.minimumSize
          )
            throw new Error("settings");
        } catch (error) {
          await globalThis.chrome.fontSettings.setDefaultFontSize({
            pixelSize: before.defaultSize,
          });
          await globalThis.chrome.fontSettings.setMinimumFontSize({
            pixelSize: before.minimumSize,
          });
          throw new Error("settings", { cause: error });
        }
      },
    };
  }
  const key = "folder:" + binding;
  const name = "Aegis Link · " + email;
  const original = await folder(name, key);
  return {
    read: () => subtree(original.id),
    async apply(data, before, keepCopy) {
      const items = validateTree(data);
      const staged = await globalThis.chrome.bookmarks.create({
        parentId: original.parentId,
        title: name + " (…)",
      });
      let installed = false;
      try {
        await fill(staged.id, items);
        if (JSON.stringify(await subtree(original.id)) !== JSON.stringify(before))
          throw new Error("conflict");
        await globalThis.chrome.bookmarks.update(staged.id, { title: name });
        await globalThis.chrome.storage.local.set({ [key]: staged.id });
        installed = true;
        if (keepCopy)
          await globalThis.chrome.bookmarks.update(original.id, {
            title: name + " · " + new Date().toISOString(),
          });
        else await globalThis.chrome.bookmarks.removeTree(original.id);
      } finally {
        if (!installed) await globalThis.chrome.bookmarks.removeTree(staged.id);
      }
    },
  };
}
