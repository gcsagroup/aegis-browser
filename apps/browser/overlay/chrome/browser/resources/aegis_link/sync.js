// 同步状态按设备、站点、用户和集合隔离。服务端版本与本地摘要共同识别并发修改。
import { fingerprint, seal, unseal } from "./codec.js";
import { profileStore } from "./profile.js";
import { portalRequest } from "./portal.js";

/** 首次双端均有资料或离线修改冲突时，交由本人明确选择。对旧版本的上传由服务端拒绝。 */
export async function synchronize(tabId, origin, user, kind, password, choose) {
  const binding = JSON.stringify(["aegis-link-v1", origin, user.id, kind]);
  return navigator.locks.request(binding, async () => {
    const store = await profileStore(kind, binding, user.email);
    const current = await store.read(),
      local = await fingerprint(current);
    const key = "revision:" + binding,
      previous = Object.values(await globalThis.chrome.storage.local.get(key))[0];
    const remote = await portalRequest(tabId, origin, kind, user.id);
    let version = remote.version,
      digest = local;
    let action = "upload";
    if (version !== "0") {
      // 即使只是上传，也用用户输入的口令解开现有资料，避免输错口令后重加密覆盖云端。
      const cloud = await unseal(remote.envelope, password, binding);
      const cloudHash = await fingerprint(cloud);
      if (cloudHash === local) action = "same";
      else if (previous?.version === version) action = "upload";
      else if (
        previous?.digest === local ||
        (!previous && kind === "bookmarks" && !current.length)
      )
        action = "download";
      else action = await choose(kind);
      if (action === "download" || action === "restore") {
        if ((await fingerprint(await store.read())) !== local)
          throw new Error("conflict");
        await store.apply(cloud, current, action === "restore");
        digest = cloudHash;
      }
    }
    if (action === "upload") {
      const envelope = await seal(current, password, binding);
      const saved = await portalRequest(tabId, origin, kind, user.id, {
        expected_version: version,
        envelope,
      });
      version = saved.version;
    }
    await globalThis.chrome.storage.local.set({ [key]: { version, digest } });
    return action;
  });
}
